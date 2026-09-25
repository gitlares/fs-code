import Foundation
import Yams

public struct ThemeRGB: Codable, Hashable, Sendable {
  public let red: UInt8
  public let green: UInt8
  public let blue: UInt8
  public let alpha: Double
  public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }
  public init(hex: String, alpha: Double = 1) throws {
    let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    guard value.count == 6, value.unicodeScalars.allSatisfy(hexadecimal.contains),
      let raw = Int(value, radix: 16)
    else { throw EditorThemeError.invalidHex(hex) }
    self.init(UInt8((raw >> 16) & 255), UInt8((raw >> 8) & 255), UInt8(raw & 255), alpha: alpha)
  }
  public var hex: String { String(format: "%02X%02X%02X", red, green, blue) }
  public var relativeLuminance: Double {
    func c(_ value: UInt8) -> Double {
      let x = Double(value) / 255
      return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * c(red) + 0.7152 * c(green) + 0.0722 * c(blue)
  }
}
public enum EditorThemeVariant: String, Codable, Sendable { case light, dark }
public enum EditorThemeError: LocalizedError, Sendable {
  case empty, unreadable
  case missingKey(String)
  case duplicateKey(String)
  case duplicateName(String)
  case builtinProtected(String)
  case invalidHex(String)
  case invalidVariant(String)
  case malformed
  public var errorDescription: String? {
    switch self {
    case .empty: "Theme file is empty."
    case .unreadable: "Theme file is unreadable."
    case .missingKey(let key): "Theme is missing \(key)."
    case .duplicateKey(let key): "Theme contains duplicate key \(key)."
    case .duplicateName(let name): "A theme named \(name) already exists."
    case .builtinProtected(let name): "The built-in theme \(name) cannot be replaced."
    case .invalidHex(let value): "Theme has invalid hex color \(value)."
    case .invalidVariant(let value): "Theme has invalid variant \(value)."
    case .malformed: "Theme YAML is malformed."
    }
  }
}
public struct EditorTheme: Hashable, Sendable {
  public let id, name: String
  public let author: String?
  public let variant: EditorThemeVariant
  public let background, foreground, currentLine, comment, currentLineNumber, cursor: ThemeRGB
  public let ansiColors: [ThemeRGB]
  private let tokenColors: [SyntaxTokenKind: ThemeRGB]
  public init(
    id: String, name: String, author: String? = nil, variant: EditorThemeVariant,
    background: ThemeRGB, foreground: ThemeRGB, currentLine: ThemeRGB, comment: ThemeRGB,
    currentLineNumber: ThemeRGB, cursor: ThemeRGB, ansiColors: [ThemeRGB],
    tokenColors: [SyntaxTokenKind: ThemeRGB]
  ) {
    self.id = id
    self.name = name
    self.author = author
    self.variant = variant
    self.background = background
    self.foreground = foreground
    self.currentLine = currentLine
    self.comment = comment
    self.currentLineNumber = currentLineNumber
    self.cursor = cursor
    self.ansiColors = ansiColors
    self.tokenColors = tokenColors
  }
  public func tokenColor(for kind: SyntaxTokenKind) -> ThemeRGB { tokenColors[kind] ?? foreground }
  public var contrastRatio: Double {
    (max(background.relativeLuminance, foreground.relativeLuminance) + 0.05)
      / (min(background.relativeLuminance, foreground.relativeLuminance) + 0.05)
  }
}
public enum Base16ThemeImporter {
  public static func parse(yaml: String, id: String = UUID().uuidString) throws -> EditorTheme {
    guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw EditorThemeError.empty
    }
    guard let node = try Yams.compose(yaml: yaml), let rootMapping = node.mapping else {
      throw EditorThemeError.malformed
    }
    func dictionary(_ mapping: Node.Mapping) throws -> [String: Node] {
      var result: [String: Node] = [:]
      for pair in mapping {
        guard let rawKey = pair.key.scalar?.string else { throw EditorThemeError.malformed }
        let key = rawKey.lowercased()
        guard result[key] == nil else { throw EditorThemeError.duplicateKey(rawKey) }
        result[key] = pair.value
      }
      return result
    }
    let root = try dictionary(rootMapping)
    let palette: [String: Node]
    if let paletteNode = root["palette"] {
      guard let mapping = paletteNode.mapping else { throw EditorThemeError.malformed }
      palette = try dictionary(mapping)
    } else {
      palette = root
    }
    if let systemNode = root["system"] {
      guard let system = systemNode.scalar?.string.lowercased(),
        system == "base16" || system == "base24"
      else { throw EditorThemeError.malformed }
    }
    func string(_ key: String, from values: [String: Node]) throws -> String {
      guard let node = values[key.lowercased()] else { throw EditorThemeError.missingKey(key) }
      guard let value = node.scalar?.string else { throw EditorThemeError.invalidHex(key) }
      return value
    }
    func value(_ key: String) throws -> ThemeRGB {
      let raw = try string(key, from: palette)
      do { return try ThemeRGB(hex: raw) } catch {
        throw EditorThemeError.invalidHex("\(key): \(raw)")
      }
    }
    let base = try (0...15).map { try value(String(format: "base%02X", $0)) }
    for extraIndex in 0x10...0x17 {
      let key = String(format: "base%02X", extraIndex)
      if palette[key.lowercased()] != nil { _ = try value(key) }
    }
    let name = (root["name"] ?? root["scheme"])?.scalar?.string.trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard let name, !name.isEmpty else { throw EditorThemeError.missingKey("name") }
    if root["variant"] != nil, root["variant"]?.scalar?.string == nil {
      throw EditorThemeError.invalidVariant("variant")
    }
    let rawVariant = root["variant"]?.scalar?.string
    let variant: EditorThemeVariant
    if let rawVariant {
      guard let parsed = EditorThemeVariant(rawValue: rawVariant.lowercased()) else {
        throw EditorThemeError.invalidVariant(rawVariant)
      }
      variant = parsed
    } else {
      variant = base[0].relativeLuminance > 0.5 ? .light : .dark
    }
    func extra(_ hex: Int, fallback: ThemeRGB) throws -> ThemeRGB {
      let key = String(format: "base%02X", hex)
      guard palette.first(where: { $0.key.lowercased() == key.lowercased() }) != nil else {
        return fallback
      }
      return try value(key)
    }
    let ansi = [
      base[0], base[8], base[11], base[10], base[13], base[14], base[12], base[5], base[3],
      try extra(0x12, fallback: base[8]), try extra(0x14, fallback: base[11]),
      try extra(0x13, fallback: base[10]), try extra(0x16, fallback: base[13]),
      try extra(0x17, fallback: base[14]), try extra(0x15, fallback: base[12]), base[7],
    ]
    let tokens: [SyntaxTokenKind: ThemeRGB] = [
      .keyword: base[14], .operator: base[5], .tag: base[8], .string: base[11], .comment: base[3],
      .number: base[9], .type: base[10], .function: base[13], .property: base[8],
      .attribute: base[10],
    ]
    return EditorTheme(
      id: id, name: name, author: root["author"]?.scalar?.string, variant: variant,
      background: base[0], foreground: base[5], currentLine: base[1], comment: base[3],
      currentLineNumber: base[4], cursor: base[5], ansiColors: ansi, tokenColors: tokens)
  }
}

