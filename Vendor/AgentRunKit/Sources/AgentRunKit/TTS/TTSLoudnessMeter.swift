import Accelerate
import Foundation

enum TTSLoudnessReading: Equatable {
    case measured(Double)
    case unmeasurable(Reason)

    enum Reason: Equatable {
        case shorterThanGatingBlock
        case belowAbsoluteGate
    }

    var lufs: Double? {
        if case let .measured(value) = self { return value }
        return nil
    }
}

enum TTSLoudnessMeter {
    static func integratedLoudness(_ samples: [Double], sampleRate: Int) -> TTSLoudnessReading {
        let state = IntegratedState(sampleRate: sampleRate)
        samples.withUnsafeBufferPointer { state.append($0) }
        return state.reading()
    }

    static func truePeakDBTP(_ samples: [Double]) -> Double {
        var state = TruePeakState()
        samples.withUnsafeBufferPointer { state.append($0) }
        return state.readingDBTP()
    }

    private static func gatedReading(_ powers: [Double]) -> TTSLoudnessReading {
        guard !powers.isEmpty else { return .unmeasurable(.shorterThanGatingBlock) }
        let absoluteGated = powers.filter { blockLoudness($0) > absoluteGate }
        guard !absoluteGated.isEmpty else { return .unmeasurable(.belowAbsoluteGate) }
        let meanAbsolute = absoluteGated.reduce(0, +) / Double(absoluteGated.count)
        let relativeThreshold = offset + 10 * log10(meanAbsolute) - relativeGate
        let gate = max(absoluteGate, relativeThreshold)
        let gated = powers.filter { blockLoudness($0) > gate }
        guard !gated.isEmpty else { return .unmeasurable(.belowAbsoluteGate) }
        let meanGated = gated.reduce(0, +) / Double(gated.count)
        return .measured(offset + 10 * log10(meanGated))
    }

    private static func maximumMagnitude(source: UnsafePointer<Double>, count: Int) -> Double {
        var peak = 0.0
        vDSP_maxmgvD(source, 1, &peak, vDSP_Length(count))
        return peak
    }

    private static func squaredEnergy(source: UnsafePointer<Double>, count: Int) -> Double {
        var energy = 0.0
        vDSP_svesqD(source, 1, &energy, vDSP_Length(count))
        return energy
    }

    private static func convolve(
        source: UnsafePointer<Double>,
        filter: [Double],
        count: Int,
        destination: UnsafeMutablePointer<Double>
    ) {
        filter.withUnsafeBufferPointer { taps in
            guard let tapBase = taps.baseAddress else {
                preconditionFailure("interpolator phase is empty")
            }
            vDSP_convD(
                source, 1, tapBase, 1, destination, 1,
                vDSP_Length(count), vDSP_Length(filter.count)
            )
        }
    }

    private static func kWeightShelf(sampleRate: Int) -> [Double] {
        let cutoff = 1681.974450955533
        let gain = 3.999843853973347
        let quality = 0.7071752369554196
        let warp = tan(.pi * cutoff / Double(sampleRate))
        let shelfGain = pow(10.0, gain / 20.0)
        let bandGain = pow(shelfGain, 0.4996667741545416)
        let norm = 1.0 + warp / quality + warp * warp
        return [
            (shelfGain + bandGain * warp / quality + warp * warp) / norm,
            2.0 * (warp * warp - shelfGain) / norm,
            (shelfGain - bandGain * warp / quality + warp * warp) / norm,
            2.0 * (warp * warp - 1.0) / norm,
            (1.0 - warp / quality + warp * warp) / norm,
        ]
    }

    private static func kWeightHighPass(sampleRate: Int) -> [Double] {
        let cutoff = 38.13547087602444
        let quality = 0.5003270373238773
        let warp = tan(.pi * cutoff / Double(sampleRate))
        let norm = 1.0 + warp / quality + warp * warp
        return [
            1.0,
            -2.0,
            1.0,
            2.0 * (warp * warp - 1.0) / norm,
            (1.0 - warp / quality + warp * warp) / norm,
        ]
    }

    private static let offset = -0.691
    private static let absoluteGate = -70.0
    private static let relativeGate = 10.0

    private static func blockLoudness(_ power: Double) -> Double {
        power > 0 ? offset + 10 * log10(power) : -.infinity
    }

