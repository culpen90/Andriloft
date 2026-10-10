import Foundation

/// Executes application DEX bytecode and delegates supported Android/Java APIs to a macOS host.
/// The interpreter deliberately rejects instructions and services it cannot implement faithfully.
public final class DexVM {
    public var maximumInstructions = 500_000
    public var maximumCallDepth = 128
    public var maximumArrayLength = 1_000_000
    public var maximumAllocations = 20_000
    public var maximumAllocatedArraySlots = 2_000_000

    private let files: [DexFile]
    private let host: DexHost
    private var definitions: [DexIdentifier: (DexClassDefinition, Int)] = [:]
    private var staticFields: [DexFieldReference: DexValue] = [:]
    private var initializing = Set<DexIdentifier>()
    private var initialized = Set<DexIdentifier>()
    private var depth = 0
    private var steps = 0
    private var allocations = 0
    private var arraySlots = 0
    private var duplicateClasses = Set<DexIdentifier>()

    public init(files: [DexFile], host: DexHost) {
        self.files = files; self.host = host
        for (index, file) in files.enumerated() {
            for definition in file.classes {
                if definitions[DexIdentifier(definition.type)] != nil { duplicateClasses.insert(DexIdentifier(definition.type)) }
                else { definitions[DexIdentifier(definition.type)] = (definition, index) }
            }
        }
    }

    public func newObject(type: String) throws -> DexObject {
        try withExecution {
            try initialize(type)
            try countAllocation()
            let object = DexObject(type: type)
            var current: String? = type, seen = Set<DexIdentifier>()
            while let name = current, let (definition, _) = definitions[DexIdentifier(name)] {
                guard seen.insert(DexIdentifier(name)).inserted, seen.count <= maximumCallDepth else { throw DexError.malformed("Cyclic or excessive class inheritance") }
                for field in definition.instanceFields { object.dexFields[field.reference] = zero(field.reference.type) }
                current = definition.superclass
            }
            return object
        }
    }

    public func invoke(receiver: DexObject, name: String, descriptor: String, arguments: [DexValue]) throws -> DexValue {
        try invoke(method: DexMethodReference(owner: receiver.type, name: name, descriptor: descriptor),
                   receiver: .object(receiver), arguments: arguments)
    }

    public func invoke(method: DexMethodReference, receiver: DexValue?, arguments: [DexValue]) throws -> DexValue {
        try withExecution {
            try call(method, receiver: receiver, arguments: arguments,
                     kind: receiver == nil ? .staticCall : (method.name == "<init>" ? .direct : .virtual), caller: nil)
        }
    }

    private func withExecution<T>(_ body: () throws -> T) throws -> T {
        let topLevel = depth == 0
        if topLevel { steps = 0; allocations = 0; arraySlots = 0 }
        guard duplicateClasses.isEmpty else { throw DexError.malformed("Duplicate classes across DEX files: \(duplicateClasses.map(\.text).sorted().joined(separator: ", "))") }
        depth += 1
        defer { depth -= 1 }
        guard depth <= maximumCallDepth else { throw DexError.limit("Call depth exceeds \(maximumCallDepth)") }
        return try body()
    }

    private enum CallKind { case virtual, superCall, direct, staticCall, interface }

    private func initialize(_ type: String) throws {
        guard !initialized.contains(DexIdentifier(type)), !initializing.contains(DexIdentifier(type)), let (definition, _) = definitions[DexIdentifier(type)] else { return }
        guard initializing.count < maximumCallDepth else { throw DexError.limit("Class initialization depth") }
        initializing.insert(DexIdentifier(type))
        defer { initializing.remove(DexIdentifier(type)) }
        if let superclass = definition.superclass { try initialize(superclass) }
        for (index, field) in definition.staticFields.enumerated() {
            staticFields[field.reference] = index < definition.staticValues.count
                ? try coerce(definition.staticValues[index], to: field.reference.type)
                : zero(field.reference.type)
        }
        if let constructor = definition.methods.first(where: { $0.reference.name == "<clinit>" && $0.reference.descriptor == "()V" }) {
            _ = try call(constructor.reference, receiver: nil, arguments: [], kind: .staticCall, caller: nil)
        }
        initialized.insert(DexIdentifier(type))
    }

    private func lookup(_ owner: String, _ name: String, _ descriptor: String) throws -> (DexEncodedMethod, Int)? {
        var current: String? = owner, seen = Set<DexIdentifier>()
        while let type = current, let (definition, file) = definitions[DexIdentifier(type)] {
            guard seen.insert(DexIdentifier(type)).inserted, seen.count <= maximumCallDepth else { throw DexError.malformed("Cyclic class hierarchy") }
            if let method = definition.methods.first(where: { DexIdentifier($0.reference.name) == DexIdentifier(name) && DexIdentifier($0.reference.descriptor) == DexIdentifier(descriptor) }) {
                return (method, file)
            }
            current = definition.superclass
        }
        return nil
    }