extension EditorTheme {
  public static let dracula = builtin(
    id: "builtin.dracula", name: "Dracula", variant: .dark,
    values: [
      "282A36", "F8F8F2", "44475A", "6272A4", "8BE9FD", "50FA7B", "FFB86C", "FF79C6", "BD93F9",
      "F1FA8C",
    ],
    ansi: [
      "21222C", "FF5555", "50FA7B", "F1FA8C", "BD93F9", "FF79C6", "8BE9FD", "F8F8F2", "6272A4",
      "FF6E6E", "69FF94", "FFFFA5", "D6ACFF", "FF92DF", "A4FFFF", "FFFFFF",
    ])
  public static let alucard = builtin(
    id: "builtin.alucard", name: "Alucard", variant: .light,
    values: [
      "FFFBEB", "1F1F1F", "CFCFDE", "6C664B", "036A96", "14710A", "A34D14", "A3144D", "644AC9",
      "846E15",
    ],
    ansi: [
      "1F1F1F", "B3261E", "14710A", "846E15", "644AC9", "A3144D", "036A96", "FFFBEB", "6C664B",
      "D34038", "258C1B", "A88916", "7958DC", "C33A70", "087FAF", "FFFFFF",
    ])
  public static let builtins = [dracula, alucard]
  private static func builtin(
    id: String, name: String, variant: EditorThemeVariant, values: [String], ansi: [String]
  ) -> EditorTheme {
    let c = values.map { try! ThemeRGB(hex: $0) }
    let a = ansi.map { try! ThemeRGB(hex: $0) }
    return EditorTheme(
      id: id, name: name, variant: variant, background: c[0], foreground: c[1],
      currentLine: ThemeRGB(c[2].red, c[2].green, c[2].blue, alpha: 0.35), comment: c[3],
      currentLineNumber: c[3], cursor: c[8], ansiColors: a,
      tokenColors: [
        .keyword: c[7], .operator: c[7], .tag: c[7], .string: c[9], .comment: c[3], .number: c[8],
        .type: c[4], .function: c[5], .property: c[5], .attribute: c[5],
      ])
  }
}

