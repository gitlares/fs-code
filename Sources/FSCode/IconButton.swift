import AppKit

/// Configures `button` as an icon-only control: SF Symbol image, accessible label,
/// tooltip, and target/action. Shared by the terminal header, the editor's inline
/// agent-change controls, and the chat composer's icon buttons.
@MainActor
func configureIconButton(
    _ button: NSButton,
    symbol: String,
    label: String,
    target: AnyObject?,
    action: Selector,
    bezelStyle: NSButton.BezelStyle = .inline,
    controlSize: NSControl.ControlSize = .regular,
    pointSize: CGFloat? = nil,
    isBordered: Bool? = nil
) {
    button.title = ""
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.imagePosition = .imageOnly
    button.bezelStyle = bezelStyle
    button.controlSize = controlSize
    if let pointSize { button.symbolConfiguration = .init(pointSize: pointSize, weight: .medium) }
    if let isBordered { button.isBordered = isBordered }
    button.target = target
    button.action = action
    button.toolTip = label
    button.setAccessibilityLabel(label)
}
