import Foundation

public enum DexError: Error, LocalizedError {
    case malformed(String)
    case unsupported(String)
    case runtime(String)
    case limit(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let message): return "Malformed DEX: \(message)"
        case .unsupported(let message): return "Unsupported Android feature: \(message)"
        case .runtime(let message): return "DEX runtime: \(message)"
        case .limit(let message): return "DEX execution limit: \(message)"
        }
    }
}

public struct DexMethodReference: Hashable, CustomStringConvertible {
    public let owner: String
    public let name: String
    public let descriptor: String
    public init(owner: String, name: String, descriptor: String) {
        self.owner = owner; self.name = name; self.descriptor = descriptor
    }
    public var description: String { "\(owner)->\(name)\(descriptor)" }
}

public struct DexFieldReference: Hashable {
    public let owner: String
    public let name: String
    public let type: String
    public var key: String { "\(owner)->\(name):\(type)" }
}

public struct DexEncodedField {
    public let reference: DexFieldReference
    public let accessFlags: UInt32
}

public struct DexCode {
    public let registers: Int
    public let incomingWords: Int
    public let outgoingWords: Int
    public let instructions: [UInt16]
    public let hasExceptionHandlers: Bool
}

public struct DexEncodedMethod {
    public let reference: DexMethodReference
    public let accessFlags: UInt32
    public let code: DexCode?
    public var isStatic: Bool { accessFlags & 0x8 != 0 }
}

public struct DexClassDefinition {
    public let type: String
    public let superclass: String?
    public let interfaces: [String]
    public let accessFlags: UInt32
    public let staticFields: [DexEncodedField]
    public let instanceFields: [DexEncodedField]
    public let methods: [DexEncodedMethod]
    public let staticValues: [DexValue]
}

/// A bounds-checked reader for ordinary little-endian DEX 035–040 files.
/// Parsing does not load native code or start an Android operating system.
public struct DexFile {
    public static let maximumFileSize = 128 * 1024 * 1024
    public let strings: [String]
    public let types: [String]
    public let fields: [DexFieldReference]
    public let methods: [DexMethodReference]
    public let classes: [DexClassDefinition]

