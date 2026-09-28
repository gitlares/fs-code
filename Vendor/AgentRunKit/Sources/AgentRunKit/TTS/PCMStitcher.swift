import Foundation

enum PCMStitcher {
    private static let blockFrames = 4096
    private static let pcmScale = 32768.0

    static func stitch(
        segments: [Data],
        boundaries: [TTSBoundary],
        policy: TTSStitchPolicy,
        format: PCMFormat
    ) throws -> (audio: Data, ranges: [Range<Int>]) {
        precondition(segments.count == boundaries.count, "segments and boundaries must be aligned")
        var planner = try PCMSeam.Planner(format: format, policy: policy, totalSegments: segments.count)
        var audio = Data()
        audio.reserveCapacity(segments.reduce(0) { $0 + $1.count })
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(segments.count)
        for index in segments.indices {
            let layout = try planner.next(audio: segments[index], trailingBoundary: boundaries[index])
            try audio.append(render(audio: segments[index], layout: layout, gain: 1, format: format))
            ranges.append(layout.byteRange)
        }
        return (audio, ranges)
    }

    static func forEachSampleBlock(
        in audio: Data,
        format: PCMFormat,
        _ consume: (UnsafeMutableBufferPointer<Double>, Int) throws -> Void
    ) throws {
        let bytesPerFrame = format.bytesPerFrame
        let channels = format.channels
        guard !audio.isEmpty, audio.count.isMultiple(of: bytesPerFrame) else {
            throw TTSError.invalidConfiguration("stitching requires nonempty PCM aligned to whole 16-bit frames")
        }
        let frames = audio.count / bytesPerFrame
        var scratch = try [Double](repeating: 0, count: scratchCapacity(frames: frames, channels: channels))
        var offset = 0
        try audio.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            while offset < frames {
                try Task.checkCancellation()
                let count = min(blockFrames, frames - offset)
                for position in 0 ..< count {
                    decodeFrame(
                        bytes,
                        frame: offset + position,
                        channels: channels,
                        bytesPerFrame: bytesPerFrame,
                        into: &scratch,
                        slot: position * channels
                    )
                }
                try scratch[0 ..< count * channels].withUnsafeMutableBufferPointer { block in
                    try consume(block, offset)
                }
                offset += count
            }
        }
    }

    static func forEachRenderedBlock(
        in audio: Data,
        layout: PCMSeam.Layout,
        gain: Double,
        format: PCMFormat,
        _ consume: (UnsafeBufferPointer<Double>) throws -> Void
    ) throws {
        let bytesPerFrame = format.bytesPerFrame
        let channels = format.channels
        guard !audio.isEmpty, audio.count.isMultiple(of: bytesPerFrame) else {
            throw TTSError.invalidConfiguration("stitching requires nonempty PCM aligned to whole 16-bit frames")
        }
        guard audio.count / bytesPerFrame == layout.frameCount else {
            throw TTSError.invalidConfiguration("rendered layout does not match audio frame count")
        }
        guard gain.isFinite else {
            throw TTSError.invalidConfiguration("rendering requires a finite gain")
        }
        let (totalFrames, totalOverflow) = layout.leadingSilenceFrames.addingReportingOverflow(layout.frameCount)
        guard !totalOverflow else {
            throw TTSError.invalidConfiguration("rendered layout size is not representable")
        }
        var scratch = try [Double](repeating: 0, count: scratchCapacity(frames: totalFrames, channels: channels))
        var rendered = 0
        try audio.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            while rendered < totalFrames {
                try Task.checkCancellation()
                let count = min(blockFrames, totalFrames - rendered)
                for position in 0 ..< count {
                    renderFrame(
                        bytes,
                        outputFrame: rendered + position,
                        layout: layout,
                        gain: gain,
                        format: format,
                        into: &scratch,
                        slot: position * channels
                    )
                }
                try scratch.prefix(count * channels).withUnsafeBufferPointer { block in
                    try consume(block)
                }
                rendered += count
            }
        }
    }

    static func render(audio: Data, layout: PCMSeam.Layout, gain: Double, format: PCMFormat) throws -> Data {
        let (totalFrames, framesOverflow) = layout.leadingSilenceFrames.addingReportingOverflow(layout.frameCount)
        let (totalBytes, bytesOverflow) = totalFrames.multipliedReportingOverflow(by: format.bytesPerFrame)
        guard !framesOverflow, !bytesOverflow else {
            throw TTSError.invalidConfiguration("rendered layout size is not representable")
        }
        var output = Data()
        output.reserveCapacity(totalBytes)
        try forEachRenderedBlock(in: audio, layout: layout, gain: gain, format: format) { block in
            output.append(contentsOf: encode(block))
        }
        return output
    }

    private static func scratchCapacity(frames: Int, channels: Int) throws -> Int {
        let (capacity, overflow) = min(blockFrames, frames).multipliedReportingOverflow(by: channels)
        guard !overflow else {
            throw TTSError.invalidConfiguration("sample block size is not representable")
        }
        return capacity
    }

    private static func decodeFrame(
        _ bytes: UnsafeBufferPointer<UInt8>,
        frame: Int,
        channels: Int,
        bytesPerFrame: Int,
        into scratch: inout [Double],
        slot: Int
    ) {
        let base = frame * bytesPerFrame
        for channel in 0 ..< channels {
            let low = base + channel * 2
            let sample = Int16(bitPattern: UInt16(bytes[low]) | (UInt16(bytes[low + 1]) << 8))
            scratch[slot + channel] = Double(sample) / pcmScale
        }
    }

    private static func renderFrame(
        _ bytes: UnsafeBufferPointer<UInt8>,
        outputFrame: Int,
        layout: PCMSeam.Layout,
        gain: Double,
        format: PCMFormat,
        into scratch: inout [Double],
        slot: Int
    ) {
        guard outputFrame >= layout.leadingSilenceFrames else {
            for channel in 0 ..< format.channels {
                scratch[slot + channel] = 0
            }
            return
        }
        let sourceFrame = outputFrame - layout.leadingSilenceFrames
        let fade = renderedFade(sourceFrame: sourceFrame, layout: layout)
        let base = sourceFrame * format.bytesPerFrame
        for channel in 0 ..< format.channels {
            let low = base + channel * 2
            let sample = Int16(bitPattern: UInt16(bytes[low]) | (UInt16(bytes[low + 1]) << 8))
            scratch[slot + channel] = Double(sample) / pcmScale * fade * gain
        }
    }

    private static func renderedFade(sourceFrame: Int, layout: PCMSeam.Layout) -> Double {
        if layout.fadeInFrames > 0, sourceFrame < layout.fadeInFrames {
            return PCMSeam.fadeGain(step: sourceFrame, fade: layout.fadeInFrames)
        }
        let fadeOutStart = layout.frameCount - layout.fadeOutFrames
        if layout.fadeOutFrames > 0, sourceFrame >= fadeOutStart {
            return PCMSeam.fadeGain(step: layout.frameCount - 1 - sourceFrame, fade: layout.fadeOutFrames)
        }
        return 1
    }

    private static func encode(_ block: UnsafeBufferPointer<Double>) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: block.count * 2)
        for index in 0 ..< block.count {
            let scaled = (block[index] * pcmScale).rounded()
            let sample = if scaled >= Double(Int16.max) {
                Int16.max
            } else if scaled <= Double(Int16.min) {
                Int16.min
            } else {
                Int16(scaled)
            }
            let bits = UInt16(bitPattern: sample)
            bytes[index * 2] = UInt8(bits & 0x00FF)
            bytes[index * 2 + 1] = UInt8(bits >> 8)
        }
        return bytes
    }
}