    private func externalOwner(_ owner: String) throws -> String {
        var current = owner, seen = Set<DexIdentifier>()
        while let (definition, _) = definitions[DexIdentifier(current)], let superclass = definition.superclass {
            guard seen.insert(DexIdentifier(current)).inserted, seen.count <= maximumCallDepth else { throw DexError.malformed("Cyclic class hierarchy") }
            current = superclass
        }
        return current
    }

    private func call(_ reference: DexMethodReference, receiver: DexValue?, arguments: [DexValue], kind: CallKind, caller: String?) throws -> DexValue {
        try withExecution {
            let parameterTypes = try Self.parameters(reference.descriptor)
            guard parameterTypes.count == arguments.count else { throw DexError.runtime("Argument count mismatch for \(reference)") }
            let arguments = try zip(arguments, parameterTypes).map { try coerce($0.0, to: $0.1) }
            var lookupOwner = reference.owner
            var receiver = receiver
            if kind != .staticCall {
                guard let value = receiver, !isNull(value) else { throw DexError.runtime("Null receiver for \(reference)") }
                if kind == .virtual || kind == .interface { lookupOwner = valueType(value) ?? reference.owner }
                if kind == .superCall, let caller, let superclass = definitions[DexIdentifier(caller)]?.0.superclass { lookupOwner = superclass }
                receiver = try coerce(value, to: "Ljava/lang/Object;")
            }
            let found: (DexEncodedMethod, Int)?
            if kind == .direct {
                found = definitions[DexIdentifier(reference.owner)].flatMap { entry in
                    entry.0.methods.first(where: { $0.reference == reference }).map { ($0, entry.1) }
                }
            } else { found = try lookup(lookupOwner, reference.name, reference.descriptor) }
            if let (method, fileIndex) = found {
                guard method.isStatic == (kind == .staticCall) else { throw DexError.runtime("Incorrect invocation kind for \(method.reference)") }
                if method.isStatic { try initialize(method.reference.owner) }
                guard let code = method.code else { throw DexError.unsupported("Native or abstract method \(method.reference)") }
                return try execute(method, code: code, file: files[fileIndex], receiver: receiver, arguments: arguments)
            }
            var owner = try externalOwner(kind == .superCall ? lookupOwner : reference.owner)
            // Framework shims also need virtual dispatch: Object.toString on a StringBuilder
            // must call the builder implementation, while Object.equals remains inherited.
            if kind == .virtual || kind == .interface, let value = receiver, let dynamicType = valueType(value) {
                if dynamicType == "Ljava/lang/String;", ["toString", "equals", "hashCode", "length", "isEmpty", "contentEquals"].contains(reference.name) {
                    owner = dynamicType
                } else if ["Ljava/lang/StringBuilder;", "Ljava/lang/StringBuffer;"].contains(dynamicType),
                          ["toString", "length", "append"].contains(reference.name) {
                    owner = dynamicType
                }
            }
            // A missing application constructor is not an implicit call to its framework superclass.
            if kind == .direct && definitions[DexIdentifier(reference.owner)] != nil {
                throw DexError.runtime("Application method missing: \(reference)")
            }
            let hostReference = DexMethodReference(owner: owner, name: reference.name, descriptor: reference.descriptor)
            return try host.invoke(method: hostReference, receiver: receiver, arguments: arguments, vm: self)
        }
    }

    private func field(_ reference: DexFieldReference, isStatic: Bool) throws -> DexFieldReference {
        var current: String? = reference.owner, seen = Set<DexIdentifier>()
        while let type = current, let (definition, _) = definitions[DexIdentifier(type)] {
            guard seen.insert(DexIdentifier(type)).inserted, seen.count <= maximumCallDepth else { throw DexError.malformed("Cyclic field hierarchy") }
            let list = isStatic ? definition.staticFields : definition.instanceFields
            if let field = list.first(where: { DexIdentifier($0.reference.name) == DexIdentifier(reference.name) && DexIdentifier($0.reference.type) == DexIdentifier(reference.type) }) { return field.reference }
            current = definition.superclass
        }
        throw DexError.unsupported("Field \(reference.key)")
    }

    private func allocateArray(_ type: String, count: Int) throws -> DexArray {
        guard type.hasPrefix("["), count >= 0 else { throw DexError.runtime("Invalid array type or negative length") }
        guard count <= maximumArrayLength, arraySlots <= maximumAllocatedArraySlots,
              count <= maximumAllocatedArraySlots - arraySlots else { throw DexError.limit("Array allocation exceeds configured limit") }
        try countAllocation(); arraySlots += count
        return DexArray(type: type, values: Array(repeating: zero(String(type.dropFirst())), count: count))
    }

    private func countAllocation() throws {
        guard allocations < maximumAllocations else { throw DexError.limit("Too many object allocations") }
        allocations += 1
    }