    private static let interpolatorPhases: [[Double]] = {
        let tapCount = 49
        let factor = 4
        let center = Double(tapCount - 1) / 2.0
        var prototype = [Double](repeating: 0, count: tapCount)
        for tap in 0 ..< tapCount {
            let offset = Double(tap) - center
            let sinc = offset == 0 ? 1.0 : sin(.pi * offset / Double(factor)) / (.pi * offset / Double(factor))
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(tap) / Double(tapCount - 1))
            prototype[tap] = sinc * window
        }
        var phases: [[Double]] = []
        for phase in 1 ..< factor {
            var coefficients: [Double] = []
            var source = phase
            while source < prototype.count {
                coefficients.append(prototype[source])
                source += factor
            }
            phases.append(normalizedToUnitDCGain(coefficients))
        }
        return phases
    }()

    private static func normalizedToUnitDCGain(_ coefficients: [Double]) -> [Double] {
        let sum = coefficients.reduce(0, +)
        return sum == 0 ? coefficients : coefficients.map { $0 / sum }
    }

    // Phases are pre-reversed so convolve can use positive filter stride.

    private static let reversedInterpolatorPhases = interpolatorPhases.map { Array($0.reversed()) }

    private static let interpolationGainBound: Double = {
        let worstPhase = reversedInterpolatorPhases.map { phase in
            phase.reduce(0) { $0 + abs($1) }
        }.max() ?? 1
        return max(1, worstPhase)
    }()

    static let truePeakQuantizationMargin: Double = 0.5 / 32768 * interpolationGainBound

    private static let workBlockLength = 4096
}

extension TTSLoudnessMeter {
    private final class WorkBuffer {
        let base: UnsafeMutablePointer<Double>
        private let capacity: Int

        init(capacity: Int) {
            base = UnsafeMutablePointer<Double>.allocate(capacity: capacity)
            base.initialize(repeating: 0, count: capacity)
            self.capacity = capacity
        }

        deinit {
            base.deinitialize(count: capacity)
            base.deallocate()
        }
    }

    private final class BiquadFilter {
        private let setup: OpaquePointer
        private let delays: WorkBuffer

        init(coefficients: [Double]) {
            let sectionCount = coefficients.count / 5
            var setup: OpaquePointer?
            coefficients.withUnsafeBufferPointer { coefficientsPointer in
                guard let base = coefficientsPointer.baseAddress else { return }
                setup = vDSP_biquad_CreateSetupD(base, vDSP_Length(sectionCount))
            }
            guard let setup else {
                preconditionFailure("vDSP biquad setup allocation failed")
            }
            self.setup = setup
            delays = WorkBuffer(capacity: 2 * (sectionCount + 1))
        }

        deinit {
            vDSP_biquad_DestroySetupD(setup)
        }

        func apply(source: UnsafePointer<Double>, destination: UnsafeMutablePointer<Double>, count: Int) {
            vDSP_biquadD(setup, delays.base, source, 1, destination, 1, vDSP_Length(count))
        }

        func applyInPlace(buffer: UnsafeMutablePointer<Double>, count: Int) {
            vDSP_biquadD(setup, delays.base, buffer, 1, buffer, 1, vDSP_Length(count))
        }
    }
}

extension TTSLoudnessMeter {
    final class IntegratedState {
        private let shelf: BiquadFilter
        private let highPass: BiquadFilter
        private let scratch: WorkBuffer
        private let hopLength: Int
        private let gatingBlockLength: Int
        private var pendingEnergy = 0.0
        private var pendingCount = 0
        private var recentHops: [Double] = []
        private var blockPowers: [Double] = []

        init(sampleRate: Int) {
            hopLength = sampleRate / 10
            gatingBlockLength = 4 * hopLength
            shelf = BiquadFilter(coefficients: TTSLoudnessMeter.kWeightShelf(sampleRate: sampleRate))
            highPass = BiquadFilter(coefficients: TTSLoudnessMeter.kWeightHighPass(sampleRate: sampleRate))
            scratch = WorkBuffer(capacity: TTSLoudnessMeter.workBlockLength)
        }

        func append(_ samples: UnsafeBufferPointer<Double>) {
            guard hopLength > 0, !samples.isEmpty, let base = samples.baseAddress else { return }
            var offset = 0
            while offset < samples.count {
                let count = min(TTSLoudnessMeter.workBlockLength, samples.count - offset)
                filterBlock(base: base + offset, count: count)
                offset += count
            }
        }

        func reading() -> TTSLoudnessReading {
            TTSLoudnessMeter.gatedReading(blockPowers)
        }

