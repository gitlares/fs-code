import Foundation

enum PCMSeam {
    struct Layout: Equatable {
        let frameCount: Int
        let leadingSilenceFrames: Int
        let fadeInFrames: Int
        let fadeOutFrames: Int
        let byteRange: Range<Int>
    }

    struct Planner {
        private let format: PCMFormat
        private let sentencePauseFrames: Int
        private let paragraphPauseFrames: Int
        private let requestedFadeFrames: Int
        private let directFadeCapFrames: Int
        private let minimumQuietFrames: Int
        private let scanLimitFrames: Int
        private let totalSegments: Int
        private var emittedCount = 0
        private var previousBoundary: TTSBoundary = .end
        private var previousTrailingQuiet = 0
        private var cursorBytes = 0

        init(format: PCMFormat, policy: TTSStitchPolicy, totalSegments: Int) throws {
            sentencePauseFrames = try PCMSeam.frameCount(policy.sentencePause, sampleRate: format.sampleRate)
            paragraphPauseFrames = try PCMSeam.frameCount(policy.paragraphPause, sampleRate: format.sampleRate)
            requestedFadeFrames = try PCMSeam.frameCount(policy.joinFade, sampleRate: format.sampleRate)
            directFadeCapFrames = try PCMSeam.frameCount(.milliseconds(1), sampleRate: format.sampleRate)
            minimumQuietFrames = try PCMSeam.frameCount(.milliseconds(2), sampleRate: format.sampleRate)
            scanLimitFrames = max(
                sentencePauseFrames, paragraphPauseFrames, requestedFadeFrames, minimumQuietFrames
            )
            self.format = format
            self.totalSegments = totalSegments
        }

        mutating func next(audio: Data, trailingBoundary: TTSBoundary) throws -> Layout {
            guard emittedCount < totalSegments else {
                throw TTSError.invalidConfiguration("seam planner received more segments than declared")
            }
            let bytesPerFrame = format.bytesPerFrame
            guard !audio.isEmpty, audio.count.isMultiple(of: bytesPerFrame) else {
                throw TTSError.invalidConfiguration("stitching requires nonempty PCM aligned to whole 16-bit frames")
            }
            let frames = audio.count / bytesPerFrame
            let leadingQuiet = PCMSeam.leadingQuietFrames(in: audio, format: format, limit: scanLimitFrames)
            let trailingQuiet = PCMSeam.trailingQuietFrames(in: audio, format: format, limit: scanLimitFrames)
            let gap = leadingGap(leadingQuiet: leadingQuiet)
            let byteRange = try bodyRange(audioBytes: audio.count, gapFrames: gap, bytesPerFrame: bytesPerFrame)
            let (fadeIn, fadeOut) = fades(frames: frames, audio: audio, trailingBoundary: trailingBoundary)
            previousBoundary = trailingBoundary
            previousTrailingQuiet = trailingQuiet >= minimumQuietFrames ? trailingQuiet : 0
            cursorBytes = byteRange.upperBound
            emittedCount += 1
            return Layout(
                frameCount: frames,
                leadingSilenceFrames: gap,
                fadeInFrames: fadeIn,
                fadeOutFrames: fadeOut,
                byteRange: byteRange
            )
        }

        private func leadingGap(leadingQuiet: Int) -> Int {
            guard emittedCount > 0 else { return 0 }
            let requested = PCMSeam.pauseFrames(
                for: previousBoundary,
                sentence: sentencePauseFrames,
                paragraph: paragraphPauseFrames
            )
            let creditedLeading = leadingQuiet >= minimumQuietFrames ? leadingQuiet : 0
            return max(0, requested - previousTrailingQuiet - creditedLeading)
        }

        private func bodyRange(audioBytes: Int, gapFrames: Int, bytesPerFrame: Int) throws -> Range<Int> {
            let (gapBytes, gapOverflow) = gapFrames.multipliedReportingOverflow(by: bytesPerFrame)
            let (lower, lowerOverflow) = cursorBytes.addingReportingOverflow(gapBytes)
            let (upper, upperOverflow) = lower.addingReportingOverflow(audioBytes)
            guard !gapOverflow, !lowerOverflow, !upperOverflow else {
                throw TTSError.invalidConfiguration("stitched program size is not representable as bytes")
            }
            return lower ..< upper
        }

