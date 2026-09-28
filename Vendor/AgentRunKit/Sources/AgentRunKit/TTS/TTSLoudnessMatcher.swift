import Foundation

enum TTSLoudnessMatcher {
    struct Output {
        let audio: Data
        let ranges: [Range<Int>]
        let measurements: [TTSLoudnessMeasurement]
        let summary: TTSLoudnessSummary
    }

    private static let relativeGateLU = 10.0

    private struct RenderedProgram {
        let audio: Data
        let achievedLUFS: Double?
        let truePeakDBTP: Double?
    }

    static func match(
        segments: [Data],
        boundaries: [TTSBoundary],
        policy: TTSStitchPolicy,
        loudness: TTSLoudnessMatch,
        format: PCMFormat
    ) throws -> Output {
        precondition(segments.count == boundaries.count, "segments and boundaries must be aligned")
        try validate(format: format)
        if case .recentMedian = loudness.target {
            return try matchRecent(
                segments: segments,
                boundaries: boundaries,
                policy: policy,
                loudness: loudness,
                format: format
            )
        }
        let layouts = try resolveLayouts(segments: segments, boundaries: boundaries, policy: policy, format: format)
        let readings = try measureOriginals(segments: segments, format: format)
        let anchor = computeAnchor(readings.compactMap(\.lufs))
        let maxCorrection = loudness.maxCorrectionDB
        let differentials = readings.map { reading -> Double in
            differential(reading.lufs, anchor: anchor, maxCorrectionDB: maxCorrection)
        }
        let analysis = try analyzeProgram(
            segments: segments,
            layouts: layouts,
            differentials: differentials,
            loudness: loudness,
            format: format
        )
        let targetShift = try shift(for: loudness.target, measured: analysis.lufs)
        let trim = try peakTrim(peakDBTP: analysis.peakDBTP + targetShift, ceilingDBTP: loudness.truePeakCeilingDBTP)
        let uniform = targetShift + trim
        let gains = differentials.map { linearGain($0 + uniform) }
        let rendered = try renderProgram(segments: segments, layouts: layouts, gains: gains, format: format)
        if rendered.truePeakDBTP == nil, analysis.peakDBTP.isFinite {
            throw TTSError.invalidConfiguration(
                "loudness matching erased nonzero audio during quantization: the delivered program is silent"
            )
        }
        if case .lufs = loudness.target, rendered.achievedLUFS == nil {
            throw TTSError.invalidConfiguration(
                "loudness target is unreachable: the program has no measurable loudness"
            )
        }
        let measurements = readings.enumerated().map { index, reading in
            TTSLoudnessMeasurement(integratedLUFS: reading.lufs, appliedGainDB: differentials[index] + uniform)
        }
        let requested: Double? = if case let .lufs(value) = loudness.target { value } else { nil }
        return Output(
            audio: rendered.audio,
            ranges: layouts.map(\.byteRange),
            measurements: measurements,
            summary: TTSLoudnessSummary(
                achievedLUFS: rendered.achievedLUFS,
                requestedTargetLUFS: requested,
                appliedTrimDB: trim,
                truePeakDBTP: rendered.truePeakDBTP
            )
        )
    }

    static func validate(format: PCMFormat) throws {
        guard format.channels == 1 else {
            throw TTSError.invalidConfiguration("loudness matching requires mono (1-channel) 16-bit PCM")
        }
        guard format.sampleRate >= 8000 else {
            throw TTSError.invalidConfiguration("loudness matching requires a sample rate of at least 8000 Hz")
        }
    }

    private static func resolveLayouts(
        segments: [Data],
        boundaries: [TTSBoundary],
        policy: TTSStitchPolicy,
        format: PCMFormat
    ) throws -> [PCMSeam.Layout] {
        var planner = try PCMSeam.Planner(format: format, policy: policy, totalSegments: segments.count)
        var layouts: [PCMSeam.Layout] = []
        layouts.reserveCapacity(segments.count)
        for index in segments.indices {
            try layouts.append(planner.next(audio: segments[index], trailingBoundary: boundaries[index]))
        }
        return layouts
    }