        private func filterBlock(base: UnsafePointer<Double>, count: Int) {
            shelf.apply(source: base, destination: scratch.base, count: count)
            highPass.applyInPlace(buffer: scratch.base, count: count)
            accumulate(source: scratch.base, count: count)
        }

        private func accumulate(source: UnsafePointer<Double>, count: Int) {
            var offset = 0
            while offset < count {
                let take = min(hopLength - pendingCount, count - offset)
                pendingEnergy += TTSLoudnessMeter.squaredEnergy(source: source + offset, count: take)
                pendingCount += take
                offset += take
                if pendingCount == hopLength {
                    completeHop()
                }
            }
        }

        private func completeHop() {
            recentHops.append(pendingEnergy)
            pendingEnergy = 0
            pendingCount = 0
            guard recentHops.count == 4 else { return }
            blockPowers.append(recentHops.reduce(0, +) / Double(gatingBlockLength))
            recentHops.removeFirst()
        }
    }
}

extension TTSLoudnessMeter {
    struct TruePeakState {
        static let historySampleCount: Int = {
            let longest = TTSLoudnessMeter.interpolatorPhases.map(\.count).max() ?? 1
            return longest - 1
        }()

        private var history: [Double] = []
        private var sampleCount = 0
        private var peak = 0.0
        private let windowWork: WorkBuffer
        private let stageWork: WorkBuffer

        init() {
            windowWork = WorkBuffer(
                capacity: Self.historySampleCount + TTSLoudnessMeter.workBlockLength
            )
            stageWork = WorkBuffer(capacity: TTSLoudnessMeter.workBlockLength)
        }

        mutating func append(_ samples: UnsafeBufferPointer<Double>) {
            guard !samples.isEmpty, let base = samples.baseAddress else { return }
            var offset = 0
            while offset < samples.count {
                let count = min(TTSLoudnessMeter.workBlockLength, samples.count - offset)
                appendBlock(base: base + offset, count: count)
                offset += count
            }
        }

        func readingDBTP() -> Double {
            guard sampleCount > 0 else { return -.infinity }
            let measured = peakWithZeroExtendedTail()
            return measured > 0 ? 20 * log10(measured) : -.infinity
        }

        func maximumGain(
            followingHead: UnsafeBufferPointer<Double>,
            isolatedPeak: Double,
            leadingSilenceFrames: Int,
            ceilingDBTP: Double,
            quantizationStep: Double,
            requestedGain: Double
        ) throws -> Double {
            precondition(followingHead.count <= Self.historySampleCount, "head must fit the interpolator history")
            precondition(isolatedPeak.isFinite && isolatedPeak >= 0, "isolated peak must be finite and non-negative")
            precondition(leadingSilenceFrames >= 0, "leading silence must not be negative")
            precondition(quantizationStep.isFinite && quantizationStep > 0, "step must be finite and positive")
            precondition(requestedGain.isFinite && requestedGain > 0, "requested gain must be finite and positive")
            let ceilingLinear = pow(10.0, ceilingDBTP / 20.0)
            let margin = 0.5 * quantizationStep * TTSLoudnessMeter.interpolationGainBound
            guard ceilingLinear > margin else {
                throw TTSError.invalidConfiguration("true-peak ceiling leaves no representable quantization headroom")
            }
            let cap = min(requestedGain, isolatedPeak > 0 ? (ceilingLinear - margin) / isolatedPeak : .infinity)
            guard leadingSilenceFrames < Self.historySampleCount else { return cap }
            // Every candidate is a region top, so a feasible region keeps the whole body's largest quantized samples.
            var candidate = cap
            while true {
                try Task.checkCancellation()
                let quantized = Self.quantizedHead(at: candidate, followingHead: followingHead, step: quantizationStep)
                if 20 * log10(mixedJoinPeak(quantizedHead: quantized, silence: leadingSilenceFrames)) <= ceilingDBTP {
                    return candidate
                }
                let bottom = Self.smallestGain(
                    reachingMagnitudes: quantized.map(abs),
                    followingHead: followingHead,
                    step: quantizationStep,
                    top: candidate
                )
                candidate = bottom.nextDown
                guard candidate > 0 else { break }
            }
            throw TTSError.invalidConfiguration("no positive gain holds the join under truePeakCeilingDBTP")
        }

