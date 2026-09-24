import Foundation

public enum ContextOrigin: String, Codable, Sendable {
    case fsCode
    case external
}

public enum ContextProvider: String, Codable, Sendable, CaseIterable {
    case fsCode
    case codex
    case claude
    case cursor
    case copilot
    case generic

    var stableOrder: Int {
        switch self {
        case .fsCode: 0
        case .codex: 1
        case .claude: 2
        case .cursor: 3
        case .copilot: 4
        case .generic: 5
        }
    }
}

public enum ContextScope: String, Codable, Sendable {
    case global
    case project
    case folder
    case glob
    case file
    case external
}

public enum ContextState: String, Codable, Sendable {
    case active
    case replaced
    case ignored
    case conflict
    case inactive
    case manual
    case unknown
    case unsupported
}

/// Describes whether a provider can deterministically apply a discovered source.
/// User activation is represented separately by `ContextRule.enabled`.
public enum ContextApplicability: String, Codable, Sendable {
    case automatic
    case manual
    case unknown
    case unsupported
    case replaced
}

public enum ContextDiagnosticKind: String, Codable, Sendable {
    case duplicate
    case conflict
    case stale
    case missing
    case invalidManifest
    case invalidMetadata
    case unsupportedPattern
    case unsupportedSyntax
    case pathEscape
    case oversize
    case incompleteScan
}

public struct ContextDiagnostic: Codable, Hashable, Sendable {
    public let kind: ContextDiagnosticKind
    public let message: String

    public init(_ kind: ContextDiagnosticKind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct ContextRule: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var url: URL?
    public var origin: ContextOrigin
    public var provider: ContextProvider
    public var scope: ContextScope
    /// A project-relative folder, file, or glob depending on `scope`.
    public var target: String?
    /// External formats may attach one source to several globs. Owned FS Code
    /// rules use the singular `target`.
    public var matchPatterns: [String]
    /// For owned rules this is the user's enabled switch. For external rules it is
    /// explicit consent persisted by relative source path.
    public var enabled: Bool
    public var priority: Int
    public var content: String
    public var hash: String
    public var diagnostics: [ContextDiagnostic]
    public var applicability: ContextApplicability
    public var applicabilityReason: String?

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL? = nil,
        origin: ContextOrigin,
        provider: ContextProvider? = nil,
        scope: ContextScope,
        target: String? = nil,
        matchPatterns: [String] = [],
        enabled: Bool = true,
        priority: Int = 0,
        content: String,
        hash: String,
        diagnostics: [ContextDiagnostic] = [],
        applicability: ContextApplicability = .automatic,
        applicabilityReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.origin = origin
        self.provider = provider ?? (origin == .fsCode ? .fsCode : .generic)
        self.scope = scope
        self.target = target
        self.matchPatterns = matchPatterns
        self.enabled = enabled
        self.priority = priority
        self.content = content
        self.hash = hash
        self.diagnostics = diagnostics
        self.applicability = applicability
        self.applicabilityReason = applicabilityReason
    }
}

public struct ContextCatalogSnapshot: Sendable {
    public let rules: [ContextRule]
    public let diagnostics: [ContextDiagnostic]

    public init(rules: [ContextRule], diagnostics: [ContextDiagnostic] = []) {
        self.rules = rules
        self.diagnostics = diagnostics
    }
}

public struct ContextResolutionEntry: Sendable, Identifiable {
    public let rule: ContextRule
    public let state: ContextState
    public let reason: String
    public let order: Int?
    /// Stable project-relative paths from the request for which this rule matched.
    public let matchedPaths: [String]
    public var id: UUID { rule.id }

    public init(rule: ContextRule, state: ContextState, reason: String, order: Int?, matchedPaths: [String]) {
        self.rule = rule
        self.state = state
        self.reason = reason
        self.order = order
        self.matchedPaths = matchedPaths
    }
}

public struct ContextResolution: Sendable {
    public let entries: [ContextResolutionEntry]
    public let consolidatedText: String
    public let utf8ByteCount: Int
    public let approximateTokenCount: Int
    public let diagnostics: [ContextDiagnostic]
    public let canSend: Bool

    public init(
        entries: [ContextResolutionEntry],
        consolidatedText: String,
        utf8ByteCount: Int,
        approximateTokenCount: Int,
        diagnostics: [ContextDiagnostic],
        canSend: Bool
    ) {
        self.entries = entries
        self.consolidatedText = consolidatedText
        self.utf8ByteCount = utf8ByteCount
        self.approximateTokenCount = approximateTokenCount
        self.diagnostics = diagnostics
        self.canSend = canSend
    }
}