    private static func measureOriginals(segments: [Data], format: PCMFormat) throws -> [TTSLoudnessReading] {
        try segments.map { audio in
            try measureOriginal(audio: audio, format: format)
        }
    }

    static func measureOriginal(audio: Data, format: PCMFormat) throws -> TTSLoudnessReading {
        let state = TTSLoudnessMeter.IntegratedState(sampleRate: format.sampleRate)
        try PCMStitcher.forEachSampleBlock(in: audio, format: format) { block, _ in
            state.append(UnsafeBufferPointer(block))
        }
        return state.reading()
    }

    private static func analyzeProgram(
        segments: [Data],
        layouts: [PCMSeam.Layout],
        differentials: [Double],
        loudness: TTSLoudnessMatch,
        format: PCMFormat
    ) throws -> (peakDBTP: Double, lufs: Double?) {
        var peak = TTSLoudnessMeter.TruePeakState()
        let program: TTSLoudnessMeter.IntegratedState? =
            if case .lufs = loudness.target {
                TTSLoudnessMeter.IntegratedState(sampleRate: format.sampleRate)
            } else {
                nil
            }
        for index in segments.indices {
            let gain = linearGain(differentials[index])
            try PCMStitcher.forEachRenderedBlock(
                in: segments[index],
                layout: layouts[index],
                gain: gain,
                format: format
            ) { block in
                peak.append(block)
                program?.append(block)
            }
        }
        return (peak.readingDBTP(), program?.reading().lufs)
    }

    private static func renderProgram(
        segments: [Data],
        layouts: [PCMSeam.Layout],
        gains: [Double],
        format: PCMFormat
    ) throws -> RenderedProgram {
        var audio = Data()
        audio.reserveCapacity(segments.reduce(0) { $0 + $1.count })
        let programLoudness = TTSLoudnessMeter.IntegratedState(sampleRate: format.sampleRate)
        var programPeak = TTSLoudnessMeter.TruePeakState()
        for index in segments.indices {
            let rendered = try PCMStitcher.render(
                audio: segments[index],
                layout: layouts[index],
                gain: gains[index],
                format: format
            )
            audio.append(rendered)
            try PCMStitcher.forEachSampleBlock(in: rendered, format: format) { block, _ in
                programLoudness.append(UnsafeBufferPointer(block))
                programPeak.append(UnsafeBufferPointer(block))
            }
        }
        let peak = programPeak.readingDBTP()
        return RenderedProgram(
            audio: audio,
            achievedLUFS: programLoudness.reading().lufs,
            truePeakDBTP: peak.isFinite ? peak : nil
        )
    }

    private static func shift(for target: TTSLoudnessMatch.Target, measured: Double?) throws -> Double {
        switch target {
        case .programMedian, .recentMedian:
            return 0
        case let .lufs(value):
            guard let measured else {
                throw TTSError.invalidConfiguration(
                    "loudness target is unreachable: the program has no measurable loudness"
                )
            }
            return value - measured
        }
    }

    private static func peakTrim(peakDBTP: Double, ceilingDBTP: Double) throws -> Double {
        let ceilingLinear = pow(10.0, ceilingDBTP / 20.0)
        let margin = TTSLoudnessMeter.truePeakQuantizationMargin
        guard ceilingLinear > margin else {
            throw TTSError.invalidConfiguration(
                "true-peak ceiling leaves no representable headroom for 16-bit quantization"
            )
        }
        guard peakDBTP.isFinite else { return 0 }
        return min(0, 20 * log10(ceilingLinear - margin) - peakDBTP)
    }

    static func linearGain(_ decibels: Double) -> Double {
        decibels == 0 ? 1 : pow(10.0, decibels / 20.0)
    }

    static func differential(_ value: Double?, anchor: Double?, maxCorrectionDB: Double) -> Double {
        guard let anchor, let value else { return 0 }
        return min(maxCorrectionDB, max(-maxCorrectionDB, anchor - value))
    }

    static func computeAnchor(_ measured: [Double]) -> Double? {
        guard !measured.isEmpty else { return nil }
        let provisional = median(measured)
        let included = measured.filter { $0 >= provisional - relativeGateLU }
        return median(included)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count.isMultiple(of: 2) {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
        return sorted[count / 2]
    }
}