    private func execute(_ method: DexEncodedMethod, code: DexCode, file: DexFile, receiver: DexValue?, arguments: [DexValue]) throws -> DexValue {
        var registers = Array(repeating: DexValue.int(0), count: code.registers)
        let parameterTypes = try Self.parameters(method.reference.descriptor)
        let needed = (method.isStatic ? 0 : 1) + parameterTypes.reduce(0) { $0 + ($1 == "J" || $1 == "D" ? 2 : 1) }
        guard needed == code.incomingWords else { throw DexError.malformed("Incoming word count mismatch for \(method.reference)") }
        func get(_ index: Int) throws -> DexValue {
            guard index >= 0, index < registers.count else { throw DexError.malformed("Register v\(index) exceeds method bounds") }
            return registers[index]
        }
        func put(_ index: Int, _ value: DexValue, wide: Bool = false) throws {
            guard index >= 0, index < registers.count, !wide || index + 1 < registers.count else {
                throw DexError.malformed("Register v\(index) exceeds method bounds")
            }
            registers[index] = value
            if wide { registers[index + 1] = .null }
        }
        var incoming = code.registers - code.incomingWords
        if !method.isStatic { try put(incoming, receiver ?? .null); incoming += 1 }
        for (value, type) in zip(arguments, parameterTypes) {
            let wide = type == "J" || type == "D"
            try put(incoming, value, wide: wide); incoming += wide ? 2 : 1
        }
        let words = code.instructions
        func word(_ index: Int) throws -> UInt16 {
            guard index >= 0, index < words.count else { throw DexError.malformed("Instruction exceeds code bounds") }
            return words[index]
        }
        func intWord(_ index: Int) throws -> Int32 {
            try Int32(bitPattern: UInt32(word(index)) | UInt32(word(index + 1)) << 16)
        }
        func integer(_ index: Int) throws -> Int32 { try int(get(index)) }
        func object(_ index: Int) throws -> DexObject {
            guard case .object(let value) = try get(index) else { throw DexError.runtime("Expected non-null object in v\(index)") }
            return value
        }
        func array(_ index: Int) throws -> DexArray {
            guard case .array(let value) = try get(index) else { throw DexError.runtime("Expected non-null array in v\(index)") }
            return value
        }
        func arrayIndex(_ value: DexArray, _ index: Int32) throws -> Int {
            guard index >= 0, Int(index) < value.values.count else { throw DexError.runtime("Array index \(index) out of bounds") }
            return Int(index)
        }
        func invocationArguments(_ indices: [Int], _ target: DexMethodReference, staticCall: Bool) throws -> (DexValue?, [DexValue]) {
            let types = try Self.parameters(target.descriptor)
            var offset = 0, result = [DexValue]()
            let receiver: DexValue?
            if staticCall { receiver = nil }
            else {
                guard !indices.isEmpty else { throw DexError.malformed("Invocation has no receiver register") }
                receiver = try get(indices[0]); offset = 1
            }
            for type in types {
                let wide = type == "J" || type == "D"
                guard offset < indices.count, !wide || offset + 1 < indices.count else { throw DexError.malformed("Invocation word count mismatch") }
                if wide && indices[offset + 1] != indices[offset] + 1 { throw DexError.malformed("Wide argument registers are not consecutive") }
                result.append(try get(indices[offset])); offset += wide ? 2 : 1
            }
            guard offset == indices.count else { throw DexError.malformed("Invocation has extra argument words") }
            return (receiver, result)
        }
        var pc = 0, result = DexValue.null
        var resultReady = false
        while pc < words.count {
            steps += 1
            guard steps <= maximumInstructions else { throw DexError.limit("More than \(maximumInstructions) instructions in one invocation") }
            let instruction = try word(pc), opcode = Int(instruction & 0xff)
            let a8 = Int(instruction >> 8), a4 = a8 & 0xf, b4 = a8 >> 4
            var next = pc + 1
            let previousResultReady = resultReady
            resultReady = false
            switch opcode {
            case 0x00:
                guard instruction == 0 else { throw DexError.malformed("Execution entered an instruction payload") }
            case 0x01, 0x04, 0x07:
                try put(a4, get(b4), wide: opcode == 0x04)
            case 0x02, 0x05, 0x08:
                try put(a8, get(Int(word(pc + 1))), wide: opcode == 0x05); next = pc + 2
            case 0x03, 0x06, 0x09:
                try put(Int(word(pc + 1)), get(Int(word(pc + 2))), wide: opcode == 0x06); next = pc + 3
            case 0x0a...0x0c:
                guard previousResultReady else { throw DexError.malformed("move-result is not immediately after an invocation") }
                try put(a8, result, wide: opcode == 0x0b)
            case 0x0d: throw DexError.unsupported("Java exception handlers in \(method.reference)")
            case 0x0e: return .null
            case 0x0f, 0x10, 0x11:
                let value = try get(a8)
                return try coerce(value, to: Self.returnType(method.reference.descriptor))
            case 0x12:
                let literal = b4 >= 8 ? b4 - 16 : b4
                try put(a4, .int(Int32(literal)))
            case 0x13:
                try put(a8, .int(Int32(Int16(bitPattern: word(pc + 1))))); next = pc + 2
            case 0x14:
                try put(a8, .int(intWord(pc + 1))); next = pc + 3
            case 0x15:
                try put(a8, .int(Int32(bitPattern: UInt32(word(pc + 1)) << 16))); next = pc + 2
            case 0x16:
                try put(a8, .long(Int64(Int16(bitPattern: word(pc + 1)))), wide: true); next = pc + 2
            case 0x17:
                try put(a8, .long(Int64(intWord(pc + 1))), wide: true); next = pc + 3
            case 0x18:
                var value: UInt64 = 0
                for part in 0..<4 { value |= UInt64(try word(pc + 1 + part)) << (part * 16) }
                try put(a8, .long(Int64(bitPattern: value)), wide: true); next = pc + 5
            case 0x19:
                try put(a8, .long(Int64(bitPattern: UInt64(word(pc + 1)) << 48)), wide: true); next = pc + 2
            case 0x1a:
                try put(a8, .string(DexFile.element(file.strings, Int(word(pc + 1)), "instruction string"))); next = pc + 2
            case 0x1b:
                try put(a8, .string(DexFile.element(file.strings, Int(UInt32(bitPattern: intWord(pc + 1))), "jumbo string"))); next = pc + 3
            case 0x1c:
                try countAllocation()
                let value = DexObject(type: "Ljava/lang/Class;")
                value.fields["name"] = .string(try DexFile.element(file.types, Int(word(pc + 1)), "class literal"))
                try put(a8, .object(value)); next = pc + 2
            case 0x1d, 0x1e: throw DexError.unsupported("Java monitor synchronization")
            case 0x1f:
                let type = try DexFile.element(file.types, Int(word(pc + 1)), "cast type")
                let value = try get(a8)
                guard try isNull(value) || isInstance(value, of: type) else { throw DexError.runtime("Class cast to \(type) failed") }
                next = pc + 2
            case 0x20:
                let type = try DexFile.element(file.types, Int(word(pc + 1)), "instance-of type")
                try put(a4, .int(isInstance(get(b4), of: type) ? 1 : 0)); next = pc + 2
            case 0x21: try put(a4, .int(Int32(array(b4).values.count)))
            case 0x22:
                let type = try DexFile.element(file.types, Int(word(pc + 1)), "new-instance type")
                guard type.hasPrefix("L") else { throw DexError.malformed("new-instance refers to a non-class type") }
                try put(a8, .object(newObject(type: type))); next = pc + 2
            case 0x23:
                let type = try DexFile.element(file.types, Int(word(pc + 1)), "new-array type")
                try put(a4, .array(allocateArray(type, count: Int(integer(b4))))); next = pc + 2
            case 0x24, 0x25:
                let type = try DexFile.element(file.types, Int(word(pc + 1)), "filled-array type")
                let indices: [Int]
                if opcode == 0x24 {
                    guard b4 <= 5 else { throw DexError.malformed("filled-array argument count exceeds five") }
                    let packed = try word(pc + 2)
                    indices = Array([Int(packed & 0xf), Int((packed >> 4) & 0xf), Int((packed >> 8) & 0xf), Int(packed >> 12), a4].prefix(b4))
                } else { let first = Int(try word(pc + 2)); indices = Array(first..<(first + a8)) }
                guard !["[J", "[D"].contains(type) else { throw DexError.malformed("filled-new-array cannot contain wide values") }
                let value = try allocateArray(type, count: indices.count)
                value.values = try indices.map { try coerce(get($0), to: String(type.dropFirst())) }
                result = .array(value); resultReady = true; next = pc + 3
            case 0x26:
                let value = try array(a8), payload = pc + Int(try intWord(pc + 1))
                guard try word(payload) == 0x0300 else { throw DexError.malformed("Invalid fill-array-data payload") }
                let width = Int(try word(payload + 1)), count = Int(UInt32(bitPattern: try intWord(payload + 2)))
                guard [1, 2, 4, 8].contains(width), count <= value.values.count else { throw DexError.malformed("Invalid array-data element count or width") }
                let elementType = String(value.type.dropFirst())
                let expected = ["Z":1, "B":1, "S":2, "C":2, "I":4, "F":4, "J":8, "D":8][elementType]
                guard expected == width else { throw DexError.malformed("Array-data width differs from element type") }
                for index in 0..<count {
                    var bits: UInt64 = 0
                    for byte in 0..<width {
                        let position = index * width + byte, packed = try word(payload + 4 + position / 2)
                        bits |= UInt64((packed >> ((position % 2) * 8)) & 0xff) << (byte * 8)
                    }
                    value.values[index] = try coerce(width == 8 ? .long(Int64(bitPattern: bits)) : .int(Int32(truncatingIfNeeded: bits)), to: elementType)
                }
                next = pc + 3
            case 0x27: throw DexError.unsupported("Java throw/catch in \(method.reference)")
            case 0x28: next = pc + Int(Int8(bitPattern: UInt8(a8)))
            case 0x29: next = pc + Int(Int16(bitPattern: try word(pc + 1)))
            case 0x2a: next = pc + Int(try intWord(pc + 1))
            case 0x2b, 0x2c:
                let payload = pc + Int(try intWord(pc + 1)), key = try integer(a8)
                guard try word(payload) == (opcode == 0x2b ? 0x0100 : 0x0200) else { throw DexError.malformed("Invalid switch payload") }
                let count = Int(try word(payload + 1))
                next = pc + 3
                if opcode == 0x2b {
                    let first = try intWord(payload + 2), index = Int64(key) - Int64(first)
                    // Validate the whole payload even if the selected key falls outside its range.
                    if count > 0 { _ = try word(payload + 3 + count * 2) }
                    if index >= 0, index < count { next = pc + Int(try intWord(payload + 4 + Int(index) * 2)) }
                } else {
                    if count > 0 { _ = try word(payload + 1 + count * 4) }
                    for index in 0..<count where try intWord(payload + 2 + index * 2) == key {
                        next = pc + Int(try intWord(payload + 2 + count * 2 + index * 2)); break
                    }
                }
            case 0x2d...0x31:
                let operands = try word(pc + 1), left = try get(Int(operands & 0xff)), right = try get(Int(operands >> 8))
                let comparison: Int32
                if opcode == 0x31 { let a = try long(left), b = try long(right); comparison = a == b ? 0 : (a < b ? -1 : 1) }
                else {
                    let a = opcode <= 0x2e ? Double(try float(left)) : try double(left)
                    let b = opcode <= 0x2e ? Double(try float(right)) : try double(right)
                    comparison = a.isNaN || b.isNaN ? (opcode == 0x2d || opcode == 0x2f ? -1 : 1) : (a == b ? 0 : (a < b ? -1 : 1))
                }
                try put(a8, .int(comparison)); next = pc + 2
            case 0x32...0x37:
                let left = try get(a4), right = try get(b4), offset = Int(Int16(bitPattern: try word(pc + 1)))
                let condition: Bool
                if opcode <= 0x33 { condition = equal(left, right) == (opcode == 0x32) }
                else { condition = try compare(int(left), int(right), operation: opcode - 0x34) }
                next = condition ? pc + offset : pc + 2
            case 0x38...0x3d:
                let value = try get(a8), offset = Int(Int16(bitPattern: try word(pc + 1)))
                let condition: Bool
                if opcode <= 0x39 { condition = isNull(value) == (opcode == 0x38) }
                else { condition = try compare(int(value), 0, operation: opcode - 0x3a) }
                next = condition ? pc + offset : pc + 2
            case 0x44...0x51:
                let operands = try word(pc + 1), value = try array(Int(operands & 0xff))
                let index = try arrayIndex(value, integer(Int(operands >> 8)))
                if opcode <= 0x4a { try put(a8, value.values[index], wide: opcode == 0x45) }
                else { value.values[index] = try coerce(get(a8), to: String(value.type.dropFirst())) }
                next = pc + 2
            case 0x52...0x5f:
                let reference = try field(DexFile.element(file.fields, Int(word(pc + 1)), "instance field"), isStatic: false)
                let value = try object(b4)
                guard try isInstance(.object(value), of: reference.owner) else { throw DexError.runtime("Field receiver has incompatible type") }
                if opcode <= 0x58 { try put(a4, value.dexFields[reference] ?? zero(reference.type), wide: opcode == 0x53) }
                else { value.dexFields[reference] = try coerce(get(a4), to: reference.type) }
                next = pc + 2
            case 0x60...0x6d:
                let reference = try field(DexFile.element(file.fields, Int(word(pc + 1)), "static field"), isStatic: true)
                try initialize(reference.owner)
                if opcode <= 0x66 { try put(a8, staticFields[reference] ?? zero(reference.type), wide: opcode == 0x61) }
                else { staticFields[reference] = try coerce(get(a8), to: reference.type) }
                next = pc + 2
            case 0x6e...0x72, 0x74...0x78:
                let target = try DexFile.element(file.methods, Int(word(pc + 1)), "invoked method")
                let base = opcode >= 0x74 ? opcode - 6 : opcode
                let kind: CallKind = base == 0x6e ? .virtual : base == 0x6f ? .superCall : base == 0x70 ? .direct : base == 0x71 ? .staticCall : .interface
                let indices: [Int]
                if opcode < 0x74 {
                    guard b4 <= 5 else { throw DexError.malformed("Invocation argument count exceeds five") }
                    let packed = try word(pc + 2)
                    indices = Array([Int(packed & 0xf), Int((packed >> 4) & 0xf), Int((packed >> 8) & 0xf), Int(packed >> 12), a4].prefix(b4))
                } else { let first = Int(try word(pc + 2)); indices = Array(first..<(first + a8)) }
                let (targetReceiver, values) = try invocationArguments(indices, target, staticCall: kind == .staticCall)
                result = try call(target, receiver: targetReceiver, arguments: values, kind: kind, caller: method.reference.owner)
                resultReady = true; next = pc + 3
            case 0x7b...0x8f:
                let value = try get(b4), converted: DexValue
                switch opcode {
                case 0x7b: converted = .int(0 &- (try int(value)))
                case 0x7c: converted = .int(~(try int(value)))
                case 0x7d: converted = .long(0 &- (try long(value)))
                case 0x7e: converted = .long(~(try long(value)))
                case 0x7f: converted = .float(-(try float(value)))
                case 0x80: converted = .double(-(try double(value)))
                case 0x81: converted = .long(Int64(try int(value)))
                case 0x82: converted = .float(Float(try int(value)))
                case 0x83: converted = .double(Double(try int(value)))
                case 0x84: converted = .int(Int32(truncatingIfNeeded: try long(value)))
                case 0x85: converted = .float(Float(try long(value)))
                case 0x86: converted = .double(Double(try long(value)))
                case 0x87: converted = .int(javaInt(Double(try float(value))))
                case 0x88: converted = .long(javaLong(Double(try float(value))))
                case 0x89: converted = .double(Double(try float(value)))
                case 0x8a: converted = .int(javaInt(try double(value)))
                case 0x8b: converted = .long(javaLong(try double(value)))
                case 0x8c: converted = .float(Float(try double(value)))
                case 0x8d: converted = .int(Int32(Int8(truncatingIfNeeded: try int(value))))
                case 0x8e: converted = .int(Int32(UInt16(truncatingIfNeeded: try int(value))))
                default: converted = .int(Int32(Int16(truncatingIfNeeded: try int(value))))
                }
                try put(a4, converted, wide: [0x7d,0x7e,0x80,0x81,0x83,0x86,0x88,0x89,0x8b].contains(opcode))
            case 0x90...0xaf, 0xb0...0xcf:
                let operation: Int, left: DexValue, right: DexValue, destination: Int
                if opcode >= 0xb0 { operation = opcode - 0x20; destination = a4; left = try get(a4); right = try get(b4) }
                else { operation = opcode; destination = a8; let operands = try word(pc + 1); left = try get(Int(operands & 0xff)); right = try get(Int(operands >> 8)); next = pc + 2 }
                let value = try binary(operation, left, right)
                try put(destination, value, wide: (0x9b...0xa5).contains(operation) || (0xab...0xaf).contains(operation))
            case 0xd0...0xe2:
                let left: Int32, literal: Int32, destination: Int, operation: Int
                if opcode <= 0xd7 {
                    left = try integer(b4); literal = Int32(Int16(bitPattern: try word(pc + 1))); destination = a4; operation = opcode - 0xd0
                } else {
                    let operands = try word(pc + 1)
                    left = try integer(Int(operands & 0xff)); literal = Int32(Int8(bitPattern: UInt8(operands >> 8))); destination = a8; operation = opcode - 0xd8
                }
                let value = operation == 1 ? literal &- left : try intBinary(operation == 0 ? 0 : operation, left, literal, reverseSubtract: operation == 1)
                try put(destination, .int(value)); next = pc + 2
            default: throw DexError.unsupported(String(format: "Dalvik opcode 0x%02x at %@ +%d", opcode, method.reference.description, pc))
            }
            guard next >= 0, next < words.count else { throw DexError.malformed("Method fell through or branched outside code at \(method.reference) +\(pc)") }
            pc = next
        }
        throw DexError.malformed("Method has no return: \(method.reference)")
    }

