import Foundation

struct SchemaUnkeyedContainer: UnkeyedDecodingContainer {
    let decoder: SchemaDecoderImpl
    var codingPath: [any CodingKey]
    var count: Int? = 1
    var isAtEnd: Bool {
        currentIndex >= 1
    }

    var currentIndex: Int = 0

    mutating func decodeNil() -> Bool {
        decoder.pendingNullable = true
        return false
    }

    mutating func decode(_: Bool.Type) -> Bool {
        let schema: JSONSchema = decoder.pendingNullable ? .boolean().optional() : .boolean()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return false
    }

    mutating func decode(_: String.Type) -> String {
        let schema: JSONSchema = decoder.pendingNullable ? .string().optional() : .string()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return ""
    }

    mutating func decode(_: Double.Type) -> Double {
        let schema: JSONSchema = decoder.pendingNullable ? .number().optional() : .number()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return 0
    }

    mutating func decode(_: Float.Type) -> Float {
        let schema: JSONSchema = decoder.pendingNullable ? .number().optional() : .number()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return 0
    }

    mutating func decode(_: Int.Type) -> Int {
        let schema: JSONSchema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return 0
    }

    mutating func decode(_: Int8.Type) -> Int8 {
        let schema: JSONSchema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return 0
    }

    mutating func decode(_: Int16.Type) -> Int16 {
        let schema: JSONSchema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return 0
    }

    mutating func decode(_: Int32.Type) -> Int32 {
        let schema: JSONSchema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return 0
    }

    mutating func decode(_: Int64.Type) -> Int64 {
        let schema: JSONSchema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return 0
    }

    mutating func decode(_: UInt.Type) -> UInt {
        let schema: JSONSchema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return 0
    }

    mutating func decode(_: UInt8.Type) -> UInt8 {
        let schema: JSONSchema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return 0
    }

    mutating func decode(_: UInt16.Type) -> UInt16 {
        let schema: JSONSchema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return 0
    }

    mutating func decode(_: UInt32.Type) -> UInt32 {
        let schema: JSONSchema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return 0
    }

    mutating func decode(_: UInt64.Type) -> UInt64 {
        let schema: JSONSchema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        decoder.schema = .array(items: schema)
        currentIndex += 1
        return 0
    }

    mutating func decode<T: Decodable>(_: T.Type) throws -> T {
        let nestedDecoder = SchemaDecoderImpl()
        nestedDecoder.codingPath = codingPath
        nestedDecoder.pendingNullable = decoder.pendingNullable
        decoder.pendingNullable = false
        let value = try T(from: nestedDecoder)
        if let nestedSchema = nestedDecoder.schema {
            decoder.schema = .array(items: nestedSchema)
        }
        currentIndex += 1
        return value
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type
    ) -> KeyedDecodingContainer<NestedKey> {
        let container = SchemaKeyedContainer<NestedKey>(decoder: decoder, codingPath: codingPath)
        return KeyedDecodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedDecodingContainer {
        SchemaUnkeyedContainer(decoder: decoder, codingPath: codingPath)
    }

    mutating func superDecoder() -> any Decoder {
        decoder
    }
}

struct SchemaSingleValueContainer: SingleValueDecodingContainer {
    let decoder: SchemaDecoderImpl
    var codingPath: [any CodingKey]

    func decodeNil() -> Bool {
        decoder.pendingNullable = true
        return false
    }

    func decode(_: Bool.Type) -> Bool {
        decoder.schema = decoder.pendingNullable ? .boolean().optional() : .boolean()
        decoder.pendingNullable = false
        return false
    }

    func decode(_: String.Type) -> String {
        decoder.schema = decoder.pendingNullable ? .string().optional() : .string()
        decoder.pendingNullable = false
        return ""
    }

    func decode(_: Double.Type) -> Double {
        decoder.schema = decoder.pendingNullable ? .number().optional() : .number()
        decoder.pendingNullable = false
        return 0
    }

    func decode(_: Float.Type) -> Float {
        decoder.schema = decoder.pendingNullable ? .number().optional() : .number()
        decoder.pendingNullable = false
        return 0
    }

    func decode(_: Int.Type) -> Int {
        decoder.schema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        return 0
    }

    func decode(_: Int8.Type) -> Int8 {
        decoder.schema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        return 0
    }

    func decode(_: Int16.Type) -> Int16 {
        decoder.schema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        return 0
    }

    func decode(_: Int32.Type) -> Int32 {
        decoder.schema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        return 0
    }

    func decode(_: Int64.Type) -> Int64 {
        decoder.schema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        return 0
    }

    func decode(_: UInt.Type) -> UInt {
        decoder.schema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        return 0
    }

    func decode(_: UInt8.Type) -> UInt8 {
        decoder.schema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        return 0
    }

    func decode(_: UInt16.Type) -> UInt16 {
        decoder.schema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        return 0
    }

    func decode(_: UInt32.Type) -> UInt32 {
        decoder.schema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        return 0
    }

    func decode(_: UInt64.Type) -> UInt64 {
        decoder.schema = decoder.pendingNullable ? .integer().optional() : .integer()
        decoder.pendingNullable = false
        return 0
    }

    func decode<T: Decodable>(_: T.Type) throws -> T {
        let nestedDecoder = SchemaDecoderImpl()
        nestedDecoder.codingPath = codingPath
        nestedDecoder.pendingNullable = decoder.pendingNullable
        decoder.pendingNullable = false
        let value = try T(from: nestedDecoder)
        if let nestedSchema = nestedDecoder.schema {
            decoder.schema = nestedSchema
        }
        return value
    }
}
