import XCTest
import AndriloftCore

final class DexTests: XCTestCase {
    func testTruncatedAndInvalidTablesThrow() throws {
        let valid = minimalDEX(instructions: [0x7012, 0x000f], registers: 1)
        XCTAssertEqual(try DexFile(data: valid).classes.first?.type, "Ldemo/Program;")
        for length in [0, 7, 31, 111, valid.count - 1] {
            XCTAssertThrowsError(try DexFile(data: Data(valid.prefix(length))))
        }
        for length in 112..<valid.count {
            var truncated = Data(valid.prefix(length))
            write32(UInt32(length), at: 32, in: &truncated)
            XCTAssertThrowsError(try DexFile(data: truncated), "Accepted truncated DEX at byte \(length)")
        }
        var enormousTable = valid
        write32(UInt32.max, at: 56, in: &enormousTable)
        XCTAssertThrowsError(try DexFile(data: enormousTable))
        var invalidIndex = valid
        write32(UInt32.max, at: 128, in: &invalidIndex)
        XCTAssertThrowsError(try DexFile(data: invalidIndex))
        var invalidOffset = valid
        write32(UInt32.max, at: 112, in: &invalidOffset)
        XCTAssertThrowsError(try DexFile(data: invalidOffset))
    }

    func testInterpreterExecutesRealDEXAndJavaOverflow() throws {
        // const v0, INT_MIN; const/4 v1, -1; div-int v0, v0, v1; return v0
        let dex = try DexFile(data: minimalDEX(instructions: [0x0014, 0, 0x8000, 0xf112, 0x0093, 0x0100, 0x000f], registers: 2))
        let host = RejectingDexHost()
        let vm = DexVM(files: [dex], host: host)
        let value = try vm.invoke(method: try XCTUnwrap(dex.methods.first), receiver: nil, arguments: [])
        XCTAssertEqual(value.intValue, .min)
    }

    func testExecutionBudgetStopsGuestLoop() throws {
        let dex = try DexFile(data: minimalDEX(instructions: [0x0028], registers: 0))
        let host = RejectingDexHost()
        let vm = DexVM(files: [dex], host: host)
        vm.maximumInstructions = 10
        XCTAssertThrowsError(try vm.invoke(method: try XCTUnwrap(dex.methods.first), receiver: nil, arguments: [])) { error in
            guard case DexError.limit = error else { return XCTFail("Expected an instruction limit, received \(error)") }
        }
    }

    func testInvalidRegisterAndDivisionByZeroReturnErrors() throws {
        let host = RejectingDexHost()
        for instructions: [UInt16] in [[0x7012, 0x010f], [0x1012, 0x0112, 0x0093, 0x0100, 0x000f]] {
            let dex = try DexFile(data: minimalDEX(instructions: instructions, registers: instructions.count == 2 ? 1 : 2))
            let vm = DexVM(files: [dex], host: host)
            XCTAssertThrowsError(try vm.invoke(method: try XCTUnwrap(dex.methods.first), receiver: nil, arguments: []))
        }
    }

    func testFrameworkVirtualDispatchUsesRuntimeImplementation() throws {
        let host = RecordingDexHost()
        let testedVM = DexVM(files: [], host: host)
        let objectToString = DexMethodReference(owner: "Ljava/lang/Object;", name: "toString", descriptor: "()Ljava/lang/String;")
        _ = try testedVM.invoke(method: objectToString, receiver: .string("hello"), arguments: [])
        XCTAssertEqual(host.lastOwner, "Ljava/lang/String;")
        let builder = DexObject(type: "Ljava/lang/StringBuilder;")
        _ = try testedVM.invoke(method: objectToString, receiver: .object(builder), arguments: [])
        XCTAssertEqual(host.lastOwner, "Ljava/lang/StringBuilder;")
        let objectEquals = DexMethodReference(owner: "Ljava/lang/Object;", name: "equals", descriptor: "(Ljava/lang/Object;)Z")
        _ = try testedVM.invoke(method: objectEquals, receiver: .string("hello"), arguments: [.string("hello")])
        XCTAssertEqual(host.lastOwner, "Ljava/lang/String;")
        _ = try testedVM.invoke(method: objectEquals, receiver: .object(builder), arguments: [.object(builder)])
        XCTAssertEqual(host.lastOwner, "Ljava/lang/Object;")
        let constructor = DexMethodReference(owner: "Ljava/lang/Object;", name: "<init>", descriptor: "()V")
        _ = try testedVM.invoke(method: constructor, receiver: .object(builder), arguments: [])
        XCTAssertEqual(host.lastOwner, "Ljava/lang/Object;")
    }

