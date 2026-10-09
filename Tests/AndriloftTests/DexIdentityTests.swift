import XCTest
@testable import AndriloftCore

final class DexIdentityTests: XCTestCase {
    func testCanonicalEquivalentClassesKeepSeparateDispatchAndStaticState() throws {
        let first = "Ldemo/\u{0390};"
        let second = "Ldemo/\u{1fd3};"
        XCTAssertEqual(first, second, "Swift considers these names equivalent")
        let files = try [program(owner: first, value: 7), program(owner: second, value: 8)].map(DexFile.init)
        let vm = DexVM(files: files, host: IdentityRejectingHost())
        for (owner, expected): (String, Int32) in [(first, 7), (second, 8), (first, 7)] {
            let method = DexMethodReference(owner: owner, name: "run", descriptor: "()I")
            XCTAssertEqual(try vm.invoke(method: method, receiver: nil, arguments: []).intValue, expected)
        }
    }

    func testCanonicalEquivalentMethodNamesDoNotAliasDuringLookup() throws {
        let owner = "Ldemo/Program;"
        let file = try DexFile(data: program(owner: owner, name: "\u{0390}", value: 7))
        let vm = DexVM(files: [file], host: IdentityRejectingHost())
        XCTAssertEqual(try vm.invoke(method: DexMethodReference(owner: owner, name: "\u{0390}", descriptor: "()I"), receiver: nil, arguments: []).intValue, 7)
        XCTAssertThrowsError(try vm.invoke(method: DexMethodReference(owner: owner, name: "\u{1fd3}", descriptor: "()I"), receiver: nil, arguments: []))
    }

    func testExactDuplicateClassAcrossDEXFilesStillFails() throws {
        let file = try DexFile(data: program(owner: "Ldemo/Program;", value: 7))
        let vm = DexVM(files: [file, file], host: IdentityRejectingHost())
        XCTAssertThrowsError(try vm.newObject(type: "Ldemo/Program;"))
    }

    /// One class, one initialized static int field, and a method reading that field.
    /// Identifier indexes preserve the original UTF-16 rather than Swift equality.
    private func program(owner: String, name: String = "run", value: UInt8) -> Data {
        let strings = ["I", owner, "Ljava/lang/Object;", name, "value"].sorted {
            $0.utf16.lexicographicallyPrecedes($1.utf16)
        }
        func stringIndex(_ value: String) -> Int { strings.firstIndex { $0.utf16.elementsEqual(value.utf16) }! }
        let types = ["I", owner, "Ljava/lang/Object;"].sorted { stringIndex($0) < stringIndex($1) }
        func typeIndex(_ value: String) -> Int { types.firstIndex { $0.utf16.elementsEqual(value.utf16) }! }
        let stringOffset = 112
        let typeOffset = stringOffset + strings.count * 4
        let protoOffset = typeOffset + types.count * 4
        let fieldOffset = protoOffset + 12
        let methodOffset = fieldOffset + 8
        let classOffset = methodOffset + 8
        let dataOffset = classOffset + 32
        var data = Data(repeating: 0, count: dataOffset)
        data.replaceSubrange(0..<8, with: Data("dex\n035\0".utf8))
        put32(112, at: 36, in: &data)
        put32(0x12345678, at: 40, in: &data)
        for (header, count, offset) in [(56, strings.count, stringOffset), (64, types.count, typeOffset), (72, 1, protoOffset), (80, 1, fieldOffset), (88, 1, methodOffset), (96, 1, classOffset)] {
            put32(UInt32(count), at: header, in: &data)
            put32(UInt32(offset), at: header + 4, in: &data)
        }
        for (index, text) in strings.enumerated() {
            put32(UInt32(data.count), at: stringOffset + index * 4, in: &data)
            data.append(contentsOf: uleb(text.utf16.count))
            data.append(contentsOf: text.utf8)
            data.append(0)
        }
        for (index, type) in types.enumerated() { put32(UInt32(stringIndex(type)), at: typeOffset + index * 4, in: &data) }
        put32(UInt32(stringIndex("I")), at: protoOffset, in: &data)
        put32(UInt32(typeIndex("I")), at: protoOffset + 4, in: &data)
        put16(UInt16(typeIndex(owner)), at: fieldOffset, in: &data)
        put16(UInt16(typeIndex("I")), at: fieldOffset + 2, in: &data)
        put32(UInt32(stringIndex("value")), at: fieldOffset + 4, in: &data)
        put16(UInt16(typeIndex(owner)), at: methodOffset, in: &data)
        put32(UInt32(stringIndex(name)), at: methodOffset + 4, in: &data)
        put32(UInt32(typeIndex(owner)), at: classOffset, in: &data)
        put32(1, at: classOffset + 4, in: &data)
        put32(UInt32(typeIndex("Ljava/lang/Object;")), at: classOffset + 8, in: &data)
        put32(UInt32.max, at: classOffset + 16, in: &data)
        put32(UInt32(data.count), at: classOffset + 28, in: &data)
        data.append(contentsOf: [1, 0x04, value]) // encoded_array: one int value
        while data.count % 4 != 0 { data.append(0) }
        let codeOffset = data.count
        data.append(contentsOf: [1, 0]) // one register
        data.append(Data(repeating: 0, count: 10))
        data.append(contentsOf: little32(3))
        data.append(contentsOf: [0x60, 0, 0, 0, 0x0f, 0]) // sget v0, field@0; return v0
        put32(UInt32(data.count), at: classOffset + 24, in: &data)
        data.append(contentsOf: [1, 0, 1, 0, 0, 9, 0, 9])
        data.append(contentsOf: uleb(codeOffset))
        put32(UInt32(data.count), at: 32, in: &data)
        put32(UInt32(data.count - dataOffset), at: 104, in: &data)
        put32(UInt32(dataOffset), at: 108, in: &data)
        return data
    }

    private func uleb(_ input: Int) -> [UInt8] {
        var value = input, result: [UInt8] = []
        repeat {
            let bits = UInt8(value & 0x7f)
            value >>= 7
            result.append(bits | (value == 0 ? 0 : 0x80))
        } while value != 0
        return result
    }
    private func little32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    private func put32(_ value: UInt32, at offset: Int, in data: inout Data) { data.replaceSubrange(offset..<(offset + 4), with: little32(value)) }
    private func put16(_ value: UInt16, at offset: Int, in data: inout Data) { data.replaceSubrange(offset..<(offset + 2), with: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
}

private final class IdentityRejectingHost: DexHost {
    func invoke(method: DexMethodReference, receiver: DexValue?, arguments: [DexValue], vm: DexVM) throws -> DexValue {
        throw DexError.unsupported("Unexpected external method \(method)")
    }
}