        private static func quantizedHead(
            at gain: Double, followingHead: UnsafeBufferPointer<Double>, step: Double
        ) -> [Double] {
            var quantized = [Double](repeating: 0, count: followingHead.count)
            for index in 0 ..< followingHead.count where followingHead[index] != 0 {
                // Exactly zero samples round to zero at every gain and carry no signal to preserve.
                let scaled = (followingHead[index] * gain / step).rounded()
                quantized[index] = scaled * step
            }
            return quantized
        }

        private func mixedJoinPeak(quantizedHead: [Double], silence: Int) -> Double {
            let historyLength = Self.historySampleCount
            let window = windowWork.base
            var cursor = 0
            for _ in 0 ..< (historyLength - history.count) {
                window[cursor] = 0
                cursor += 1
            }
            for sample in history {
                window[cursor] = sample
                cursor += 1
            }
            for _ in 0 ..< silence {
                window[cursor] = 0
                cursor += 1
            }
            for sample in quantizedHead {
                window[cursor] = sample
                cursor += 1
            }
            while cursor < 2 * historyLength {
                window[cursor] = 0
                cursor += 1
            }
            var peak = 0.0
            for phase in TTSLoudnessMeter.reversedInterpolatorPhases {
                TTSLoudnessMeter.convolve(
                    source: window,
                    filter: phase,
                    count: historyLength,
                    destination: stageWork.base
                )
                peak = max(peak, TTSLoudnessMeter.maximumMagnitude(source: stageWork.base, count: historyLength))
            }
            return peak
        }

        private static func smallestGain(
            reachingMagnitudes magnitudes: [Double],
            followingHead: UnsafeBufferPointer<Double>,
            step: Double,
            top: Double
        ) -> Double {
            var low: UInt64 = 1
            var high = top.bitPattern
            while low < high {
                let middle = low + (high - low) / 2
                let gain = Double(bitPattern: middle)
                let quantized = quantizedHead(at: gain, followingHead: followingHead, step: step)
                if magnitudes.indices.allSatisfy({ abs(quantized[$0]) >= magnitudes[$0] }) {
                    high = middle
                } else {
                    low = middle + 1
                }
            }
            return Double(bitPattern: low)
        }

        private mutating func appendBlock(base: UnsafePointer<Double>, count: Int) {
            let block = UnsafeBufferPointer(start: base, count: count)
            peak = max(peak, TTSLoudnessMeter.maximumMagnitude(source: base, count: count))
            peak = max(peak, committedInterpolationPeak(block: block))
            advanceHistory(block: block)
            sampleCount += count
        }

        private func committedInterpolationPeak(block: UnsafeBufferPointer<Double>) -> Double {
            let historyLength = Self.historySampleCount
            let window = windowWork.base
            var cursor = 0
            for _ in 0 ..< (historyLength - history.count) {
                window[cursor] = 0
                cursor += 1
            }
            for sample in history {
                window[cursor] = sample
                cursor += 1
            }
            for index in 0 ..< block.count {
                window[cursor] = block[index]
                cursor += 1
            }
            var committed = 0.0
            for phase in TTSLoudnessMeter.reversedInterpolatorPhases {
                TTSLoudnessMeter.convolve(
                    source: window,
                    filter: phase,
                    count: block.count,
                    destination: stageWork.base
                )
                committed = max(
                    committed,
                    TTSLoudnessMeter.maximumMagnitude(source: stageWork.base, count: block.count)
                )
            }
            return committed
        }

        private func peakWithZeroExtendedTail() -> Double {
            let historyLength = Self.historySampleCount
            let input = windowWork.base
            var cursor = 0
            for _ in 0 ..< (historyLength - history.count) {
                input[cursor] = 0
                cursor += 1
            }
            for sample in history {
                input[cursor] = sample
                cursor += 1
            }
            for _ in 0 ..< historyLength {
                input[cursor] = 0
                cursor += 1
            }
            var measured = peak
            for phase in TTSLoudnessMeter.reversedInterpolatorPhases {
                let tail = phase.count - 1
                TTSLoudnessMeter.convolve(
                    source: input,
                    filter: phase,
                    count: tail,
                    destination: stageWork.base
                )
                measured = max(
                    measured,
                    TTSLoudnessMeter.maximumMagnitude(source: stageWork.base, count: tail)
                )
            }
            return measured
        }

        private mutating func advanceHistory(block: UnsafeBufferPointer<Double>) {
            let historyLength = Self.historySampleCount
            let incoming = Array(block.suffix(historyLength))
            let keep = max(0, historyLength - incoming.count)
            history = Array(history.suffix(keep)) + incoming
        }
    }
}
