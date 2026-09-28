# Multimodal and Audio

Send images, video, PDFs, and audio as input. Stream audio output from the model. Generate speech with ``TTSClient``.

## Multimodal Input

``ContentPart`` represents a single piece of content within a user message. Six variants cover text and media:

| Variant | Factory Method |
|---|---|
| `.text(String)` | Direct case |
| `.imageURL(String)` | ``ContentPart/image(url:)`` |
| `.imageBase64(data:mimeType:)` | ``ContentPart/image(data:mimeType:)`` |
| `.videoBase64(data:mimeType:)` | ``ContentPart/video(data:mimeType:)`` |
| `.pdfBase64(data:)` | ``ContentPart/pdf(data:)`` |
| `.audioBase64(data:format:)` | ``ContentPart/audio(data:format:)`` |

Build multimodal messages with ``ChatMessage`` convenience methods:

```swift
// Image from URL
let msg = ChatMessage.user(text: "Describe this image.", imageURL: "https://example.com/photo.jpg")

// Image from raw bytes
let msg = ChatMessage.user(text: "What's in this photo?", imageData: jpegData, mimeType: "image/jpeg")

// Video
let msg = ChatMessage.user(text: "Summarize this clip.", videoData: mp4Data, mimeType: "video/mp4")

// Audio with text prompt
let msg = ChatMessage.user(text: "Transcribe this.", audioData: wavData, format: .wav)

// Audio only
let msg = ChatMessage.user(audioData: wavData, format: .wav)
```

For full control, pass an array of ``ContentPart`` values directly:

```swift
let msg = ChatMessage.user([
    .text("Compare these two images."),
    .image(url: "https://example.com/a.jpg"),
    .image(data: localPNG, mimeType: "image/png"),
])
```

``AudioInputFormat`` supports: `wav`, `mp3`, `m4a`, `flac`, `ogg`, `opus`, `webm`. Each case provides a `mimeType` property for wire format encoding.

## Per-Provider Encoding

Each client encodes ``ContentPart`` onto its native wire format. Encoding and accepted media types vary:

| Provider | Images | Audio | Video | PDF | Wire format |
|---|---|---|---|---|---|
| ``OpenAIClient`` | URL, base64 | Yes | No | No | `content: [{type: "image_url" \| ...}]` |
| ``ResponsesAPIClient`` | URL, base64 | No | No | No | `content: [{type: "input_image" \| ...}]` |
| ``AnthropicClient`` | base64 | No | No | base64 | `content: [{type: "image" \| "document", source: {type: "base64", media_type, data}}]` |
| ``VertexAnthropicClient`` | base64 | No | No | base64 | same as ``AnthropicClient`` |
| ``GeminiClient`` | base64 | base64 | base64 | base64 | `parts: [{inlineData: {mimeType, data}}]` |
| ``VertexGoogleClient`` | base64 | base64 | base64 | base64 | same as ``GeminiClient`` |

Anthropic and Gemini reject raw image URLs because neither provider fetches external URLs server-side. Passing an `.imageURL` part to either client throws ``TransportError/featureUnsupported(provider:feature:)`` at request build. Fetch the bytes yourself and pass them as `.imageBase64`.

## Audio Streaming Output

Some providers (OpenAI) can stream audio alongside text. Three ``StreamEvent`` cases carry audio data:

| Event | Description |
|---|---|
| `.audioData(Data)` | A chunk of audio bytes, delivered incrementally |
| `.audioTranscript(String)` | Text transcript of the generated audio |
| `.audioFinished(id:expiresAt:data:)` | Final audio payload with metadata |

Enable audio output by passing `modalities` and `audio` configuration through ``RequestContext`` extra fields:

```swift
let requestContext = RequestContext(extraFields: [
    "modalities": .array([.string("text"), .string("audio")]),
    "audio": .object([
        "voice": .string("alloy"),
        "format": .string("pcm16"),
    ]),
])

for try await event in agent.stream(userMessage: "Tell me a story.", context: ctx, requestContext: requestContext) {
    switch event.kind {
    case .audioData(let chunk):
        audioPlayer.enqueue(chunk)
    case .audioTranscript(let text):
        print(text)
    case .audioFinished(_, _, let fullAudio):
        audioPlayer.finalize(fullAudio)
    default:
        break
    }
}
```

