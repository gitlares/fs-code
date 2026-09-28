import Foundation

extension TTSLoudnessMatcher {
    static func matchRecent(
        segments: [Data],
        boundaries: [TTSBoundary],
        policy: TTSStitchPolicy,
        loudness: TTSLoudnessMatch,
        format: PCMFormat
    ) throws -> Output {
        var running = try Running(format: format, policy: policy, loudness: loudness, totalSegments: segments.count)
        var audio = Data()
        audio.reserveCapacity(segments.reduce(0) { $0 + $1.count })
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(segments.count)
        var measurements: [TTSLoudnessMeasurement] = []
        measurements.reserveCapacity(segments.count)
        for index in segments.indices {
            let processed = try running.process(audio: segments[index], trailingBoundary: boundaries[index])
            audio.append(processed.audio)
            ranges.append(processed.range)
            measurements.append(processed.measurement)
        }
        return try Output(
            audio: audio,
            ranges: ranges,
            measurements: measurements,
            summary: deliveredSummary(audio: audio, format: format)
        )
    }

    private static func deliveredSummary(audio: Data, format: PCMFormat) throws -> TTSLoudnessSummary {
        guard !audio.isEmpty else {
            return TTSLoudnessSummary(achievedLUFS: nil, requestedTargetLUFS: nil, appliedTrimDB: 0, truePeakDBTP: nil)
        }
        let programLoudness = TTSLoudnessMeter.IntegratedState(sampleRate: format.sampleRate)
        var programPeak = TTSLoudnessMeter.TruePeakState()
        try PCMStitcher.forEachSampleBlock(in: audio, format: format) { block, _ in
            programLoudness.append(UnsafeBufferPointer(block))
            programPeak.append(UnsafeBufferPointer(block))
        }
        let peak = programPeak.readingDBTP()
        return TTSLoudnessSummary(
            achievedLUFS: programLoudness.reading().lufs,
            requestedTargetLUFS: nil,
            appliedTrimDB: 0,
            truePeakDBTP: peak.isFinite ? peak : nil
        )
    }

    struct Running {
        private static let recentReadingLimit = 5
        private static let quantizationStep = 1.0 / 32768.0

        private let format: PCMFormat
        private let loudness: TTSLoudnessMatch
        private var planner: PCMSeam.Planner
        private var peakContext: TTSLoudnessMeter.TruePeakState
        private var recentReadings: [Double] = []

        init(format: PCMFormat, policy: TTSStitchPolicy, loudness: TTSLoudnessMatch, totalSegments: Int) throws {
            try TTSLoudnessMatcher.validate(format: format)
            self.format = format
            self.loudness = loudness
            planner = try PCMSeam.Planner(format: format, policy: policy, totalSegments: totalSegments)
            peakContext = TTSLoudnessMeter.TruePeakState()
        }

        mutating func process(
            audio: Data,
            trailingBoundary: TTSBoundary
            // The audio, its body range, and its measurement are one processing result consumed together.
            // swiftlint:disable:next large_tuple
        ) throws -> (audio: Data, range: Range<Int>, measurement: TTSLoudnessMeasurement) {
            let layout = try planner.next(audio: audio, trailingBoundary: trailingBoundary)
            let reading = try TTSLoudnessMatcher.measureOriginal(audio: audio, format: format)
            if let value = reading.lufs {
                recentReadings.append(value)
                if recentReadings.count > Self.recentReadingLimit {
                    recentReadings.removeFirst()
                }
            }
            let differential = TTSLoudnessMatcher.differential(
                reading.lufs,
                anchor: TTSLoudnessMatcher.computeAnchor(recentReadings),
                maxCorrectionDB: loudness.maxCorrectionDB
            )
            let faded = try fadedBodyAnalysis(audio: audio, layout: layout)
            let requestedGain = TTSLoudnessMatcher.linearGain(differential)
            let gain = try faded.head.withUnsafeBufferPointer { head in
                try peakContext.maximumGain(
                    followingHead: head,
                    isolatedPeak: faded.isolatedPeak,
                    leadingSilenceFrames: layout.leadingSilenceFrames,
                    ceilingDBTP: loudness.truePeakCeilingDBTP,
                    quantizationStep: Self.quantizationStep,
                    requestedGain: requestedGain
                )
            }
            let appliedDB = gain == requestedGain ? differential : 20 * log10(gain)
            let rendered = try PCMStitcher.render(
                audio: audio,
                layout: layout,
                gain: gain,
                format: format
            )
            let bodyStartFrame = layout.leadingSilenceFrames
            var bodyHasSignal = false
            var advanced = peakContext
            try PCMStitcher.forEachSampleBlock(in: rendered, format: format) { block, frameOffset in
                advanced.append(UnsafeBufferPointer(block))
                guard !bodyHasSignal else { return }
                let bodyStart = max(0, bodyStartFrame - frameOffset)
                guard bodyStart < block.count else { return }
                for sample in bodyStart ..< block.count where block[sample] != 0 {
                    bodyHasSignal = true
                    break
                }
            }
            if faded.isolatedPeak > 0, !bodyHasSignal {
                throw TTSError.invalidConfiguration(
                    "chunk signal erased during quantization: no representable gain meets the true-peak ceiling"
                )
            }
            // The peak context commits only after the emitted bytes verify; a failure ends the operation.
            guard advanced.readingDBTP() <= loudness.truePeakCeilingDBTP else {
                throw TTSError.invalidConfiguration("quantized chunk output exceeds the true-peak ceiling at a join")
            }
            peakContext = advanced
            return (
                audio: rendered,
                range: layout.byteRange,
                measurement: TTSLoudnessMeasurement(integratedLUFS: reading.lufs, appliedGainDB: appliedDB)
            )
        }

        private func fadedBodyAnalysis(
            audio: Data,
            layout: PCMSeam.Layout
        ) throws -> (head: [Double], isolatedPeak: Double) {
            let bodyLayout = PCMSeam.Layout(
                frameCount: layout.frameCount,
                leadingSilenceFrames: 0,
                fadeInFrames: layout.fadeInFrames,
                fadeOutFrames: layout.fadeOutFrames,
                byteRange: layout.byteRange
            )
            var isolated = TTSLoudnessMeter.TruePeakState()
            let headCount = min(TTSLoudnessMeter.TruePeakState.historySampleCount, layout.frameCount)
            var head: [Double] = []
            head.reserveCapacity(headCount)
            try PCMStitcher.forEachRenderedBlock(in: audio, layout: bodyLayout, gain: 1, format: format) { block in
                isolated.append(block)
                if head.count < headCount {
                    head.append(contentsOf: block.prefix(headCount - head.count))
                }
            }
            let isolatedDB = isolated.readingDBTP()
            return (head, isolatedDB.isFinite ? pow(10.0, isolatedDB / 20.0) : 0)
        }
    }
}
