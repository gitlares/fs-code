import AppKit

/// UI text sizing that can grow with the user's preferred content size, unlike a
/// raw `NSFont.systemFont(ofSize:)`. Editor, gutter, and code-preview fonts stay
/// on fixed monospaced sizes and must not use this helper.
enum UIFont {
    static func text(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}