## Text-to-Speech

``TTSClient`` generates speech from text using any ``TTSProvider``. It handles chunking, concurrent generation, and ordered reassembly.

### Setup

```swift
let provider = OpenAITTSProvider(apiKey: "sk-...", model: "gpt-4o-mini-tts")
let tts = TTSClient(provider: provider, maxConcurrent: 4)
```

``OpenAITTSProvider`` accepts `baseURL`, `maxChunkCharacters`, `defaultVoice`, and `defaultFormat` in its initializer. AgentRunKit currently defaults the `model` parameter to `tts-1`, but OpenAI's current recommended speech-generation model is `gpt-4o-mini-tts`. The other defaults are voice `alloy`, format `.mp3`, and chunk size `4096`.

### Generating Audio

These methods cover different use cases:

| Method | Returns | Behavior |
|---|---|---|
| `generate(text:voice:options:)` | `Data` | Single request, no chunking |
| `stream(text:voice:options:stitch:)` | `AsyncThrowingStream<TTSSegment, Error>` | Chunked, yields ordered ``TTSSegment`` values as provider requests complete, optionally processed through a ``TTSStitchPolicy`` |
| `generateAll(text:voice:options:stitch:)` | `Data` | Chunked, concatenates all segments into one `Data`, stitched when a policy is supplied |
| `generateWithManifest(text:voice:options:stitch:)` | ``TTSConcatenationResult`` | Like `generateAll` but also returns a per-segment manifest; an optional ``TTSStitchPolicy`` stitches PCM with boundary-keyed pauses |
| `generateBatch(text:voice:options:stitch:)` | ``TTSBatchResult`` | Chunked, preserves completed segments and reports per-chunk failures instead of throwing |
| `chunks(for:stitch:)` | `[TTSChunk]` | The chunk plan this client will use for the input and optional policy, without invoking the provider |

```swift
// Single generation
let audio = try await tts.generate(text: "Hello, world.", voice: "nova")

// Streaming segments as each provider request completes
for try await segment in tts.stream(text: longArticle) {
    player.play(segment.audio)
    let chunk = segment.chunk
    print("chunk \(chunk.index + 1)/\(chunk.total) bytes \(chunk.sourceRange): \(chunk.text)")
}

// Full concatenated output
let fullAudio = try await tts.generateAll(text: longArticle, options: TTSOptions(speed: 1.25))

// Concatenated audio plus a per-segment manifest
let result = try await tts.generateWithManifest(text: longArticle, options: TTSOptions(responseFormat: .pcm))
for entry in result.manifest {
    if let range = entry.timing.byteRangeInConcatenatedAudio {
        print("chunk \(entry.chunk.index): bytes \(range) of result.audio")
    }
    if let duration = entry.timing.durationSeconds {
        print("chunk \(entry.chunk.index): \(duration) seconds")
    }
}

// Forecast the chunk plan without generating audio
let plan = tts.chunks(for: longArticle)
```

`generateAll` is implemented on top of the same path and returns `result.audio`.

Without a policy, `stream` segments carry ``TTSSegmentTiming/uncomputed`` timing and the raw chunk
bytes. With a policy, each segment's `audio` is processed and playable on its own: it begins with any
silence inserted before that chunk's body, while ``TTSSegmentTiming/byteRangeInConcatenatedAudio``
identifies only the processed body in the virtual concatenation of every emitted `audio` and
`durationSeconds` covers that body alone. Play or concatenate the `audio` buffers as delivered to
hear every pause; use the ranges when you need source-body slices. Streaming yields each processed
segment only after that chunk's provider request returns a complete response, so first-audio latency
is bounded below by the first request's completion, not by a packet-level stream. Consumers own
playback and storage; the library returns bytes and metadata only.

#### Supported Timing

| Format | Byte range | Duration |
|---|---:|---:|
| `pcm`  | yes | yes, when the provider supplies sample rate, channels, and bits per sample |
| `mp3`  | yes (accounts for ID3v2, Xing/Info, and ID3v1 stripping) | not supported |
| `wav`, `flac`, `opus`, `aac` | not supported | not supported |

