Task: Base16 color themes for the editor text area
Objective

Add support for Base16 color schemes to FS Code's editor text area and integrated terminal. A theme changes colors only. The application chrome (sidebar, tabs, panels, toolbar, status bar) is out of scope and keeps using macOS semantic colors as defined in FS-Code-Native-UI-Colors-Spec.md.

When done, the user can pick one theme for light appearance and one for dark appearance, import additional Base16 schemes from files, and see editor and terminal colors switch automatically with the system appearance.

Scope
An internal editor theme model and the mapping from Base16 to it.
The existing Dracula (dark) and Alucard (light) themes, migrated to the new model with their current colors preserved exactly.
A Base16 scheme importer (file-based, local only).
Theme selection settings: one slot for light appearance, one for dark.
Applying the active theme to the editor text area and to the SwiftTerm terminal palette.
Tests for parsing, validation, mapping, and appearance detection.
Out of scope
Any change to chrome colors, layout, or UI fonts.
Bundling third-party schemes (GitHub, Catppuccin, etc.). Only the importer is built now; bundled schemes are added later after license review.
Downloading schemes from the internet.
Semantic highlighting, LSP, or changes to the lexer's token categories.
Font styles (bold, italic) driven by themes.
Constraints
Colors only. A theme never changes font family, size, weight, style, line height, or spacing. The editor font remains a separate setting (default NSFont.monospacedSystemFont). UI text keeps the system font.
Chrome stays native. Text selection, find highlights, focus rings, and gutter change markers keep the system colors defined in the native UI spec, not theme colors.
No silent fallbacks. An invalid scheme file is rejected with a clear error naming the problem (missing key, invalid hex, unreadable file). Never load a partially valid scheme with defaults filled in.
No re-lexing on theme switch. Token categories do not change when the theme changes. Keep token → role results and re-color, starting with the visible range.
Dependencies. Parsing YAML needs a parser. If the project has none, add Yams through Swift Package Manager with a pinned version, add its license to Resources/ThirdPartyNotices.txt, and report it in the final response. Do not write a custom general-purpose YAML parser.
Inspect the existing highlighting, theme, and terminal code before editing. Reuse its structure. Do not refactor unrelated code.
Base16 format

Accept both formats in common use:

Current format

yaml
system: "base16"
name: "Scheme Name"
author: "Author Name"
variant: "dark"        # or "light"; optional
palette:
  base00: "#282a36"
  # ... through base0F

Legacy flat format

yaml
scheme: "Scheme Name"
author: "Author Name"
base00: "282a36"
# ... through base0F

Validation rules:

All 16 keys base00…base0F must be present (case-insensitive key match).
Each value is a 6-digit hex color, with or without a leading #.
name/scheme is required; author is optional but shown when present.
If variant is missing, classify the scheme as light or dark by the relative luminance of base00 (luminance > 0.5 → light).
Base24 files (with base10…base17) are accepted; use base12…base17 for the bright ANSI colors when present, otherwise ignore the extra keys.
Editor mapping

Follow the Base16 styling guidelines. First inspect the lexer's existing token categories, then map each one to the closest role below. List the final mapping in the final response.

Base16	Role in the editor
base00	Editor background, gutter background
base01	Current line highlight
base02	(Reserved; selection stays on system colors)
base03	Comments, line numbers, invisibles
base04	Current line number
base05	Default foreground, operators, punctuation
base06	(Unused unless a token category needs a light foreground)
base07	(Unused)
base08	Variables, tags, identifiers that the lexer marks as variables
base09	Numbers, booleans, constants
base0A	Types, classes, attributes
base0B	Strings
base0C	Escape sequences, regular expressions, support/built-ins
base0D	Functions, methods, headings (Markdown)
base0E	Keywords, storage modifiers
base0F	Deprecated items, embedded language delimiters
Terminal mapping
ANSI	Normal	Bright
Black	base00	base03
Red	base08	base12 if Base24, else base08
Green	base0B	base14 if Base24, else base0B
Yellow	base0A	base13 if Base24, else base0A
Blue	base0D	base16 if Base24, else base0D
Magenta	base0E	base17 if Base24, else base0E
Cyan	base0C	base15 if Base24, else base0C
White	base05	base07

Terminal background base00, foreground base05, cursor base05. Selection keeps the system selection color.

Built-in themes
Migrate Dracula and Alucard into the new theme model. Their rendered colors must not change: take a screenshot of the same file before and after migration in both appearances and compare.
Defaults: Dracula for dark appearance, Alucard for light.
Import and storage
Settings shows "Import Theme…" which opens NSOpenPanel filtered to .yaml and .yml.
A valid scheme is copied to ~/Library/Application Support/FS Code/Themes/ and appears in the theme lists.
A scheme with the same name as an existing one asks whether to replace it; never overwrite silently.
Show name, author, and variant in the theme list, plus a small preview (background with a few colored tokens).
Settings stores the selected light theme and dark theme by identifier. If a selected theme file is later missing, fall back to the built-in default for that appearance and show a one-time notice naming the missing theme.
If base05 on base00 has a contrast ratio below 4.5:1, show a warning in the theme list. Do not block selection.
Appearance switching
The active theme is the light slot when the editor's effective appearance is light and the dark slot when dark.
Switch in viewDidChangeEffectiveAppearance() for the editor and terminal views, without restarting the app. Re-color the visible range first, then the rest of the document off the main thread in batches.
Tests
Parse both formats, including keys with and without # and mixed-case keys.
Reject: missing key, invalid hex, empty file, non-YAML file. Each error message names the problem.
Light/dark classification with and without variant.
Base24 bright-color mapping, and fallback when Base24 keys are absent.
Token role → Base16 mapping for every lexer category.
Contrast ratio calculation for a known pair of colors.
Acceptance criteria
 Dracula and Alucard render identically before and after migration (screenshots in both appearances).
 Importing a valid Base16 file (current format) and a valid legacy file both succeed and appear in the lists.
 Importing a file with a missing key shows an error naming the missing key, and nothing is added.
 Switching System Settings between Light and Dark changes editor and terminal colors immediately.
 Changing the theme does not trigger re-lexing (verify via log, test, or profiler).
 Editor font family, size, and weight are unchanged after switching themes.
 Chrome colors are unchanged after switching themes.
 All tests above pass with swift test --build-system native.
Final response

Report files changed, the dependency added (if any), the final token → Base16 mapping, test results, and anything not verifie