# AgentRunKit core snapshot

Source: https://github.com/Tom-Ryder/AgentRunKit
Version: 6.0.0, commit c5bce5d70d3b3b57415beee9f7f4522ab53e6d88.
License: MIT, preserved in LICENSE and application notices.

Only the existing AgentRunKit core target is included. Optional MLX, testing helpers, documentation plugins and FoundationModels targets are not dependencies of FS Editor. No additional runtime is introduced.

Local patch: Responses reasoning details are published from the terminal response, not provisional output_item.done objects, whose lifecycle metadata can differ. Text and tool reconciliation remain strict. Regression coverage is in FS Editor NativeAgentRuntimeTests. Replace this snapshot with an upstream release when the fix is available and tested.

Completed output items are retained by index to reconstruct an empty terminal output. Reconstruction uses only typed, completed, contiguous items, then the existing projection and semantic reconciliation. Incomplete responses remain failures; raw deltas alone never authorize tool execution. Field-only failure diagnostics contain no provider payload or credentials.