Unsupported values are reported as `nil` rather than guessed. Duration for `pcm` is computed as
`bytes / (sampleRate * channels * (bitsPerSample / 8))` when the provider's
``TTSProvider/resolvedEncoding(for:options:)`` returns a fully populated ``TTSAudioEncoding``.
Built-in providers override the hook only with values they have published documentation for.
``OpenAITTSProvider`` populates `pcm` `sampleRate` (24000), `channels` (1, mono), and `bitsPerSample`
(16) from OpenAI's `/v1/audio/speech` documentation, so OpenAI `pcm` segments carry a computed
`durationSeconds`. Custom providers using the protocol's default implementation report `nil` PCM
fields and therefore `nil` duration.

### TTSOptions

``TTSOptions`` controls per-request parameters:

- `speed`: Playback speed multiplier. OpenAI accepts 0.25 to 4.0.
- `responseFormat`: Override the provider's default format. See ``TTSAudioFormat`` (`mp3`, `opus`, `aac`, `flac`, `wav`, `pcm`).

### How Chunking Works

The chunker splits input text on sentence boundaries using `NLTokenizer`. Sentences are packed up to
the provider's `maxChunkCharacters` limit. Oversized sentences fall back to word-level, then
character-level splitting. Every ``TTSChunk`` records the ``TTSBoundary`` immediately following it
(sentence, paragraph, within-sentence, or end), classified from the original text so callers and the
stitcher can tell where one sentence or paragraph ends and the next begins. Blank-line whitespace is
folded into the adjacent chunk, so a chunk is never pure whitespace.

``TTSClient`` dispatches up to `maxConcurrent` chunk requests in parallel. Results are buffered and
yielded in original order.

Each ``TTSSegment`` carries a ``TTSChunk``, a ``TTSAudioEncoding``, a ``TTSSegmentTiming``, and the
audio bytes. The chunk, encoding, and timing fields are the canonical access path; flat properties
on ``TTSSegment`` forward to the chunk for compact logging.

For force-split chunks, `text` normalizes whitespace to single spaces while `sourceRange` covers the
span of the words it contains. That keeps ranges monotonic for caller-side highlighting and forced
alignment.

``TTSClient/chunks(for:stitch:)`` returns the same ``TTSChunk`` values the stream will emit for the
same policy, without calling the provider. Use it to forecast chunk identity before generation or to
drive offline planning; `targetCharacters` and `preferParagraphBoundaries` from the policy steer this
plan exactly as they steer generation.

``TTSConcatenationResult`` and ``TTSManifestEntry`` pair concatenated audio bytes with a per-segment
manifest of chunk, encoding, and timing.

For MP3 output, the concatenator strips ID3v2 headers, Xing/Info frames, and ID3v1 tails from interior segments for clean concatenation.

### Stitching PCM

Long narration assembled from short chunks has audible seams: independent draws joined with no gap,
and no end-of-sentence or end-of-paragraph pause, because each chunk was synthesized without the
surrounding structure. Pass a ``TTSStitchPolicy`` to
``TTSClient/generateWithManifest(text:voice:options:stitch:)`` to assemble 16-bit PCM into one stream
with boundary-keyed pauses and edge fades, or to ``TTSClient/stream(text:voice:options:stitch:)`` to
process each chunk the same way as it completes.

```swift
let policy = TTSStitchPolicy(
    targetCharacters: 240,
    preferParagraphBoundaries: true,
    sentencePause: .milliseconds(220),
    paragraphPause: .milliseconds(600),
    joinFade: .milliseconds(6)
)
let result = try await tts.generateWithManifest(
    text: script,
    options: TTSOptions(responseFormat: .pcm),
    stitch: policy
)
```

