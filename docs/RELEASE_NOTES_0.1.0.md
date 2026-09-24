# FS Code 0.1.0 Alpha

First public preview of a native macOS code editor built around visible, editable agent instructions and project-scoped AI connections.

## Download

- macOS 15 or later.
- Apple Silicon (arm64) build. Intel binaries are not included in this release.
- Extract the ZIP and move FS Code.app to Applications.
- Signing and notarization status is recorded on the GitHub release after verification.

## Included

Project library and multiple project windows; native text editing and lexical highlighting; integrated terminal; project TODOs; Markdown/SVG/image previews and Quick Look; deterministic Agent Context; Build/Plan/Ask with editable prompts and project plans; native AgentRunKit conversations; ChatGPT sign-in; audited AI edits, file links, and restore controls.

## Known limits

This is an alpha. Preserve backups and review agent changes. UTF-8 editing is limited to 5 MiB per file; agent edit tools have smaller limits. Highlighting is lexical. The provider API-key path has not yet been validated against a live paid API account. Claude OAuth, project MCP, Git graph, plugins, automatic RTK integration, agent shell execution, and subagents are not part of this release. The Sparkle update feed is not enabled.

There is no FS Code analytics collector. Connected AI requests send prompts, supplied context, and tool results to the selected provider. See the privacy documentation before working with confidential material.

## Validation

178 XCTest tests, with one skipped and zero failures, plus 33 Swift Testing tests passed for this release preparation. Native UI spot checks included project-window switching, binary/PDF previews, and plan Preview/Code switching. This is not a complete cross-version or accessibility certification.