    private func intBinary(_ operation: Int, _ a: Int32, _ b: Int32, reverseSubtract: Bool = false) throws -> Int32 {
        switch operation {
        case 0: return a &+ b
        case 1: return reverseSubtract ? b &- a : a &- b
        case 2: return a &* b
        case 3:
            guard b != 0 else { throw DexError.runtime("Integer division by zero") }
            return a == Int32.min && b == -1 ? Int32.min : a / b
        case 4:
            guard b != 0 else { throw DexError.runtime("Integer remainder by zero") }
            return a == Int32.min && b == -1 ? 0 : a % b
        case 5: return a & b
        case 6: return a | b
        case 7: return a ^ b
        case 8: return a &<< (b & 31)
        case 9: return a >> (b & 31)
        case 10: return Int32(bitPattern: UInt32(bitPattern: a) >> (b & 31))
        default: throw DexError.unsupported("Integer arithmetic operation \(operation)")
        }
    }

    private func binary(_ opcode: Int, _ left: DexValue, _ right: DexValue) throws -> DexValue {
        if opcode <= 0x9a { return .int(try intBinary(opcode - 0x90, int(left), int(right))) }
        if opcode <= 0xa5 {
            let a = try long(left), operation = opcode - 0x9b
            let b: Int64 = operation >= 8 ? Int64(try int(right)) : try long(right)
            switch operation {
            case 0: return .long(a &+ b)
            case 1: return .long(a &- b)
            case 2: return .long(a &* b)
            case 3:
                guard b != 0 else { throw DexError.runtime("Long division by zero") }
                return .long(a == Int64.min && b == -1 ? Int64.min : a / b)
            case 4:
                guard b != 0 else { throw DexError.runtime("Long remainder by zero") }
                return .long(a == Int64.min && b == -1 ? 0 : a % b)
            case 5: return .long(a & b)
            case 6: return .long(a | b)
            case 7: return .long(a ^ b)
            case 8: return .long(a &<< (b & 63))
            case 9: return .long(a >> (b & 63))
            default: return .long(Int64(bitPattern: UInt64(bitPattern: a) >> (b & 63)))
            }
        }
        if opcode <= 0xaa {
            let a = try float(left), b = try float(right)
            switch opcode - 0xa6 {
            case 0: return .float(a + b)
            case 1: return .float(a - b)
            case 2: return .float(a * b)
            case 3: return .float(a / b)
            default: return .float(a.truncatingRemainder(dividingBy: b))
            }
        }
        let a = try double(left), b = try double(right)
        switch opcode - 0xab {
        case 0: return .double(a + b)
        case 1: return .double(a - b)
        case 2: return .double(a * b)
        case 3: return .double(a / b)
        default: return .double(a.truncatingRemainder(dividingBy: b))
        }
    }