        private func fades(frames: Int, audio: Data, trailingBoundary: TTSBoundary) -> (Int, Int) {
            let fadeIn = incomingFade(audio: audio)
            let fadeOut = outgoingFade(frames: frames, audio: audio, trailingBoundary: trailingBoundary)
            if fadeIn > 0, fadeOut > 0 {
                let cap = (frames - 1) / 2
                return (min(fadeIn, cap), min(fadeOut, cap))
            }
            if fadeIn > 0 {
                return (min(fadeIn, frames - 1), 0)
            }
            return (0, min(fadeOut, frames - 1))
        }

        private func incomingFade(audio: Data) -> Int {
            guard emittedCount > 0 else { return 0 }
            let requested = PCMSeam.pauseFrames(
                for: previousBoundary,
                sentence: sentencePauseFrames,
                paragraph: paragraphPauseFrames
            )
            let budget = requested > 0 ? requestedFadeFrames : min(requestedFadeFrames, directFadeCapFrames)
            guard budget > 0, !PCMSeam.isQuietFrame(at: 0, in: audio, format: format) else { return 0 }
            return budget
        }

        private func outgoingFade(frames: Int, audio: Data, trailingBoundary: TTSBoundary) -> Int {
            guard emittedCount < totalSegments - 1 else { return 0 }
            let requested = PCMSeam.pauseFrames(
                for: trailingBoundary,
                sentence: sentencePauseFrames,
                paragraph: paragraphPauseFrames
            )
            let budget = requested > 0 ? requestedFadeFrames : min(requestedFadeFrames, directFadeCapFrames)
            guard budget > 0, !PCMSeam.isQuietFrame(at: frames - 1, in: audio, format: format) else { return 0 }
            return budget
        }
    }

    static func frameCount(_ duration: Duration, sampleRate: Int) throws -> Int {
        guard duration > .zero else { return 0 }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let frames = (seconds * Double(sampleRate)).rounded()
        guard frames >= 1 else { return 0 }
        guard let count = Int(exactly: frames) else {
            throw TTSError.invalidConfiguration("requested audio duration is not representable as PCM frames")
        }
        return count
    }

    static func fadeGain(step: Int, fade: Int) -> Double {
        precondition(fade >= 1 && step >= 0 && step < fade, "fade step must lie within a nonempty fade")
        guard fade > 1 else { return 0 }
        let position = Double(step) / Double(fade - 1)
        return position * position * (3 - 2 * position)
    }

    static func pauseFrames(for boundary: TTSBoundary, sentence: Int, paragraph: Int) -> Int {
        switch boundary {
        case .sentence: sentence
        case .paragraph: paragraph
        case .withinSentence, .end: 0
        }
    }

    private static let quietSampleLimit = 32

    private static func leadingQuietFrames(in audio: Data, format: PCMFormat, limit: Int) -> Int {
        let frames = audio.count / format.bytesPerFrame
        let scan = min(limit, frames)
        guard scan > 0 else { return 0 }
        return audio.withUnsafeBytes { raw in
            var quiet = 0
            while quiet < scan,
                  isQuietFrame(raw, frame: quiet, bytesPerFrame: format.bytesPerFrame, channels: format.channels) {
                quiet += 1
            }
            return quiet
        }
    }

    private static func trailingQuietFrames(in audio: Data, format: PCMFormat, limit: Int) -> Int {
        let frames = audio.count / format.bytesPerFrame
        let scan = min(limit, frames)
        guard scan > 0 else { return 0 }
        return audio.withUnsafeBytes { raw in
            var quiet = 0
            while quiet < scan,
                  isQuietFrame(
                      raw,
                      frame: frames - 1 - quiet,
                      bytesPerFrame: format.bytesPerFrame,
                      channels: format.channels
                  ) {
                quiet += 1
            }
            return quiet
        }
    }

    private static func isQuietFrame(at frame: Int, in audio: Data, format: PCMFormat) -> Bool {
        audio.withUnsafeBytes { raw in
            isQuietFrame(raw, frame: frame, bytesPerFrame: format.bytesPerFrame, channels: format.channels)
        }
    }

    private static func isQuietFrame(
        _ bytes: UnsafeRawBufferPointer,
        frame: Int,
        bytesPerFrame: Int,
        channels: Int
    ) -> Bool {
        let base = frame * bytesPerFrame
        for channel in 0 ..< channels {
            let offset = base + channel * 2
            let sample = Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
            guard abs(Int(sample)) <= quietSampleLimit else { return false }
        }
        return true
    }
}