    public init(data: Data) throws {
        guard data.count <= Self.maximumFileSize else { throw DexError.limit("DEX file exceeds 128 MiB") }
        let reader = DexReader(bytes: Array(data))
        try reader.require(0, 112)
        guard Array(reader.bytes[0..<4]) == [0x64, 0x65, 0x78, 0x0a], reader.bytes[7] == 0,
              let version = String(bytes: reader.bytes[4..<7], encoding: .ascii),
              ["035", "037", "038", "039", "040"].contains(version) else {
            throw DexError.unsupported("Expected an ordinary DEX 035–040 file")
        }
        guard try reader.u32(32) == data.count, try reader.u32(36) == 112 else {
            throw DexError.malformed("File or header size does not match its header")
        }
        guard try reader.u32(40) == 0x12345678 else {
            throw DexError.unsupported("Reverse-endian DEX")
        }
        let stringTable = try reader.table(56, stride: 4)
        let typeTable = try reader.table(64, stride: 4)
        let protoTable = try reader.table(72, stride: 12)
        let fieldTable = try reader.table(80, stride: 8)
        let methodTable = try reader.table(88, stride: 8)
        let classTable = try reader.table(96, stride: 32)
        guard stringTable.count <= 1_000_000, typeTable.count <= 65_536, protoTable.count <= 65_536,
              fieldTable.count <= 65_536, methodTable.count <= 65_536, classTable.count <= 65_536 else {
            throw DexError.limit("DEX identifier counts exceed supported limits")
        }

        var strings = [String]()
        strings.reserveCapacity(stringTable.count)
        var stringCache: [Int: String] = [:]
        var stringUnits = 0
        for index in 0..<stringTable.count {
            let offset = Int(try reader.u32(stringTable.offset + index * 4))
            if let cached = stringCache[offset] { strings.append(cached) }
            else {
                let value = try reader.string(at: offset)
                // Overlapping data offsets must not amplify a small file into unbounded strings.
                stringUnits += value.utf16.count
                guard stringUnits <= data.count * 2 else { throw DexError.limit("DEX string expansion exceeds file limit") }
                stringCache[offset] = value; strings.append(value)
            }
        }
        var types = [String]()
        for index in 0..<typeTable.count {
            types.append(try Self.element(strings, Int(reader.u32(typeTable.offset + index * 4)), "type string"))
        }
        func typeList(_ offset: Int) throws -> [String] {
            if offset == 0 { return [] }
            let count = Int(try reader.u32(offset))
            try reader.requireTable(offset + 4, count, 2)
            return try (0..<count).map { try Self.element(types, Int(reader.u16(offset + 4 + $0 * 2)), "parameter type") }
        }
        var descriptors = [String]()
        for index in 0..<protoTable.count {
            let offset = protoTable.offset + index * 12
            _ = try Self.element(strings, Int(reader.u32(offset)), "prototype shorty")
            let result = try Self.element(types, Int(reader.u32(offset + 4)), "return type")
            let arguments = try typeList(Int(reader.u32(offset + 8)))
            descriptors.append("(" + arguments.joined() + ")" + result)
        }
        var fields = [DexFieldReference]()
        for index in 0..<fieldTable.count {
            let offset = fieldTable.offset + index * 8
            fields.append(DexFieldReference(
                owner: try Self.element(types, Int(reader.u16(offset)), "field owner"),
                name: try Self.element(strings, Int(reader.u32(offset + 4)), "field name"),
                type: try Self.element(types, Int(reader.u16(offset + 2)), "field type")))
        }
        var methods = [DexMethodReference]()
        for index in 0..<methodTable.count {
            let offset = methodTable.offset + index * 8
            methods.append(DexMethodReference(
                owner: try Self.element(types, Int(reader.u16(offset)), "method owner"),
                name: try Self.element(strings, Int(reader.u32(offset + 4)), "method name"),
                descriptor: try Self.element(descriptors, Int(reader.u16(offset + 2)), "method prototype")))
        }
        var classes = [DexClassDefinition]()
        var seenTypes = Set<String>()
        var codeCache: [Int: DexCode] = [:]
        var instructionUnits = 0
        var staticValueBudget = min(data.count, 2_000_000)
        for index in 0..<classTable.count {
            let offset = classTable.offset + index * 32
            let type = try Self.element(types, Int(reader.u32(offset)), "class type")
            guard seenTypes.insert(type).inserted else { throw DexError.malformed("Duplicate class \(type)") }
            let flags = try reader.u32(offset + 4)
            let superclassIndex = try reader.u32(offset + 8)
            let superclass = superclassIndex == UInt32.max ? nil : try Self.element(types, Int(superclassIndex), "superclass")
            let interfaces = try typeList(Int(reader.u32(offset + 12)))
            let classDataOffset = Int(try reader.u32(offset + 24))
            var staticFields = [DexEncodedField](), instanceFields = [DexEncodedField]()
            var classMethods = [DexEncodedMethod]()
            if classDataOffset != 0 {
                var cursor = classDataOffset
                let staticCount = try reader.uleb(&cursor)
                let instanceCount = try reader.uleb(&cursor)
                let directCount = try reader.uleb(&cursor)
                let virtualCount = try reader.uleb(&cursor)
                // Each record consumes at least two or three bytes. Reject impossible counts before allocating.
                guard staticCount <= fields.count, instanceCount <= fields.count,
                      directCount <= methods.count, virtualCount <= methods.count else {
                    throw DexError.malformed("Class member count exceeds identifier table")
                }
                func readFields(_ count: Int) throws -> [DexEncodedField] {
                    var result = [DexEncodedField](), fieldIndex = 0
                    for position in 0..<count {
                        let delta = try reader.uleb(&cursor)
                        if position > 0 && delta == 0 { throw DexError.malformed("Duplicate class field") }
                        fieldIndex += delta
                        let field = try Self.element(fields, fieldIndex, "encoded field")
                        guard field.owner == type else { throw DexError.malformed("Field belongs to another class") }
                        result.append(DexEncodedField(reference: field, accessFlags: UInt32(try reader.uleb(&cursor))))
                    }
                    return result
                }
                func readMethods(_ count: Int) throws -> [DexEncodedMethod] {
                    var result = [DexEncodedMethod](), methodIndex = 0
                    for position in 0..<count {
                        let delta = try reader.uleb(&cursor)
                        if position > 0 && delta == 0 { throw DexError.malformed("Duplicate class method") }
                        methodIndex += delta
                        let method = try Self.element(methods, methodIndex, "encoded method")
                        guard method.owner == type else { throw DexError.malformed("Method belongs to another class") }
                        let access = UInt32(try reader.uleb(&cursor))
                        let codeOffset = try reader.uleb(&cursor)
                        let code: DexCode?
                        if codeOffset == 0 { code = nil }
                        else if let cached = codeCache[codeOffset] { code = cached }
                        else {
                            let parsed = try reader.code(at: codeOffset)
                            instructionUnits += parsed.instructions.count
                            guard instructionUnits <= data.count / 2 else { throw DexError.limit("DEX instruction expansion exceeds file limit") }
                            codeCache[codeOffset] = parsed; code = parsed
                        }
                        result.append(DexEncodedMethod(reference: method, accessFlags: access, code: code))
                    }
                    return result
                }
                staticFields = try readFields(staticCount)
                instanceFields = try readFields(instanceCount)
                classMethods = try readMethods(directCount) + readMethods(virtualCount)
            }
            var staticValues = [DexValue]()
            let staticOffset = Int(try reader.u32(offset + 28))
            if staticOffset != 0 {
                var cursor = staticOffset
                let count = try reader.uleb(&cursor)
                guard count <= staticFields.count else { throw DexError.malformed("Too many static field values") }
                for _ in 0..<count { staticValues.append(try reader.encodedValue(&cursor, strings: strings, types: types, depth: 0, budget: &staticValueBudget)) }
            }
            classes.append(DexClassDefinition(type: type, superclass: superclass, interfaces: interfaces,
                                              accessFlags: flags, staticFields: staticFields, instanceFields: instanceFields,
                                              methods: classMethods, staticValues: staticValues))
        }
        self.strings = strings; self.types = types; self.fields = fields; self.methods = methods; self.classes = classes
    }