    private func int(_ value: DexValue) throws -> Int32 {
        if case .int(let number) = value { return number }
        if case .float(let number) = value { return Int32(bitPattern: number.bitPattern) }
        throw DexError.runtime("Expected 32-bit primitive register")
    }
    private func long(_ value: DexValue) throws -> Int64 {
        if case .long(let number) = value { return number }
        if case .double(let number) = value { return Int64(bitPattern: number.bitPattern) }
        throw DexError.runtime("Expected 64-bit primitive register")
    }
    private func float(_ value: DexValue) throws -> Float {
        if case .float(let number) = value { return number }
        if case .int(let number) = value { return Float(bitPattern: UInt32(bitPattern: number)) }
        throw DexError.runtime("Expected float register")
    }
    private func double(_ value: DexValue) throws -> Double {
        if case .double(let number) = value { return number }
        if case .long(let number) = value { return Double(bitPattern: UInt64(bitPattern: number)) }
        throw DexError.runtime("Expected double register")
    }
    private func coerce(_ value: DexValue, to type: String) throws -> DexValue {
        switch type {
        case "V": return .null
        case "Z": return .int((try int(value)) & 1)
        case "B": return .int(Int32(Int8(truncatingIfNeeded: try int(value))))
        case "S": return .int(Int32(Int16(truncatingIfNeeded: try int(value))))
        case "C": return .int(Int32(UInt16(truncatingIfNeeded: try int(value))))
        case "I": return .int(try int(value))
        case "J": return .long(try long(value))
        case "F": return .float(try float(value))
        case "D": return .double(try double(value))
        default:
            guard type.hasPrefix("L") || type.hasPrefix("[") else { throw DexError.malformed("Invalid value type descriptor \(type)") }
            if isNull(value) { return .null }
            guard valueType(value) != nil else { throw DexError.runtime("Primitive used as an object reference") }
            return value
        }
    }
    private func zero(_ type: String) -> DexValue {
        switch type {
        case "J": return .long(0)
        case "F": return .float(0)
        case "D": return .double(0)
        default: return type.hasPrefix("L") || type.hasPrefix("[") ? .null : .int(0)
        }
    }
    private func isNull(_ value: DexValue) -> Bool {
        if case .null = value { return true }
        if case .int(0) = value { return true }
        return false
    }
    private func valueType(_ value: DexValue) -> String? {
        switch value {
        case .object(let object): return object.type
        case .string: return "Ljava/lang/String;"
        case .array(let array): return array.type
        default: return nil
        }
    }
    private func equal(_ a: DexValue, _ b: DexValue) -> Bool {
        if isNull(a) && isNull(b) { return true }
        switch (a, b) {
        case (.int(let x), .int(let y)): return x == y
        case (.object(let x), .object(let y)): return x === y
        case (.array(let x), .array(let y)): return x === y
        case (.string(let x), .string(let y)): return DexIdentifier(x) == DexIdentifier(y) // DEX constant strings are interned.
        default: return false
        }
    }
    private func compare(_ a: Int32, _ b: Int32, operation: Int) -> Bool {
        switch operation { case 0: return a < b; case 1: return a >= b; case 2: return a > b; default: return a <= b }
    }
    private func isInstance(_ value: DexValue, of target: String) throws -> Bool {
        guard let start = valueType(value) else { return false }
        if target == "Ljava/lang/Object;" || DexIdentifier(target) == DexIdentifier(start) { return true }
        if start.hasPrefix("[") { return target == "Ljava/lang/Cloneable;" || target == "Ljava/io/Serializable;" }
        let externalParents: [String: [String]] = [
            "Ljava/lang/String;": ["Ljava/lang/CharSequence;", "Ljava/io/Serializable;", "Ljava/lang/Comparable;"],
            "Ljava/lang/StringBuilder;": ["Ljava/lang/CharSequence;", "Ljava/lang/Appendable;"],
            "Ljava/lang/StringBuffer;": ["Ljava/lang/CharSequence;", "Ljava/lang/Appendable;", "Ljava/io/Serializable;"],
            "Landroid/app/Activity;": ["Landroid/view/ContextThemeWrapper;", "Landroid/content/ContextWrapper;", "Landroid/content/Context;"],
            "Landroid/app/Application;": ["Landroid/content/ContextWrapper;", "Landroid/content/Context;"],
            "Landroid/view/ContextThemeWrapper;": ["Landroid/content/ContextWrapper;", "Landroid/content/Context;"],
            "Landroid/content/ContextWrapper;": ["Landroid/content/Context;"],
            "Landroid/widget/Button;": ["Landroid/widget/TextView;", "Landroid/view/View;"],
            "Landroid/widget/EditText;": ["Landroid/widget/TextView;", "Landroid/view/View;"],
            "Landroid/widget/TextView;": ["Landroid/view/View;"],
            "Landroid/widget/LinearLayout;": ["Landroid/view/ViewGroup;", "Landroid/view/View;"],
            "Landroid/widget/FrameLayout;": ["Landroid/view/ViewGroup;", "Landroid/view/View;"],
            "Landroid/widget/ScrollView;": ["Landroid/widget/FrameLayout;", "Landroid/view/ViewGroup;", "Landroid/view/View;"],
            "Landroid/view/ViewGroup;": ["Landroid/view/View;"]
        ]
        var pending = [start], seen = Set<DexIdentifier>()
        while let type = pending.popLast() {
            if DexIdentifier(type) == DexIdentifier(target) { return true }
            guard seen.insert(DexIdentifier(type)).inserted else { continue }
            guard seen.count <= maximumCallDepth * 4 else { throw DexError.malformed("Excessive class/interface hierarchy") }
            if let (definition, _) = definitions[DexIdentifier(type)] {
                if let superclass = definition.superclass { pending.append(superclass) }
                pending.append(contentsOf: definition.interfaces)
            } else { pending.append(contentsOf: externalParents[type] ?? []) }
        }
        return false
    }
    private func javaInt(_ value: Double) -> Int32 {
        if value.isNaN { return 0 }
        if value >= Double(Int32.max) { return .max }
        if value <= Double(Int32.min) { return .min }
        return Int32(value)
    }
    private func javaLong(_ value: Double) -> Int64 {
        if value.isNaN { return 0 }
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value)
    }
    private static func returnType(_ descriptor: String) throws -> String {
        guard let closing = descriptor.firstIndex(of: ")") else { throw DexError.malformed("Invalid method descriptor") }
        let result = String(descriptor[descriptor.index(after: closing)...])
        guard !result.isEmpty else { throw DexError.malformed("Missing method return type") }
        return result
    }
    private static func parameters(_ descriptor: String) throws -> [String] {
        let characters = Array(descriptor)
        guard characters.first == "(" else { throw DexError.malformed("Invalid method descriptor") }
        var result = [String](), cursor = 1
        while cursor < characters.count, characters[cursor] != ")" {
            let start = cursor
            while cursor < characters.count, characters[cursor] == "[" { cursor += 1 }
            guard cursor < characters.count else { throw DexError.malformed("Invalid array descriptor") }
            if characters[cursor] == "L" {
                cursor += 1
                while cursor < characters.count, characters[cursor] != ";" { cursor += 1 }
                guard cursor < characters.count else { throw DexError.malformed("Unterminated object descriptor") }
                cursor += 1
            } else {
                guard "ZBSCIJFD".contains(characters[cursor]) else { throw DexError.malformed("Invalid parameter descriptor") }
                cursor += 1
            }
            result.append(String(characters[start..<cursor]))
        }
        guard cursor < characters.count, characters[cursor] == ")", cursor + 1 < characters.count else { throw DexError.malformed("Invalid method descriptor") }
        return result
    }
}
