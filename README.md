# FS Code

**A native macOS code editor for working with AI, without losing sight of your code.**

FS Code is an early, MIT-licensed editor built with Swift and AppKit. No Electron, no Monaco, and no VS Code dependency. Created by Daniel Lares with Codex.

**0.1.2 Alpha** · macOS 15+ · English interface

This is a working prototype, not a finished IDE. Expect rough edges and keep your projects backed up. Performance is a design priority; we do not yet claim benchmark superiority over other editors.

## Why this exists

I like VS Code, Cursor, and Zed. FS Code starts from what I want to do differently in my own daily work:

1. **Stay native and lightweight.** Opening several projects should not require several heavyweight application runtimes. I prefer native macOS components wherever they fit.
2. **Keep a real editor beside the agent.** AI-assisted development still involves reading code, checking decisions, and making manual edits. I want a focused editor, not an entire IDE that gets in the way.
3. **Make instructions visible.** System prompts and project guardrails should be inspectable and editable. I want to understand which rules apply to a file and what context a request receives.
4. **Make efficient tools part of the workflow.** RTK (Rust Token Killer) belongs in the workflow I want to build. Compatible agent commands now use RTK when it is available locally.
5. **Show what the agent changed.** File and block changes should be visible in the editor and associated with the conversation, without requiring a trip through Git just to discover them.
6. **Make undoing AI changes straightforward.** Review the previous content and restore changes, with safeguards for subsequent edits.
7. **Keep AI accounts scoped to projects.** Different projects can use different accounts from the same service.
8. **No product telemetry.** I do not want an editor that collects analytics about how I work.

## In this alpha

- Project library: choose a folder, give it a name, search and reopen it.
- Independent project windows: **File → New Window** (`⌘⇧N`), with a native **Window** menu.
- File tree including hidden files; tabs, unsaved indicators, line numbers, current-line highlighting, and native Find/Undo.
- Language detection and lexical syntax highlighting with Dracula/Alucard colors. This is not semantic highlighting or an LSP implementation.
- Integrated local terminal powered by SwiftTerm.
- Image previews; SVG and Markdown Preview/Code views; native Quick Look for supported documents and media. Unsupported binaries show an inline read-only state.
- Project TODOs and a local, deterministic instruction/context inspector.
- Editable Shared / Build / Plan / Ask system prompts. Plans open in preview and can be edited, approved, and executed.
- Agent conversations with model/reasoning selection, queued messages, steering, file references, and activity display.
- A native Swift agent runtime using AgentRunKit. ChatGPT browser sign-in and OpenAI API-key connections are available; API-key access has not yet received the same live-account validation as ChatGPT.
- Audited AI file edits, modified-file indicators, block review/revert, and restore points with conflict checks.

The native agent currently exposes bounded project tools. It is not a full autonomous shell/subagent environment. The integrated terminal remains available for manual commands.

## Download and run

Download [FS Code 0.1.2 Alpha for Apple Silicon](https://github.com/gitlares/fs-code/releases/download/v0.1.2-alpha.1/FS-Code-0.1.2-arm64.zip), extract **FS Code.app**, and move it to Applications. This macOS 15+ build is Developer ID signed and notarized by Apple. See the [release notes and checksum](https://github.com/gitlares/fs-code/releases/tag/v0.1.2-alpha.1).

AI features require your own supported account or API key. Opening a project and using the editor do not require an FS Code account.

## Build from source

Requirements: macOS 15+, Xcode/Command Line Tools with Swift 6.1 or later, and network access to fetch pinned Swift packages. RTK is not required to build the application.

```sh
bash scripts/build-app.sh
open "dist/FS Code.app"
```

The default local build is ad-hoc signed. Developer ID distribution is documented in [Releasing](docs/RELEASING.md).

```sh
swift test --build-system native
```

The native SwiftPM backend avoids requiring the Metal shader compiler for SwiftTerm's unused Metal path; the terminal uses Core Graphics. This backend is deprecated in newer toolchains. Building through Xcode's normal path may require the Metal Toolchain component.

## Privacy and local data

FS Code contains no product analytics or crash-reporting service. Activity records are local conversation history, not analytics uploads.

**AI requests are not offline:** prompts, selected project context, and tool results are sent to the provider you connect. That provider's data policies apply. Terminal commands and external tools can also access the network.

- The project library lives under `~/Library/Application Support/FS Code/`.
- Project instructions and plans use `.fs/`; conversation and other local project state may use `.fscode/`.
- Connection credentials are stored through macOS Keychain. Do not commit local project state or credential exports to a public repository.
- Sparkle uses a public signed-update feed. Use **FS Code → Check for Updates…**; automatic checks and installation remain disabled by default. Version 0.1.0 requires one manual upgrade because it shipped without a feed.

See [Privacy](docs/PRIVACY.md) for the scope of these statements.

## What is next

- Broader RTK command coverage and measured token savings.
- Project-scoped MCP connections.
- Additional model providers, with supported authentication paths.
- Native Git status, history, and graph.
- Broader agent tool coverage and subagents with explicit controls.
- A lightweight extension model, language services, and larger-file performance work.
- End-to-end upgrade validation across published versions.

These are planned capabilities, not features promised by this release.

## Architecture

AppKit UI → editor/project/context services → `AgentEngine` boundary → native AgentRunKit runtime.

`EditorCore`, `ProjectLibrary`, `AgentContextCore`, and `AgentConnectionCore` separate persistence and domain behavior from the application UI. We reuse dependencies where they support the product rather than minimizing lines of code at the expense of maintainability.

## Contributing

Small, focused contributions are welcome. See [Contributing](CONTRIBUTING.md). Please open an issue before proposing a large dependency or a change to the native macOS direction.

## License and acknowledgments

FS Code's original code is licensed under [MIT](LICENSE.txt). Third-party components keep their own licenses and attribution requirements; MIT is not a replacement for those licenses.

FS Code builds on the work of these open-source projects:

| Project | Contribution to FS Code |
| --- | --- |
| [AgentRunKit](https://github.com/Tom-Ryder/AgentRunKit) | Native Swift agent runtime behind our `AgentEngine` interface. |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Terminal emulation for the integrated local terminal. |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | macOS update framework with a public signed-update feed. |
| [Dracula / Alucard](https://github.com/dracula/dracula-theme) | Dark and light color palettes. |

We appreciate their maintainers and contributors. As the editor matures, we hope to contribute generally useful fixes and improvements upstream while keeping FS Code-specific behavior in the editor.

Full notices ship in [ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt). Our vendored AgentRunKit version and local changes are documented in [UPSTREAM.md](Vendor/AgentRunKit/UPSTREAM.md).

[RTK — Rust Token Killer](https://github.com/rtk-ai/rtk) is used for compatible agent commands when installed locally.
