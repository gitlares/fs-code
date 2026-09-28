import Foundation

/// An opt-in policy for assembling PCM chunks into one stream with boundary-keyed pauses and join fades.
public struct TTSStitchPolicy: Sendable, Equatable, Hashable, Codable {
    /// Soft character target the chunker fills toward before cutting at a sentence boundary,
    /// or nil to pack greedily to the provider maximum.
    public let targetCharacters: Int?
    /// Whether to extend past the target to cut on a paragraph boundary when one is in reach.
    public let preferParagraphBoundaries: Bool
    /// Minimum boundary quiet where a chunk ends a sentence.
    public let sentencePause: Duration
    /// Minimum boundary quiet where a chunk ends a paragraph.
    public let paragraphPause: Duration
    /// Edge fade applied at internal joins with non-quiet edges, using the full fade beside a positive
    /// quiet budget and at most 1 ms at direct joins.
    public let joinFade: Duration
    /// Loudness matching applied across the assembled PCM chunks, or nil to leave levels untouched.
    public let loudness: TTSLoudnessMatch?

    public init(
        targetCharacters: Int? = nil,
        preferParagraphBoundaries: Bool = false,
        sentencePause: Duration = .zero,
        paragraphPause: Duration = .zero,
        joinFade: Duration = .zero,
        loudness: TTSLoudnessMatch? = nil
    ) {
        if let targetCharacters {
            precondition(targetCharacters >= 1, "targetCharacters must be at least 1")
        }
        precondition(sentencePause >= .zero, "sentencePause must not be negative")
        precondition(paragraphPause >= .zero, "paragraphPause must not be negative")
        precondition(joinFade >= .zero, "joinFade must not be negative")
        self.targetCharacters = targetCharacters
        self.preferParagraphBoundaries = preferParagraphBoundaries
        self.sentencePause = sentencePause
        self.paragraphPause = paragraphPause
        self.joinFade = joinFade
        self.loudness = loudness
    }

    private enum CodingKeys: String, CodingKey {
        case targetCharacters
        case preferParagraphBoundaries
        case sentencePause
        case paragraphPause
        case joinFade
        case loudness
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let targetCharacters = try container.decodeIfPresent(Int.self, forKey: .targetCharacters)
        let preferParagraphBoundaries = try container.decode(Bool.self, forKey: .preferParagraphBoundaries)
        let sentencePause = try container.decode(Duration.self, forKey: .sentencePause)
        let paragraphPause = try container.decode(Duration.self, forKey: .paragraphPause)
        let joinFade = try container.decode(Duration.self, forKey: .joinFade)
        let loudness = try container.decodeIfPresent(TTSLoudnessMatch.self, forKey: .loudness)
        if let targetCharacters, targetCharacters < 1 {
            throw DecodingError.dataCorruptedError(
                forKey: .targetCharacters, in: container,
                debugDescription: "targetCharacters must be at least 1"
            )
        }
        guard sentencePause >= .zero else {
            throw DecodingError.dataCorruptedError(
                forKey: .sentencePause, in: container,
                debugDescription: "sentencePause must not be negative"
            )
        }
        guard paragraphPause >= .zero else {
            throw DecodingError.dataCorruptedError(
                forKey: .paragraphPause, in: container,
                debugDescription: "paragraphPause must not be negative"
            )
        }
        guard joinFade >= .zero else {
            throw DecodingError.dataCorruptedError(
                forKey: .joinFade, in: container,
                debugDescription: "joinFade must not be negative"
            )
        }
        self.init(
            targetCharacters: targetCharacters,
            preferParagraphBoundaries: preferParagraphBoundaries,
            sentencePause: sentencePause,
            paragraphPause: paragraphPause,
            joinFade: joinFade,
            loudness: loudness
        )
    }
}