The policy couples two decisions. `targetCharacters` and `preferParagraphBoundaries` steer the chunker
to fill toward a soft size target and cut on a sentence or, when one is near, a paragraph boundary
detected in the input text. `sentencePause` and `paragraphPause` are
minimum boundary-quiet budgets: quiet already present at the chunk edges counts toward the budget, and
only the deficit is inserted. Every source frame is preserved, including breaths and longer pauses, so a
boundary that already carries enough quiet gains no extra silence. This deficit accounting intentionally
replaces always-added pauses.
Within-sentence seams, from an oversized sentence, are joined directly with no pause. At any internal
join, each edge receives the full `joinFade` beside a positive quiet budget and at most 1 ms at a direct
join, unless that edge's endpoint frame is already quiet. Fades never touch the outer program
start or end and always leave at least one source frame untouched; a zero
`joinFade` remains a real no-op.

The manifest stays truthful: each ``TTSSegmentTiming/byteRangeInConcatenatedAudio`` still covers that
segment's processed body, inserted pauses are the gaps between consecutive ranges, and
`durationSeconds` reflects the stitched output. Stitching is deterministic for identical raw segments
and policy. It requires 16-bit PCM with a known sample rate and channel count; any other output throws
``TTSError/invalidConfiguration(_:)``. Without a policy,
``TTSClient/generateWithManifest(text:voice:options:stitch:)`` concatenates the segments raw, exactly
as ``TTSClient/generateAll(text:voice:options:stitch:)`` does.

A processed stream follows the same layout per segment: the emitted `audio` begins with the silence
inserted before that chunk, so playing each buffer in order reproduces the stitched program with
every pause, while the timing range covers the body only. Treat processed stream output as final
audio: do not feed it back through ``TTSClient/stitch(segments:policy:)`` as though it were raw
provider audio, because the pauses and fades would be applied twice.

### Matching Loudness

Each chunk is an independent draw, so loudness can wander from one to the next. Set
``TTSStitchPolicy/loudness`` to level the chunks to a consistent loudness without flattening the
performance.

```swift
let policy = TTSStitchPolicy(
    sentencePause: .milliseconds(220),
    loudness: TTSLoudnessMatch(maxCorrectionDB: 3)
)
let result = try await tts.generateWithManifest(
    text: script,
    options: TTSOptions(responseFormat: .pcm),
    stitch: policy
)
if let achievedLUFS = result.loudness?.achievedLUFS {
    print("program loudness: \(achievedLUFS) LUFS")
}
```

The pass measures each chunk's gated integrated loudness (ITU-R BS.1770), anchors to the program
median, and applies one scalar gain per chunk bounded by `maxCorrectionDB`. A single per-chunk gain
corrects the per-draw offset while leaving the chunk's own dynamics intact, and the clamp keeps every
correction small enough that a genuinely soft chunk is never forced up to match a loud one. A
true-peak guard then attenuates the whole program if its oversampled true peak would exceed
`truePeakCeilingDBTP`. All correction happens in floating point over bounded sample scratch. The
retained input and output bytes, per-chunk readings, gains, layouts, and scalar gating statistics
grow with program length; only the waveform scratch is bounded. The program is quantized to 16-bit
PCM once with saturation, so no intermediate stage clips or rounds to integers.

``TTSLoudnessMatch/target`` selects the anchor. `.programMedian` levels the chunks to each other and
imposes no absolute level. `.recentMedian` levels each chunk against the latest measurable chunks in
source order. `.lufs(_:)` additionally shifts the whole program to an absolute loudness,
for example -16 LUFS for podcast delivery. Because the program is mono, that figure is the one-channel
file's loudness; a player that renders it as dual-mono stereo reads it about 3 dB louder. When the
true-peak ceiling forces the program below an absolute target the shortfall is reported, never hidden:
``TTSLoudnessSummary/achievedLUFS`` is where the program actually landed and
``TTSLoudnessSummary/appliedTrimDB`` is how far the guard pulled it down.

`.recentMedian` is the causal alternative to a program anchor: every chunk is leveled to the robust
median of the latest five measurable chunk readings in source order, including its own, so the
correction needs no lookahead beyond the current chunk. Short or silent chunks stay out of that
history and receive no differential gain. Peak protection is per chunk in this mode, holding each
chunk and its joins under `truePeakCeilingDBTP`, and the chunk's
``TTSLoudnessMeasurement/appliedGainDB`` includes that peak attenuation. No uniform trim is applied,
so ``TTSLoudnessSummary/requestedTargetLUFS`` is nil and ``TTSLoudnessSummary/appliedTrimDB`` is zero
while ``TTSLoudnessSummary/achievedLUFS`` and ``TTSLoudnessSummary/truePeakDBTP`` still measure the
delivered bytes.