extension Notification.Name {
  public static let editorThemeDidChange = Notification.Name("EditorThemeDidChange")
}

@MainActor public final class EditorThemeStore {
  public static let shared = EditorThemeStore()
  private let directory: URL
  private let defaults: UserDefaults
  private var pendingMissingNotices: [String] = []
  public private(set) var themes: [EditorTheme] = EditorTheme.builtins
  public init(applicationSupportURL: URL? = nil, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let base =
      applicationSupportURL
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    directory = base.appendingPathComponent("FS Code/Themes", isDirectory: true)
    reload()
  }
  public func selectedThemeID(for variant: EditorThemeVariant) -> String {
    defaults.string(forKey: "editorTheme.\(variant.rawValue)")
      ?? (variant == .dark ? EditorTheme.dracula.id : EditorTheme.alucard.id)
  }
  public func setSelectedThemeID(_ id: String, for variant: EditorThemeVariant) {
    defaults.set(id, forKey: "editorTheme.\(variant.rawValue)")
    defaults.set(
      themes.first(where: { $0.id == id })?.name, forKey: "editorTheme.\(variant.rawValue).name")
    NotificationCenter.default.post(name: .editorThemeDidChange, object: self)
  }
  public func activeTheme(forDarkAppearance dark: Bool) -> EditorTheme {
    let variant: EditorThemeVariant = dark ? .dark : .light
    let id = selectedThemeID(for: variant)
    return themes.first(where: { $0.id == id }) ?? (dark ? .dracula : .alucard)
  }
  public func consumeMissingSelectionNotice() -> String? {
    pendingMissingNotices.isEmpty ? nil : pendingMissingNotices.removeFirst()
  }
  public func importTheme(yaml: String, sourceName: String, replaceExisting: Bool = false) throws
    -> EditorTheme
  {
    var theme = try Base16ThemeImporter.parse(yaml: yaml)
    if let existing = themes.first(where: {
      $0.name.caseInsensitiveCompare(theme.name) == .orderedSame
    }) {
      guard replaceExisting else { throw EditorThemeError.duplicateName(theme.name) }
      guard !existing.id.hasPrefix("builtin.") else {
        throw EditorThemeError.builtinProtected(existing.name)
      }
      theme = try Base16ThemeImporter.parse(yaml: yaml, id: existing.id)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(theme.id).appendingPathExtension("yaml")
    try Data(yaml.utf8).write(to: destination, options: .atomic)
    reload()
    NotificationCenter.default.post(name: .editorThemeDidChange, object: self)
    return theme
  }
  public func removeImportedTheme(id: String) throws {
    guard let theme = themes.first(where: { $0.id == id }), !theme.id.hasPrefix("builtin.") else {
      return
    }
    let file = directory.appendingPathComponent(theme.id).appendingPathExtension("yaml")
    try FileManager.default.removeItem(at: file)
    reload()
    NotificationCenter.default.post(name: .editorThemeDidChange, object: self)
  }
  public func reload() {
    let previous = themes
    let previousActive = [
      activeTheme(forDarkAppearance: false).id, activeTheme(forDarkAppearance: true).id,
    ]
    themes = EditorTheme.builtins
    if let files = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
      where ["yaml", "yml"].contains(file.pathExtension.lowercased()) {
        if let yaml = try? String(contentsOf: file, encoding: .utf8),
          let theme = try? Base16ThemeImporter.parse(
            yaml: yaml, id: file.deletingPathExtension().lastPathComponent)
        {
          themes.append(theme)
        }
      }
    }
    for variant in [EditorThemeVariant.light, .dark] {
      let id = selectedThemeID(for: variant)
      if !themes.contains(where: { $0.id == id }), !pendingMissingNotices.contains(id) {
        let name = defaults.string(forKey: "editorTheme.\(variant.rawValue).name") ?? id
        pendingMissingNotices.append(
          "The selected \(variant.rawValue) theme \(name) is unavailable; the built-in theme is active."
        )
        defaults.set(
          variant == .dark ? EditorTheme.dracula.id : EditorTheme.alucard.id,
          forKey: "editorTheme.\(variant.rawValue)")
      }
    }
    if previous != themes
      || previousActive != [
        activeTheme(forDarkAppearance: false).id, activeTheme(forDarkAppearance: true).id,
      ]
    {
      NotificationCenter.default.post(name: .editorThemeDidChange, object: self)
    }
  }
}
