import Testing
@testable import FSCode

@MainActor
@Suite("Plan editor document formatting")
struct PlanEditorViewTests {
    @Test
    func savingCanonicalPlanUsesOnlyItsBody() {
        let markdown = """
        ---
        plan_id: release
        title: Release checklist
        format: full
        status: draft
        approved_via: none
        revision: 4
        created: 2026-09-24
        base_commit: abc123
        ---

        # Release checklist

        ## Steps
        - [ ] Verify the release
        """

        #expect(PlanEditorView.draftBody(from: markdown) == "## Steps\n- [ ] Verify the release")
    }

    @Test
    func savingNonCanonicalTextDoesNotDiscardIt() {
        let body = "Notes prepared outside the plan template."
        #expect(PlanEditorView.draftBody(from: body) == body)
    }

    @Test
    func previewHidesFrontmatterAndKeepsTheDocumentTitle() {
        let markdown = """
        ---
        plan_id: release
        title: Release checklist
        format: full
        ---

        # Release checklist

        Prepare the release.
        """

        #expect(PlanEditorView.previewMarkdown(from: markdown) == "# Release checklist\n\nPrepare the release.")
    }
}
