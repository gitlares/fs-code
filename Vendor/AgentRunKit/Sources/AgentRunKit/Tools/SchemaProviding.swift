/// A type that can provide its own JSON Schema representation.
public protocol SchemaProviding: Sendable {
    static var jsonSchema: JSONSchema { get }
    static func validateSchema() throws(AgentError)
}

public extension SchemaProviding {
    static func validateSchema() throws(AgentError) {}
}

public extension SchemaProviding where Self: Decodable {
    static var jsonSchema: JSONSchema {
        do {
            return try SchemaDecoder.decode(Self.self)
        } catch {
            preconditionFailure(
                "Schema inference failed for \(Self.self): \(error). " +
                    "Implement jsonSchema manually, or call validateSchema() at construction to surface this earlier."
            )
        }
    }

    static func validateSchema() throws(AgentError) {
        do {
            _ = try SchemaDecoder.decode(Self.self)
        } catch {
            throw AgentError.schemaInferenceFailed(
                type: String(describing: Self.self), message: String(describing: error)
            )
        }
    }
}
