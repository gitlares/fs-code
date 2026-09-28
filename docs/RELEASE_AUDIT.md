# 0.1 Alpha release audit

Reviewed 2026-09-24 from `Package.swift`, `Package.resolved`, vendored source, bundled notices, and the connection/update code. This is a source audit, not a legal opinion or a notarization review.

## License inventory

The application license is MIT (`LICENSE.txt`). Its direct dependencies are compatible with an MIT distribution when their required notices remain distributed:

| Component | Pin/source | License | Notice status |
| --- | --- | --- | --- |
| SwiftTerm | 1.20.0, `5d144068…` | MIT | Present, including its copied-code notices. |
| Sparkle | 2.10.0, `eef1a539…` | MIT plus bundled third-party notices | Present in `Resources/ThirdPartyNotices.txt`. |
| AgentRunKit | vendored 6.0.0, `c5bce5d…` | MIT | Present in `Vendor/AgentRunKit/LICENSE` and bundled notices. Local patch is documented in `UPSTREAM.md`. |
| Dracula/Alucard palettes | bundled assets | MIT | Present. |

`swift-argument-parser` 1.8.2 (Apache-2.0) appears in `Package.resolved`, but it is transitive build tooling of the dependency graph rather than a declared FS Code runtime product. Confirm the final app bundle does not include it; if it does, include its full Apache-2.0 notice. Re-check copied notices whenever Sparkle or SwiftTerm is updated.

## Network and data handling

FS Code is not an offline-only application. It makes network requests only for configured features:

- Model sign-in and model/chat requests use OpenAI authentication and provider endpoints. AgentRunKit also contains optional provider clients (OpenAI, Anthropic, Gemini, Vertex, OpenRouter and local Ollama); the configured connection selects the endpoint.
- `Check for Updates…` can contact a configured Sparkle feed. The shipped `Info.plist` has automatic checks disabled and contains no `SUFeedURL`, so update checks are unavailable until a signed feed configuration is shipped.
- Browser OAuth starts a localhost callback listener during sign-in.

The source audit found no product analytics, crash-reporting SDK, or outbound telemetry collector. “Telemetry” in the conversation code is bounded local activity history stored with the project conversation record; it is not evidence of a separate analytics upload. This does not make model-provider traffic private: prompts, selected project context, and tool results sent to a configured provider leave the device under that provider/account's terms.

Credentials are handled through Keychain-backed connection storage; this audit did not inspect credential values.

## Alpha readiness and blockers

The package targets macOS 15+ and currently builds through SwiftPM's native backend; the README documents that the normal Metal build path may require the SwiftTerm toolchain. The distributed app is ad-hoc signed and is not notarized. Before a public GitHub 0.1 alpha, publish the exact source revision, retain the license/notices files in the app bundle, and make the release notes state that model access requires a locally configured account and can transmit chat/project data.

The README describes implemented and deferred features, but should be revised by the release owner to reflect Build/Plan/Ask and binary-preview behavior once their acceptance tests pass. Do not claim automatic updates, offline AI, notarization, or comprehensive privacy guarantees for this alpha.
