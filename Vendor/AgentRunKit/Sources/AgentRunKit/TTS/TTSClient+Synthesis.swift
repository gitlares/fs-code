import Foundation

private enum SegmentProcessor {
    case raw
    case plain(PCMFormat, PCMSeam.Planner)
    case recent(PCMFormat, TTSLoudnessMatcher.Running)

    init(policy: TTSStitchPolicy, format: PCMFormat, totalSegments: Int) throws {
        if let loudness = policy.loudness {
            self = try .recent(
                format,
                TTSLoudnessMatcher.Running(
                    format: format,
                    policy: policy,
                    loudness: loudness,
                    totalSegments: totalSegments
                )
            )
        } else {
            self = try .plain(format, PCMSeam.Planner(format: format, policy: policy, totalSegments: totalSegments))
        }
    }

    mutating func process(_ segment: TTSSegment) throws -> TTSSegment {
        switch self {
        case .raw:
            return segment
        case let .plain(format, planner):
            var planner = planner
            let layout = try planner.next(audio: segment.audio, trailingBoundary: segment.chunk.trailingBoundary)
            self = .plain(format, planner)
            return try TTSSegment(
                chunk: segment.chunk,
                encoding: segment.encoding,
                timing: .processedBody(byteRange: layout.byteRange, format: format),
                audio: PCMStitcher.render(audio: segment.audio, layout: layout, gain: 1, format: format)
            )
        case let .recent(format, running):
            var running = running
            let processed = try running.process(audio: segment.audio, trailingBoundary: segment.chunk.trailingBoundary)
            self = .recent(format, running)
            return TTSSegment(
                chunk: segment.chunk,
                encoding: segment.encoding,
                timing: .processedBody(byteRange: processed.range, format: format),
                audio: processed.audio
            )
        }
    }
}

extension TTSClient {
    enum ChunkFailureHandling {
        case failFast
        case collect
    }

    private enum ChunkAttempt {
        case success(TTSSegment)
        case failure(TTSChunkFailure)
    }

    func segmentStream(
        plan: [TTSChunk],
        voice: String,
        options: TTSOptions,
        encoding: TTSAudioEncoding,
        rendering: (policy: TTSStitchPolicy, format: PCMFormat)?
    ) -> AsyncThrowingStream<TTSSegment, Error> {
        let provider = provider
        let maxConcurrent = maxConcurrent
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var processor = try rendering.map {
                        try SegmentProcessor(policy: $0.policy, format: $0.format, totalSegments: plan.count)
                    } ?? .raw
                    _ = try await Self.runChunks(
                        plan,
                        voice: voice,
                        options: options,
                        encoding: encoding,
                        provider: provider,
                        maxConcurrent: maxConcurrent,
                        handling: .failFast,
                        onSegment: { segment in
                            try Task.checkCancellation()
                            let processed = try processor.process(segment)
                            try Task.checkCancellation()
                            if case .terminated = continuation.yield(processed) {
                                throw CancellationError()
                            }
                        }
                    )
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func runChunks(
        _ chunks: [TTSChunk],
        voice: String,
        options: TTSOptions,
        encoding: TTSAudioEncoding,
        provider: P,
        maxConcurrent: Int,
        handling: ChunkFailureHandling,
        onSegment: ((TTSSegment) throws -> Void)? = nil
    ) async throws -> (segments: [TTSSegment], failures: [TTSChunkFailure]) {
        try await withThrowingTaskGroup(of: ChunkAttempt.self) { group in
            var nextToSend = 0
            var activeTasks = 0
            var buffer: [Int: TTSSegment] = [:]
            var emitCursor = 0
            var segments: [TTSSegment] = []
            var failures: [TTSChunkFailure] = []

            while nextToSend < chunks.count || activeTasks > 0 {
                try Task.checkCancellation()
                while activeTasks < maxConcurrent, nextToSend < chunks.count {
                    let chunk = chunks[nextToSend]
                    let context = TTSChunkContext(chunk: chunk, encoding: encoding)
                    group.addTask {
                        do {
                            let data = try await provider.generate(
                                text: chunk.text,
                                voice: voice,
                                options: options,
                                context: context
                            )
                            return .success(TTSSegment(
                                chunk: chunk,
                                encoding: encoding,
                                timing: .uncomputed,
                                audio: data
                            ))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as TransportError {
                            return .failure(TTSChunkFailure(chunk: chunk, encoding: encoding, error: error))
                        } catch {
                            return .failure(TTSChunkFailure(
                                chunk: chunk,
                                encoding: encoding,
                                error: .other(String(describing: error))
                            ))
                        }
                    }
                    nextToSend += 1
                    activeTasks += 1
                }

                guard let attempt = try await group.next() else { break }
                activeTasks -= 1
                try Task.checkCancellation()

                switch attempt {
                case let .success(segment):
                    if let onSegment {
                        buffer[segment.index] = segment
                        while let next = buffer.removeValue(forKey: emitCursor) {
                            try onSegment(next)
                            emitCursor += 1
                        }
                    } else {
                        segments.append(segment)
                    }
                case let .failure(failure):
                    if handling == .failFast {
                        throw TTSError.chunkFailed(
                            index: failure.index,
                            total: failure.total,
                            sourceRange: failure.sourceRange,
                            failure.error
                        )
                    }
                    failures.append(failure)
                }
            }

            return (segments, failures)
        }
    }
}