Loudness matching populates the manifest with its own measurements. Each ``TTSManifestEntry/loudness``
carries the segment's measured loudness and the gain applied, and ``TTSConcatenationResult/loudness``
carries the program-level outcome, so the correction is auditable from the result alone. Those
program figures describe the delivered bytes: ``TTSLoudnessSummary/achievedLUFS`` and
``TTSLoudnessSummary/truePeakDBTP`` are measured from the returned PCM, and the peak ceiling
reserves headroom for the worst-case quantization error of the oversampling filter. A ceiling with no
representable headroom throws ``TTSError/invalidConfiguration(_:)`` instead of clipping, as does an
absolute target with no measurable delivered output. The pass
requires mono 16-bit PCM at 8 kHz or above and runs through
``TTSClient/generateWithManifest(text:voice:options:stitch:)`` or ``TTSClient/stitch(segments:policy:)``.
The default ceiling is the EBU R128 production value of -1 dBTP.

Choose the target by the surface you are driving. Whole-program targets (`.programMedian`,
`.lufs(_:)`) need the complete program and belong on finalized output; ``TTSClient/stream(text:voice:options:stitch:)``
rejects them before any provider request. Live chunk processing uses `.recentMedian`, which is causal
and produces identical audio when the same raw segments and policy are streamed or rendered afterward:

```swift
// Live: level each chunk as it completes against the latest measurable chunks.
let livePolicy = TTSStitchPolicy(
    sentencePause: .milliseconds(220),
    loudness: TTSLoudnessMatch(target: .recentMedian, maxCorrectionDB: 3)
)
for try await segment in tts.stream(text: script, options: TTSOptions(responseFormat: .pcm), stitch: livePolicy) {
    player.enqueue(segment.audio)
}

// Finalized: anchor the whole program and optionally hit an absolute delivery target.
let finalPolicy = TTSStitchPolicy(
    sentencePause: .milliseconds(220),
    loudness: TTSLoudnessMatch(target: .lufs(-16), maxCorrectionDB: 3)
)
let result = try await tts.generateWithManifest(
    text: script,
    options: TTSOptions(responseFormat: .pcm),
    stitch: finalPolicy
)
```

Scalar loudness matching and seam treatment correct levels and joins only. They cannot repair the
synthesizer's pronunciation, prosody, or voice quality, and a streamed segment is complete provider
audio: playback can begin only after that chunk's request finishes, so delivery latency is
chunk-complete rather than incremental.

### Recovering from Partial Failure

``TTSClient/stream(text:voice:options:stitch:)`` yields each chunk in order as results arrive, so
segments already delivered stand when a later chunk fails; the failure still ends the stream with an
error. ``TTSClient/generateAll(text:voice:options:stitch:)`` and
``TTSClient/generateWithManifest(text:voice:options:stitch:)`` are all-or-nothing: one chunk's failure
throws and the completed segments are not returned. For long inputs, where re-running the whole
batch re-bills the good chunks, use ``TTSClient/generateBatch(text:voice:options:stitch:)``. It returns
a ``TTSBatchResult`` that preserves every completed ``TTSSegment`` and reports each failed chunk as a
``TTSChunkFailure`` keyed by chunk index rather than completion order. Empty text and invalid
configuration throw before any synthesis, while cancellation still escapes as `CancellationError`.
Batch and retry results always carry the raw provider bytes, even when a policy is supplied, so they
remain valid recovery input: reassemble them with ``TTSClient/stitch(segments:policy:)`` after
retrying, and never substitute already-processed stream output for raw segments in that step.

Recover by re-running just the failed chunks, merging, then assembling. Keep one PCM request
configuration for the batch and its retry so the recovered chunks share the stitched encoding — the
default OpenAI format is MP3, which stitching rejects before any synthesis:

