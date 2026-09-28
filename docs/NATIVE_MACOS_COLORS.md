FS Code — Native macOS UI colors spec
Goal

Make the application chrome look and behave like a first-party macOS app in light and dark mode. The editor text area keeps its syntax theme (Dracula for dark, Alucard for light). Everything else uses system semantic colors and materials.

Core rules
No hardcoded colors in chrome. No hex values, NSColor(red:green:blue:), or custom color assets anywhere outside the syntax theme and terminal palette. Use AppKit semantic colors and NSVisualEffectView materials only.
Follow the system by default. Appearance follows System Settings. Offer a setting with System / Light / Dark that sets NSApp.appearance (nil for System).
Follow the user's accent and highlight colors. Use controlAccentColor and selection colors; never a fixed brand color for selection, focus, or primary actions.
Re-resolve colors on appearance change. NSColor.cgColor is resolved once. Any layer-backed view that sets layer.backgroundColor or layer.borderColor must re-apply it in viewDidChangeEffectiveAppearance() or updateLayer() (with wantsUpdateLayer = true), inside effectiveAppearance.performAsCurrentDrawingAppearance { }.
Prefer standard components over custom drawing. Standard components get correct colors, contrast, and accessibility automatically.
Window structure
Element	Implementation
Window	Standard NSWindow, toolbarStyle = .unified, .fullSizeContentView so the sidebar extends under the titlebar. Standard traffic-light buttons, never custom.
Layout	NSSplitViewController. File tree as NSSplitViewItem(sidebarWithViewController:). Agent panel as NSSplitViewItem(inspectorWithViewController:).
Toolbar	NSToolbar with standard items and SF Symbols. No custom background.
Element → color mapping
Sidebar (file tree, project library)
Part	Color / material
Background	Provided by the sidebar split item (.sidebar material). Do not set a background.
Outline view	NSOutlineView with style = .sourceList, backgroundColor = .clear.
File name	labelColor
Hidden files, ignored files	secondaryLabelColor
File icons	NSWorkspace.shared.icon(for: UTType) or SF Symbols tinted secondaryLabelColor
Selected row	System default (accent-based, unemphasized when the window is not key). Do not override.
Modified-file indicator	controlAccentColor dot, or secondaryLabelColor text badge
Editor tab bar
Part	Color / material
Bar background	NSVisualEffectView with .headerView material
Inactive tab text	secondaryLabelColor
Active tab text	labelColor
Active tab background	Same as the editor background, so the active tab connects visually to the text area
Tab separators, bottom border	separatorColor
Unsaved indicator	secondaryLabelColor filled dot; close button replaces it on hover
Editor text area (theme-owned)
Part	Source
Background, text, syntax, current line, gutter, line numbers	Syntax theme: Dracula when effective appearance is dark, Alucard when light
Text selection	selectedTextBackgroundColor when focused, unemphasizedSelectedTextBackgroundColor when not
Find matches	findHighlightColor
Font	NSFont.monospacedSystemFont(ofSize:weight:) (SF Mono) by default, user-configurable

Switch the syntax theme in viewDidChangeEffectiveAppearance() and re-highlight only the visible range first.

Change and review markers (gutter)
Marker	Color
Added lines	systemGreen
Modified lines	systemBlue
Deleted lines marker	systemRed
Unreviewed agent change	controlAccentColor
Conflict on restore	systemOrange

System colors adapt to appearance and Increase Contrast automatically. Verify they remain legible on both Dracula and Alucard backgrounds.

Agent panel (inspector)
Part	Color / material
Background	windowBackgroundColor (or the inspector item's default)
Agent message text	labelColor
User message container	quaternarySystemFill background, no colored bubble
Metadata (model, tokens, timestamps)	secondaryLabelColor, tertiaryLabelColor for least important
Tool call rows	secondaryLabelColor text, SF Symbol per tool type
Code blocks	textBackgroundColor background, separatorColor border, SF Mono
Links, file references	linkColor
Input field	Standard NSTextView in an NSScrollView with system focus ring; placeholder placeholderTextColor
Errors	systemRed icon + labelColor text (do not color whole paragraphs red)
Warnings	systemOrange icon
Streaming indicator	NSProgressIndicator, spinning style
Plan preview
Part	Color
Document background	textBackgroundColor
Step status done	systemGreen SF Symbol checkmark.circle.fill
Step status in_progress	controlAccentColor circle.dotted or progress indicator
Step status blocked	systemOrange exclamationmark.triangle.fill
Step status pending	tertiaryLabelColor circle
Build note: lines	secondaryLabelColor
Status bar (bottom)
Part	Color / material
Background	windowBackgroundColor
Top border	separatorColor
Text	secondaryLabelColor
Active account / workspace	labelColor; if no account assigned, systemOrange icon with text "No account"
Terminal (SwiftTerm)
Part	Source
Background, foreground, ANSI palette	Same syntax theme as the editor (Dracula / Alucard terminal palettes), switched with appearance
Selection	selectedTextBackgroundColor
Buttons, dialogs, popovers
Part	Implementation
Buttons	Standard NSButton bezel styles. Primary action uses keyEquivalent = "\r" so it gets the accent color automatically.
Destructive actions (revert, discard)	hasDestructiveAction = true; confirmation via NSAlert with .critical style when irreversible
Popovers, menus	NSPopover, NSMenu defaults. No custom backgrounds.
Focus rings	System default. Never disable.
Scroll bars	System overlay scrollers. No custom scrollers.
Typography
UI text: system font (NSFont.systemFont(ofSize:), default 13 pt; NSFont.smallSystemFontSize for metadata).
Sidebar row size follows the user's sidebar icon size setting (use the source-list outline view defaults).
Monospaced text anywhere (editor, terminal, code blocks, paths): SF Mono via monospacedSystemFont.
Accessibility
Increase Contrast: semantic colors adapt automatically. Check that custom-drawn elements (gutter markers, tab bar) remain distinguishable; read NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast where drawing is custom.
Reduce Transparency: materials fall back automatically. Do not re-implement blur.
Never rely on color alone: every status also has an SF Symbol or text.
Out of scope
Syntax highlighting colors (Dracula / Alucard stay as they are).
New features, layout changes beyond what is listed, custom themes for chrome.
Acceptance criteria
 No hex color literals or RGB color initializers outside the syntax theme and terminal palette files (verify with a search of the sources).
 Switching System Settings between Light and Dark updates every UI element, including layer-backed views, without restarting the app.
 Changing the system accent color updates selection, focus rings, primary buttons, and unreviewed-change markers.
 With Increase Contrast on, all text and markers remain legible in both appearances.
 With Reduce Transparency on, sidebar and tab bar render as opaque without visual glitches.
 Sidebar selection turns gray (unemphasized) when the window is not key.
 Screenshots of the main window in light and dark mode, with a file open, the agent panel visible, and at least one agent change marked in the gutter.