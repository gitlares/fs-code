import AgentConnectionCore
import AppKit

@MainActor
final class SystemPromptEditorView: NSView, NSTextViewDelegate {
  private let picker = NSPopUpButton()
  private let revisionLabel = NSTextField(labelWithString: "")
  private let editor = NSTextView(usingTextLayoutManager: true)
  private let scrollView = NSScrollView()
  private let saveButton = NSButton(title: "Save", target: nil, action: nil)
  private let resetButton = NSButton(title: "Reset Section", target: nil, action: nil)
  private var store: AgentPromptStore?
  private var persisted = AgentPromptStore.defaults
  private var selectedSection = 0
  private var isDirty = false
  var canSave: Bool { isDirty && store != nil }
  func saveCurrent() { saveChanges() }

  override init(frame: NSRect) {
    super.init(frame: frame)
    picker.addItems(withTitles: ["Shared", "Build", "Plan", "Ask"])
    picker.target = self
    picker.action = #selector(sectionChanged)
    editor.delegate = self
    editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    editor.isRichText = false
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    editor.textContainer?.widthTracksTextView = true
    editor.textContainerInset = NSSize(width: 10, height: 10)
    editor.setAccessibilityLabel("System prompt")
    scrollView.documentView = editor
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.borderType = .bezelBorder
    saveButton.target = self
    saveButton.action = #selector(saveChanges)
    resetButton.target = self
    resetButton.action = #selector(resetSection)
    let header = NSStackView(views: [picker, revisionLabel, NSView(), saveButton, resetButton])
    header.orientation = .horizontal
    header.spacing = 8
    let stack = NSStackView(views: [header, scrollView])
    stack.orientation = .vertical
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
    ])
    updateDisplay()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  func configure(projectURL: URL) {
    do {
      store = try AgentPromptStore(projectURL: projectURL)
      persisted = try store!.load()
      isDirty = false
      selectedSection = 0
      picker.selectItem(at: 0)
      updateDisplay()
    } catch { revisionLabel.stringValue = error.localizedDescription }
  }
  func prepareToLeave() async -> Bool {
    guard isDirty else { return true }
    guard let window else { return false }
    return await withCheckedContinuation { continuation in
      let alert = NSAlert()
      alert.messageText = "Save changes to system prompts?"
      alert.informativeText = "Your changes will be lost if you don’t save them."
      alert.addButton(withTitle: "Save")
      alert.addButton(withTitle: "Don’t Save")
      alert.addButton(withTitle: "Cancel")
      alert.beginSheetModal(for: window) { response in
        if response == .alertFirstButtonReturn {
          self.saveChanges()
          continuation.resume(returning: !self.isDirty)
        } else if response == .alertSecondButtonReturn {
          self.isDirty = false
          self.updateDisplay()
          continuation.resume(returning: true)
        } else {
          continuation.resume(returning: false)
        }
      }
    }
  }
  func textDidChange(_ notification: Notification) {
    isDirty = true
    revisionLabel.stringValue = "Unsaved changes"
    saveButton.isEnabled = true
  }
  @objc private func sectionChanged() {
    let next = picker.indexOfSelectedItem
    guard next != selectedSection else { return }
    picker.selectItem(at: selectedSection)
    Task { [weak self] in
      guard let self, await self.prepareToLeave() else { return }
      self.selectedSection = next
      self.picker.selectItem(at: next)
      self.updateDisplay()
    }
  }
  @objc private func saveChanges() {
    guard let store else {
      revisionLabel.stringValue = "System prompt storage is unavailable."
      return
    }
    var updated = persisted
    replace(editor.string, in: &updated)
    updated.revision += 1
    do {
      try store.save(updated)
      persisted = updated
      isDirty = false
      updateDisplay()
    } catch { revisionLabel.stringValue = error.localizedDescription }
  }
  @objc private func resetSection() {
    editor.string = defaultSection
    isDirty = true
    revisionLabel.stringValue = "Unsaved changes"
    saveButton.isEnabled = true
  }
  private var currentSection: String { value(in: persisted) }
  private var defaultSection: String { value(in: AgentPromptStore.defaults) }
  private func value(in config: AgentPromptConfiguration) -> String {
    [config.shared, config.build, config.plan, config.ask][selectedSection]
  }
  private func replace(_ value: String, in config: inout AgentPromptConfiguration) {
    switch selectedSection {
    case 0: config.shared = value
    case 1: config.build = value
    case 2: config.plan = value
    default: config.ask = value
    }
  }
  private func updateDisplay() {
    editor.string = currentSection
    revisionLabel.stringValue = "v\(persisted.version) · Revision \(persisted.revision)"
    saveButton.isEnabled = canSave
  }
}
