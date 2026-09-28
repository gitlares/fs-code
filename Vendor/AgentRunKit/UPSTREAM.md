# AgentRunKit core snapshot

Source: https://github.com/Tom-Ryder/AgentRunKit
Version: 6.1.0, commit a7ac823ca42d4ecff386a83c10a44a97bd391cdb.
License: MIT, preserved in LICENSE and application notices.

Only the existing AgentRunKit core target is included. Optional MLX, testing helpers, documentation plugins and FoundationModels targets are not dependencies of FS Editor. No additional runtime is introduced.

Local patch: Responses reasoning details are published from the terminal response, not provisional output_item.done objects, whose lifecycle metadata can differ. Text and tool reconciliation remain strict. Regression coverage is in FS Editor NativeAgentRuntimeTests. Replace this snapshot with an upstream release when the fix is available and tested.

Completed output items are retained by index to reconstruct an empty terminal output. Reconstruction uses only typed, completed, contiguous items, then the existing projection and semantic reconciliation. Incomplete responses remain failures; raw deltas alone never authorize tool execution. Field-only failure diagnostics contain no provider payload or credentials.

Local patch: `ContextCompactor` (Core/Context/ContextCompactor.swift) and its `Outcome`/`SummaryGenerator` types are exposed as `public`, and `ContextCompactor` conforms to `Sendable` (`SummaryGenerator` is now `@Sendable`) so it can be called from an `@MainActor`-isolated caller under Swift 6 strict concurrency. Upstream keeps this type internal because it expects consumers to go through `Agent`; FS Editor's native runtime (`NativeAgentRuntime`) deliberately implements its own agent loop directly over `LLMClient` and needs the compactor as a standalone component. No algorithm/logic was changed, only access modifiers and concurrency annotations. Regression coverage is in FS Editor `NativeAgentRuntimeTests`. Reconcile on the next upstream sync: if a future release exposes this publicly (and Sendable) on its own, drop this patch.