    /// A small ordinary DEX with one static `Ldemo/Program;->run()I` method.
    /// The fixture checks the file-to-register execution boundary without a platform API dependency.
    private func minimalDEX(instructions: [UInt16], registers: UInt16) -> Data {
        var data = Data(repeating: 0, count: 192)
        data.replaceSubrange(0..<8, with: [0x64,0x65,0x78,0x0a,0x30,0x33,0x35,0])
        write32(112, at: 36, in: &data)
        write32(0x12345678, at: 40, in: &data)
        for (header, count, offset): (Int, UInt32, UInt32) in [(56,4,112),(64,3,128),(72,1,140),(88,1,152),(96,1,160)] {
            write32(count, at: header, in: &data); write32(offset, at: header + 4, in: &data)
        }
        for (index, text) in ["I", "Ldemo/Program;", "Ljava/lang/Object;", "run"].enumerated() {
            write32(UInt32(data.count), at: 112 + index * 4, in: &data)
            data.append(contentsOf: uleb(text.utf16.count)); data.append(contentsOf: text.utf8); data.append(0)
        }
        for index in 0..<3 { write32(UInt32(index), at: 128 + index * 4, in: &data) }
        write16(1, at: 152, in: &data) // method class index
        write32(3, at: 156, in: &data) // method name index
        write32(1, at: 160, in: &data) // class index
        write32(1, at: 164, in: &data) // public class
        write32(2, at: 168, in: &data) // Object superclass
        write32(UInt32.max, at: 176, in: &data) // no source filename
        let classData = data.count
        write32(UInt32(classData), at: 184, in: &data)
        var codeOffset = (classData + 9 + 3) & ~3
        while (classData + 6 + uleb(codeOffset).count + 3) & ~3 != codeOffset {
            codeOffset = (classData + 6 + uleb(codeOffset).count + 3) & ~3
        }
        data.append(contentsOf: [0,0,1,0,0,9]) // one public static method
        data.append(contentsOf: uleb(codeOffset))
        while data.count < codeOffset { data.append(0) }
        data.append(contentsOf: [UInt8(registers & 0xff), UInt8(registers >> 8)])
        data.append(Data(repeating: 0, count: 10))
        data.append(contentsOf: little32(UInt32(instructions.count)))
        for instruction in instructions { data.append(contentsOf: [UInt8(instruction & 0xff), UInt8(instruction >> 8)]) }
        write32(UInt32(data.count), at: 32, in: &data)
        write32(UInt32(data.count - 192), at: 104, in: &data)
        write32(192, at: 108, in: &data)
        return data
    }
    private func uleb(_ number: Int) -> [UInt8] {
        var value = number, result = [UInt8]()
        repeat { let bits = UInt8(value & 0x7f); value >>= 7; result.append(bits | (value == 0 ? 0 : 0x80)) } while value != 0
        return result
    }
    private func little32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    private func write32(_ value: UInt32, at offset: Int, in data: inout Data) { data.replaceSubrange(offset..<(offset + 4), with: little32(value)) }
    private func write16(_ value: UInt16, at offset: Int, in data: inout Data) { data.replaceSubrange(offset..<(offset + 2), with: [UInt8(value & 0xff), UInt8(value >> 8)]) }
}

private final class RejectingDexHost: DexHost {
    func invoke(method: DexMethodReference, receiver: DexValue?, arguments: [DexValue], vm: DexVM) throws -> DexValue {
        throw DexError.unsupported("Unexpected host call \(method)")
    }
}

private final class RecordingDexHost: DexHost {
    var lastOwner = ""
    func invoke(method: DexMethodReference, receiver: DexValue?, arguments: [DexValue], vm: DexVM) throws -> DexValue {
        lastOwner = method.owner
        return .null
    }
}
