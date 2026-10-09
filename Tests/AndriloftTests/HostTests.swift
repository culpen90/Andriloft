import XCTest
import AndriloftCore
import AndriloftRuntime

final class HostTests: XCTestCase {
    func testPreferenceNamespacesCannotCollide() {
        XCTAssertNotEqual(AndroidHost.preferenceSuiteName(packageName: "dev.a", name: "b.c"), AndroidHost.preferenceSuiteName(packageName: "dev.a.b", name: "c"))
        XCTAssertNotEqual(AndroidHost.preferenceSuiteName(packageName: "dev.a", name: "../b"), AndroidHost.preferenceSuiteName(packageName: "dev.a", name: "b"))
    }

    func testStringDispatchAndGrowthLimit() throws {
        let host = AndroidHost(packageName: "dev.andriloft.test")
        let vm = DexVM(files: [], host: host)
        let equals = DexMethodReference(owner: "Ljava/lang/Object;", name: "equals", descriptor: "(Ljava/lang/Object;)Z")
        XCTAssertEqual(try vm.invoke(method: equals, receiver: .string("hello"), arguments: [.string("hello")]).intValue, 1)
        XCTAssertEqual(try vm.invoke(method: equals, receiver: .string("null"), arguments: [.null]).intValue, 0)
        let builder = try vm.newObject(type: "Ljava/lang/StringBuilder;")
        _ = try vm.invoke(receiver: builder, name: "<init>", descriptor: "()V", arguments: [])
        _ = try vm.invoke(receiver: builder, name: "append", descriptor: "(Ljava/lang/String;)Ljava/lang/StringBuilder;", arguments: [.string("hello")])
        let string = try vm.invoke(method: DexMethodReference(owner: "Ljava/lang/Object;", name: "toString", descriptor: "()Ljava/lang/String;"), receiver: .object(builder), arguments: [])
        XCTAssertEqual(string.text, "hello")
        XCTAssertThrowsError(try vm.invoke(receiver: builder, name: "append", descriptor: "(Ljava/lang/String;)Ljava/lang/StringBuilder;", arguments: [.string(String(repeating: "x", count: 1_048_576))]))
    }

    func testNullPreferenceDefaultAndRemoval() throws {
        let package = "dev.andriloft.tests.\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let domain = AndroidHost.preferenceSuiteName(packageName: package, name: "store")
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let host = AndroidHost(packageName: package)
        let vm = DexVM(files: [], host: host)
        let activity = DexObject(type: "Landroid/app/Activity;")
        let store = try XCTUnwrap(try vm.invoke(receiver: activity, name: "getSharedPreferences", descriptor: "(Ljava/lang/String;I)Landroid/content/SharedPreferences;", arguments: [.string("store"), .int(0)]).objectValue)
        let value = try vm.invoke(receiver: store, name: "getString", descriptor: "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", arguments: [.string("key"), .null])
        guard case .null = value else { return XCTFail("Null default must remain null") }
        let editor = try XCTUnwrap(try vm.invoke(receiver: store, name: "edit", descriptor: "()Landroid/content/SharedPreferences$Editor;", arguments: []).objectValue)
        for value: DexValue in [.string("saved"), .null] {
            _ = try vm.invoke(receiver: editor, name: "putString", descriptor: "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;", arguments: [.string("key"), value])
            _ = try vm.invoke(receiver: editor, name: "apply", descriptor: "()V", arguments: [])
        }
        XCTAssertNil(UserDefaults(suiteName: domain)?.object(forKey: "key"))
    }
}