    static func element<T>(_ items: [T], _ index: Int, _ label: String) throws -> T {
        guard index >= 0, index < items.count else { throw DexError.malformed("Out-of-bounds \(label) index \(index)") }
        return items[index]
    }
}

private struct DexReader {
    let bytes: [UInt8]
    func require(_ offset: Int, _ length: Int) throws {
        guard offset >= 0, length >= 0, offset <= bytes.count, length <= bytes.count - offset else {
            throw DexError.malformed("Truncated item at byte \(offset)")
        }
    }
    func requireTable(_ offset: Int, _ count: Int, _ stride: Int) throws {
        guard offset >= 0, offset <= bytes.count, count >= 0, count <= (bytes.count - offset) / stride else {
            throw DexError.malformed("Identifier table exceeds file bounds")
        }
    }
    func table(_ header: Int, stride: Int) throws -> (count: Int, offset: Int) {
        let count = Int(try u32(header)), offset = Int(try u32(header + 4))
        if count != 0 && offset < 112 { throw DexError.malformed("Identifier table overlaps header") }
        try requireTable(offset, count, stride)
        return (count, offset)
    }
    func u16(_ offset: Int) throws -> UInt16 {
        try require(offset, 2)
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    func u32(_ offset: Int) throws -> UInt32 {
        try require(offset, 4)
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
    func byte(_ cursor: inout Int) throws -> UInt8 {
        try require(cursor, 1)
        defer { cursor += 1 }
        return bytes[cursor]
    }
    func uleb(_ cursor: inout Int) throws -> Int {
        var value: UInt32 = 0
        for shift in stride(from: 0, through: 28, by: 7) {
            let b = try byte(&cursor)
            if shift == 28 && b > 0x0f { throw DexError.malformed("Invalid unsigned LEB128") }
            value |= UInt32(b & 0x7f) << shift
            if b & 0x80 == 0 { return Int(value) }
        }
        throw DexError.malformed("Unterminated unsigned LEB128")
    }
    func sleb(_ cursor: inout Int) throws -> Int {
        var value: Int64 = 0, shift = 0
        for _ in 0..<5 {
            let b = try byte(&cursor)
            value |= Int64(b & 0x7f) << shift
            shift += 7
            if b & 0x80 == 0 {
                if b & 0x40 != 0 { value |= -(Int64(1) << shift) }
                guard value >= Int32.min, value <= Int32.max else { throw DexError.malformed("Invalid signed LEB128") }
                return Int(value)
            }
        }
        throw DexError.malformed("Unterminated signed LEB128")
    }
    func string(at offset: Int) throws -> String {
        var cursor = offset
        let utf16Count = try uleb(&cursor)
        guard utf16Count <= bytes.count - cursor else { throw DexError.malformed("Invalid string length") }
        var units = [UInt16]()
        units.reserveCapacity(utf16Count)
        while true {
            let b = try byte(&cursor)
            if b == 0 { break }
            let unit: UInt16
            if b < 0x80 { unit = UInt16(b) }
            else if b & 0xe0 == 0xc0 {
                let next = try byte(&cursor)
                guard next & 0xc0 == 0x80 else { throw DexError.malformed("Invalid modified UTF-8 string") }
                unit = UInt16(b & 0x1f) << 6 | UInt16(next & 0x3f)
                guard unit >= 0x80 || (b == 0xc0 && next == 0x80) else { throw DexError.malformed("Overlong modified UTF-8 string") }
            } else if b & 0xf0 == 0xe0 {
                let n1 = try byte(&cursor), n2 = try byte(&cursor)
                guard n1 & 0xc0 == 0x80, n2 & 0xc0 == 0x80 else { throw DexError.malformed("Invalid modified UTF-8 string") }
                unit = UInt16(b & 0xf) << 12 | UInt16(n1 & 0x3f) << 6 | UInt16(n2 & 0x3f)
                guard unit >= 0x800 else { throw DexError.malformed("Overlong modified UTF-8 string") }
            } else { throw DexError.malformed("Invalid modified UTF-8 string byte") }
            units.append(unit)
            guard units.count <= utf16Count else { throw DexError.malformed("String exceeds declared UTF-16 length") }
        }
        guard units.count == utf16Count else { throw DexError.malformed("String UTF-16 length mismatch") }
        return String(decoding: units, as: UTF16.self)
    }
    func code(at offset: Int) throws -> DexCode {
        try require(offset, 16)
        guard offset % 4 == 0 else { throw DexError.malformed("Misaligned code item") }
        let registers = Int(try u16(offset)), incoming = Int(try u16(offset + 2))
        guard incoming <= registers else { throw DexError.malformed("Incoming registers exceed method register count") }
        let outgoing = Int(try u16(offset + 4)), tries = Int(try u16(offset + 6))
        let count = Int(try u32(offset + 12))
        try requireTable(offset + 16, count, 2)
        let instructions = try (0..<count).map { try u16(offset + 16 + $0 * 2) }
        if tries != 0 {
            let tryOffset = offset + 16 + count * 2 + (count % 2) * 2
            try requireTable(tryOffset, tries, 8)
            var cursor = tryOffset + tries * 8
            let handlersBase = cursor
            let handlerCount = try uleb(&cursor)
            guard handlerCount <= bytes.count - cursor else { throw DexError.malformed("Invalid exception handler count") }
            var handlerOffsets = Set<Int>()
            for _ in 0..<handlerCount {
                handlerOffsets.insert(cursor - handlersBase)
                let size = try sleb(&cursor)
                guard abs(size) <= (bytes.count - cursor) / 2 else { throw DexError.malformed("Invalid typed exception count") }
                for _ in 0..<abs(size) {
                    _ = try uleb(&cursor)
                    guard try uleb(&cursor) < count else { throw DexError.malformed("Exception handler address exceeds code") }
                }
                if size <= 0, try uleb(&cursor) >= count { throw DexError.malformed("Catch-all address exceeds code") }
            }
            for index in 0..<tries {
                let start = Int(try u32(tryOffset + index * 8)), length = Int(try u16(tryOffset + index * 8 + 4))
                let handler = Int(try u16(tryOffset + index * 8 + 6))
                guard start <= count, length <= count - start, handlerOffsets.contains(handler) else {
                    throw DexError.malformed("Invalid exception handler region")
                }
            }
        }
        return DexCode(registers: registers, incomingWords: incoming, outgoingWords: outgoing,
                       instructions: instructions, hasExceptionHandlers: tries != 0)
    }
    func encodedValue(_ cursor: inout Int, strings: [String], types: [String], depth: Int, budget: inout Int) throws -> DexValue {
        guard depth < 32 else { throw DexError.malformed("Static value nesting exceeds 32 levels") }
        guard budget > 0 else { throw DexError.limit("Too many DEX static values") }
        budget -= 1
        let header = try byte(&cursor), kind = header & 0x1f, argument = Int(header >> 5)
        func raw(_ maxBytes: Int) throws -> UInt64 {
            guard argument + 1 <= maxBytes else { throw DexError.malformed("Encoded value length exceeds its type") }
            var value: UInt64 = 0
            for index in 0...argument { value |= UInt64(try byte(&cursor)) << (index * 8) }
            return value
        }
        func signed(_ maxBytes: Int) throws -> Int64 {
            let value = try raw(maxBytes), shift = 64 - (argument + 1) * 8
            return Int64(bitPattern: value << shift) >> shift
        }
        switch kind {
        case 0x00: return .int(Int32(try signed(1)))
        case 0x02: return .int(Int32(try signed(2)))
        case 0x03: return .int(Int32(try raw(2)))
        case 0x04: return .int(Int32(try signed(4)))
        case 0x06: return .long(try signed(8))
        case 0x10: return .float(Float(bitPattern: UInt32(try raw(4)) << ((3 - argument) * 8)))
        case 0x11: return .double(Double(bitPattern: try raw(8) << ((7 - argument) * 8)))
        case 0x17: return .string(try DexFile.element(strings, Int(raw(4)), "static string"))
        case 0x18:
            let object = DexObject(type: "Ljava/lang/Class;")
            object.fields["name"] = .string(try DexFile.element(types, Int(raw(4)), "static type"))
            return .object(object)
        case 0x1c:
            guard argument == 0 else { throw DexError.malformed("Invalid encoded array") }
            let count = try uleb(&cursor)
            guard count <= bytes.count - cursor else { throw DexError.malformed("Encoded array exceeds file bounds") }
            guard count <= budget else { throw DexError.limit("Encoded array exceeds static value limit") }
            let values = try (0..<count).map { _ in try encodedValue(&cursor, strings: strings, types: types, depth: depth + 1, budget: &budget) }
            return .array(DexArray(type: "[Ljava/lang/Object;", values: values))
        case 0x1e:
            guard argument == 0 else { throw DexError.malformed("Invalid encoded null") }
            return .null
        case 0x1f:
            guard argument <= 1 else { throw DexError.malformed("Invalid encoded boolean") }
            return .int(Int32(argument))
        default: throw DexError.unsupported(String(format: "Static encoded value 0x%02x", kind))
        }
    }
}