```swift
let pcm = TTSOptions(responseFormat: .pcm)
let batch = try await tts.generateBatch(text: longArticle, options: pcm, stitch: policy)
let whole: TTSBatchResult
if batch.isComplete {
    whole = batch
} else {
    let retry = try await tts.generate(chunks: batch.failedChunks, options: pcm)
    whole = try batch.merging(retry)
}
let result = try tts.stitch(segments: whole.completedSegments, policy: policy)
```

``TTSClient/generate(chunks:voice:options:)`` re-runs exactly the chunks you pass and reports their
outcomes, so the caller owns the retry policy. ``TTSBatchResult/merging(_:)`` folds a retry into the
prior result and refuses to overwrite a completed chunk. ``TTSClient/concatenate(segments:)`` and
``TTSClient/stitch(segments:policy:)`` reassemble a complete, gap-free segment set; a hole or mixed
encodings throws ``TTSError/invalidConfiguration(_:)``. Loudness is re-derived over the segments you
pass, so stitching the complete recovered set reproduces the program a single uninterrupted run makes.

### Custom Providers

Conform to ``TTSProvider`` to use any speech synthesis backend. ``TTSClient`` delivers a
``TTSChunkContext`` carrying the chunk plan and requested encoding alongside each call. Providers
should treat `context.encoding` as the authoritative source for the format to produce, and can
additionally use it for logging or request correlation.

Override ``TTSProvider/resolvedEncoding(for:options:)`` to surface documented `pcm` sample rate,
channel count, and bit depth so the framework can compute ``TTSSegmentTiming/durationSeconds`` for
`pcm` segments. The default implementation returns ``TTSAudioEncoding`` with `nil` PCM fields, so
providers without published encoding values can omit it.

```swift
struct MyTTSProvider: TTSProvider {
    let config: TTSProviderConfig

    func resolvedEncoding(for format: TTSAudioFormat, options: TTSOptions) -> TTSAudioEncoding {
        switch format {
        case .pcm:
            TTSAudioEncoding(format, sampleRate: 24000, channels: 1, bitsPerSample: 16)
        case .mp3, .opus, .aac, .flac, .wav:
            TTSAudioEncoding(format)
        }
    }

    func generate(
        text: String,
        voice: String,
        options: TTSOptions,
        context: TTSChunkContext
    ) async throws -> Data {
        let chunkID = "\(context.chunk.index + 1)/\(context.chunk.total)"
        log("synthesizing \(chunkID) as \(context.encoding.mimeType)")
        // Call your speech API and return audio bytes
    }
}

let provider = MyTTSProvider(config: TTSProviderConfig(
    maxChunkCharacters: 2000,
    defaultVoice: "default",
    defaultFormat: .wav
))
let tts = TTSClient(provider: provider)
```

For HTTP-backed providers, ``HTTPDataRetry`` exposes the same retry primitive
``OpenAITTSProvider`` uses: exponential backoff with jitter and `Retry-After`-aware handling of
429 responses. Pass a ``RetryPolicy`` and receive `(Data, HTTPURLResponse)` on success or a
``TransportError`` on failure; cancellation propagates through `CancellationError`.

```swift
let (data, response) = try await HTTPDataRetry.perform(
    urlRequest: request,
    session: .shared,
    retryPolicy: .default
)
```

## See Also

- <doc:AgentAndChat>
- <doc:LLMProviders>
- ``ContentPart``
- ``ChatMessage``
- ``AudioInputFormat``
- ``StreamEvent``
- ``TTSClient``
- ``TTSProvider``
- ``OpenAITTSProvider``
- ``TTSSegment``
- ``TTSSegmentTiming``
- ``TTSChunk``
- ``TTSBoundary``
- ``TTSChunkContext``
- ``TTSAudioEncoding``
- ``TTSManifestEntry``
- ``TTSConcatenationResult``
- ``TTSStitchPolicy``
- ``TTSLoudnessMatch``
- ``TTSLoudnessMeasurement``
- ``TTSLoudnessSummary``
- ``TTSOptions``
- ``HTTPDataRetry``
