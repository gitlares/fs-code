import Foundation

/// The semantic kind of tool call requested by the model.
public enum ToolCallKind: String, Sendable, Equatable, Codable {
    case function
    case custom
}

/// A tool call requested by the model during generation.
public struct ToolCall: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let arguments: String
    public let kind: ToolCallKind

    public init(id: String, name: String, arguments: String, kind: ToolCallKind = .function) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.kind = kind
    }

    public var argumentsData: Data {
        Data(arguments.utf8)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, arguments
        case kind = "type"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        arguments = try container.decode(String.self, forKey: .arguments)
        kind = try container.decodeIfPresent(ToolCallKind.self, forKey: .kind) ?? .function
    }
}
