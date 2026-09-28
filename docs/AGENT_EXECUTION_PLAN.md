# Agent execution capabilities

Status: implemented in the development working tree; automated validation passed. These tools are not available in the published 0.1.0-alpha.1 release.

## Goal

Develop, validate, commit, and publish FS Code from inside FS Code. Capabilities belong to the host harness, not to a particular model or a system-prompt instruction.

## Current boundary

The native runtime exposes project reading/search, audited file editing in Build, restricted plan tools, and project-authorized development commands and Accessibility actions. The integrated interactive terminal and agent command runner are separate.

## Execution service

The native process service accepts explicit executable/argument vectors and starts in the project directory. It drains combined stdout/stderr asynchronously, retains bounded output, and reports exit status, timeouts, cancellation, and turn-associated activity. Activity shows command start and completion; output is returned at completion, not streamed into the UI. A working directory is not a filesystem sandbox; do not claim otherwise.

The requested scope includes a general development command tool, not just fixed Git actions. Enable it through an explicit project capability. Commands run with the user account’s normal access, starting in the project directory; the capability is not a filesystem or network sandbox. Structured Git and release actions may build on this service later.

- Git: status, diff, log, explicit path staging, commit, push to a displayed remote and branch. No implicit force push or blanket staging of local state.
- Build/test: user-configured named tasks. Project configuration is untrusted until accepted; approval is bound to the task definition and must be invalidated if it changes.
- Signing: select a Developer ID identity and keychain; call codesign. Return status and certificate identity, never private-key material.
- Notarization: use an existing notarytool Keychain profile; return submission/status and staple the accepted ticket.
- Publication: use Git/gh credential providers; bind publication to the reviewed commit/tag and verified artifacts. Surface release target and visibility before an authorized operation.

Ask remains read-only. Plan must not gain shell writes indirectly. Build capabilities and grants are scoped to the project; switching models does not bypass that policy. Honor an explicit authorization already provided rather than asking again for every step.

## Credentials

Do not expose a general “read Keychain” tool. Git uses its credential helper or SSH agent, gh uses its credential store, and codesign/notarytool use macOS facilities. Any password prompt belongs to the OS/user interaction and must never be forwarded to the model. Project-specific model credentials and system Git/signing credentials are distinct; using the latter does not automatically isolate accounts per project.

## Preserve the editor's guarantees

Commands can modify tracked, untracked, and ignored files. Command-origin restore points and unsaved-buffer protection are not guaranteed by the command runner. Only fs_edit_file currently passes through the single audited write service. Do not claim per-block deterministic restore or attribution for arbitrary command writes until that behavior is implemented and tested. A filesystem watcher alone cannot distinguish concurrent user/external-agent changes.

When installed, RTK automatically handles recognized direct Git, ls, and rg commands at the host boundary. Check the actual command after any rewriting, retain the original exit status, and never run a command twice merely to obtain a different output representation.

## Acceptance

| Area | Required check |
| --- | --- |
| Project isolation | Enabling a capability in one project does not enable it in another. |
| Chat requests | A tool request cannot grant itself permission; denial remains denied. |
| Revocation | A subsequent dispatch reads the latest project grant. |
| Modes | Ask and Plan cannot run commands or desktop actions. |
| Commands | Output is bounded while drained; timeout and cancellation terminate the process group. |
| Git | Temporary repository pushes successfully to a temporary bare remote. |
| Computer Use | Missing OS permission, secure input, stale target IDs and changed app identity fail closed. |
| UI | Permissions stays readable at the sidebar minimum width in light and dark appearances. |


Use a temporary repository to verify status → edit → test → commit → push to a local bare remote. Test cancellation, output caps, process-tree termination, changed task definitions, denied operations, dirty editor buffers, and two project windows with distinct settings. Validate a signing/notarization/release dry run separately before enabling real publication. Built-in handlers must not retrieve credentials. A general command can print arbitrary user-accessible data, so do not claim that unrestricted shell output is automatically secret-free.

## User-controlled capabilities

A Permissions section in the left sidebar shows active and inactive project capabilities. Development Commands and Computer Use can be enabled or disabled independently. All connected models share the host policy. A model may request activation from the conversation, but only the host user interface can grant it; repository instructions and tool output cannot grant permissions. Revocation is checked at tool dispatch.

Computer Use begins with native macOS Accessibility inspection and actions. Project authorization controls which agent can use it, but desktop access is not restricted to project files. macOS permission remains separately required. Tool activity identifies the target application. Secure fields and system credential dialogs are excluded. A screenshot filename is not visual model input; do not advertise screenshot vision until the provider transports image content.

## RTK and usage visibility

RTK is optional at installation time and should be used automatically for recognized direct commands when available. Preserve argument boundaries, disclose the effective command, and never retry the original command after an RTK execution failure. Unsupported shell strings and custom executables remain unchanged. Global RTK statistics are not FS Code-specific savings.

Provider-advertised default and maximum windows are distinct from the published API model limit. Usage reports preserve missing cache fields as unavailable, not zero. Cache-read totals do not establish which individual instruction file was cached. The current Responses mapper merges all system messages, including changing host metadata, into instructions; further provider-specific prefix work is required before promising stable instruction caching.

## Conversation task details

Complete structured Checkpoint footers in final responses appear as a collapsed Task details disclosure. A meaningful next action remains visible. Original message text is preserved for history and copying. This model-authored continuity summary is separate from deterministic file restore points. Incomplete or unrecognized footers remain visible rather than silently losing information.

## Validation — 2026-09-24

The full native-build test run completed with 188 XCTest tests (one skipped) and 33 Swift Testing tests, with no failures. Checks include local bare-remote Git push, project-scoped grants, Ask/Plan command rejection, bounded output, timeout, cancellation with a background child and an unaffected parallel invocation, cache telemetry, and Checkpoint parsing. This does not constitute a live provider cache measurement, signing/publication validation, or an OS Accessibility permission grant.

The opt-in AppKit chat artifact test also passed (one test). Collapsed and expanded Task details were visually reviewed at narrow width in dark appearance, and expanded details in light appearance. The native Permissions sidebar was inspected in an isolated application instance without granting capabilities. OS Accessibility actions and live provider authentication were not exercised in that instance. The development app was packaged at `dist/FS Code.app` with an ad-hoc signature; the published notarized release was not replaced.
