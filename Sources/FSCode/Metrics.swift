import CoreGraphics

/// Shared corner-radius scale for the small number of chrome surfaces that get a
/// discreet rounding (composer, message bubbles, small boxes). Outer panels stay
/// rectangular per docs/MACOS_GUI.md and must not use this.
enum Radius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
}

/// Shared spacing scale for new or touched layout code. Existing untouched files
/// keep their own literals until they're revisited.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}
