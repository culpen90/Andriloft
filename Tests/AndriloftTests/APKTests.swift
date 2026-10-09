import XCTest
import CZlib
@testable import AndriloftCore

final class APKTests: XCTestCase {
    func testZIPReadsStoredAndDeflatedEntriesAndChecksCRC() throws {
        let archive = try APKZIP(data: APKFixture.zip([
            ("stored.txt", Data("stored".utf8), false),
            ("deflated.txt", Data("deflated".utf8), true),
            ("empty.txt", Data(), true)
        ]))
        XCTAssertEqual(try archive.read("stored.txt"), Data("stored".utf8))
        XCTAssertEqual(try archive.read("deflated.txt"), Data("deflated".utf8))
        XCTAssertEqual(try archive.read("empty.txt"), Data())
        var damaged = APKFixture.zip([("file", Data("original".utf8), false)])
        damaged[34] ^= 1
        let damagedArchive = try APKZIP(data: damaged)
        XCTAssertThrowsError(try damagedArchive.read("file"))
    }

    func testZIPRejectsTraversalDuplicateAndTruncation() {
        XCTAssertThrowsError(try APKZIP(data: APKFixture.zip([("../manifest", Data(), false)])))
        XCTAssertThrowsError(try APKZIP(data: APKFixture.zip([("same", Data(), false), ("same", Data(), false)])))
        XCTAssertThrowsError(try APKZIP(data: APKFixture.zip([("res/é.png", Data(), false), ("res/e\u{301}.png", Data(), false)])))
        let data = APKFixture.zip([("file", Data([1, 2, 3]), false)])
        XCTAssertThrowsError(try APKZIP(data: Data(data.dropLast())))
        XCTAssertThrowsError(try APKZIP(data: Data(repeating: 0, count: 22)))
    }

    func testZIPPreservesAndroidCaseSensitiveResourceNames() throws {
        let archive = try APKZIP(data: APKFixture.zip([
            ("res/-P.png", Data([1, 2]), false),
            ("res/-p.png", Data([3, 4]), true)
        ]))
        XCTAssertEqual(try archive.read("res/-P.png"), Data([1, 2]))
        XCTAssertEqual(try archive.read("res/-p.png"), Data([3, 4]))
    }

    func testHighlyCompressedAPKAssetsRemainWithinExpansionLimits() throws {
        let asset = Data(repeating: 0, count: 1024 * 1024)
        let compressed = try APKFixture.deflate(asset)
        XCTAssertGreaterThan(asset.count / compressed.count, 500)
        let data = APKFixture.zip([
            ("AndroidManifest.xml", APKFixture.manifest(), true),
            ("assets/bin/Data/zero-filled.assets", asset, true)
        ], compressedEntries: ["assets/bin/Data/zero-filled.assets": compressed])
        let archive = try APKZIP(data: data)
        XCTAssertEqual(try archive.read("assets/bin/Data/zero-filled.assets"), asset)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".apk")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        XCTAssertEqual(try APKPackage(url: file).metadata.packageName, "com.example.demo")

        // A highly compressed stream cannot expand past the header's declared size.
        let understated = APKFixture.zip([("asset", Data([0]), true)], compressedEntries: ["asset": compressed])
        let understatedArchive = try APKZIP(data: understated)
        XCTAssertThrowsError(try understatedArchive.read("asset"))
    }

    func testZIPRejectsOverlappingAndOversizedEntries() {
        var oversized = APKFixture.zip([("file", Data([1]), true)])
        let central = 30 + 4 + 6
        oversized.replaceSubrange(22..<26, with: APKFixture.le32(200 * 1024 * 1024))
        oversized.replaceSubrange((central + 24)..<(central + 28), with: APKFixture.le32(200 * 1024 * 1024))
        XCTAssertThrowsError(try APKZIP(data: oversized))

        // Each entry is within the per-entry cap, but their combined expansion is not.
        var totalExceeded = APKFixture.zip((0..<5).map { ("\($0)", Data([0]), true) })
        let localLength = 30 + 1 + 6
        let centralStart = localLength * 5
        for index in 0..<5 {
            let declaredSize: UInt32 = index == 4 ? 1 : 128 * 1024 * 1024
            let localSize = index * localLength + 22
            let centralSize = centralStart + index * 47 + 24
            totalExceeded.replaceSubrange(localSize..<(localSize + 4), with: APKFixture.le32(declaredSize))
            totalExceeded.replaceSubrange(centralSize..<(centralSize + 4), with: APKFixture.le32(declaredSize))
        }
        XCTAssertThrowsError(try APKZIP(data: totalExceeded))

        var badLocal = APKFixture.zip([("file", Data([1]), false)])
        badLocal[30] = 0x61
        XCTAssertThrowsError(try APKZIP(data: badLocal))
    }

    func testCompiledManifestSelectsCanonicalLauncherAndResourceLabel() throws {
        let manifest = try AndroidManifest(data: APKFixture.manifest(), strings: [0x7f010000: "Example App"])
        XCTAssertEqual(manifest.metadata.packageName, "com.example.demo")
        XCTAssertEqual(manifest.metadata.displayName, "Example App")
        XCTAssertEqual(manifest.metadata.versionName, "1.2")
        XCTAssertEqual(manifest.metadata.mainActivity, "com.example.demo.MainActivity")
        XCTAssertEqual(manifest.metadata.applicationClass, "com.example.demo.DemoApplication")
        XCTAssertEqual(manifest.metadata.minimumSDK, 21)
        XCTAssertEqual(manifest.permissions, ["android.permission.INTERNET"])
    }

    func testLauncherRequiresMainAndLauncherInSameFilter() throws {
        let manifest = try AndroidManifest(data: APKFixture.manifest(separateFilters: true), strings: [:])
        XCTAssertNil(manifest.metadata.mainActivity)
    }

    func testNonexportedOrDisabledActivityCannotBecomeLauncher() throws {
        XCTAssertNil(try AndroidManifest(data: APKFixture.manifest(exported: false), strings: [:]).metadata.mainActivity)
        XCTAssertNil(try AndroidManifest(data: APKFixture.manifest(enabled: false), strings: [:]).metadata.mainActivity)
    }

    func testResourceBooleanControlsLauncherAndUnresolvedBooleanFails() throws {
        let resources = try AndroidResourceTable(data: APKFixture.resources())
        let compiled = APKFixture.manifest(exportedReference: 0x7f020000)
        XCTAssertNil(try AndroidManifest(data: compiled, strings: resources.strings, booleans: resources.booleans).metadata.mainActivity)
        XCTAssertThrowsError(try AndroidManifest(data: compiled, strings: resources.strings))
    }

    func testAliasUsesDeclaredTargetActivity() throws {
        XCTAssertEqual(try AndroidManifest(data: APKFixture.manifest(alias: true), strings: [:]).metadata.mainActivity,
                       "com.example.demo.MainActivity")
        XCTAssertThrowsError(try AndroidManifest(data: APKFixture.manifest(alias: true, aliasTarget: ".Missing"), strings: [:]))
    }

    func testMalformedCompiledXMLFailsWithoutCrashing() {
        let good = APKFixture.manifest()
        for length in [0, 7, 8, 16, good.count - 1] {
            XCTAssertThrowsError(try AndroidManifest(data: Data(good.prefix(length)), strings: [:]))
        }
        var invalidPool = good
        invalidPool.replaceSubrange(36..<40, with: APKFixture.le32(UInt32.max))
        XCTAssertThrowsError(try AndroidManifest(data: invalidPool, strings: [:]))
        var invalidEnd = good
        invalidEnd.replaceSubrange((good.count - 4)..<good.count, with: APKFixture.le32(UInt32.max - 1))
        XCTAssertThrowsError(try AndroidManifest(data: invalidEnd, strings: [:]))
        XCTAssertThrowsError(try AndroidManifest(data: Data("<manifest package='com.example'/>".utf8), strings: [:]))
    }

    func testResourceTableResolvesStringReferencesAndSkipsLocales() throws {
        let resources = try AndroidResourceTable(data: APKFixture.resources())
        XCTAssertEqual(resources.strings[0x7f010000], "Example App")
        XCTAssertEqual(resources.strings[0x7f010001], "Example App")
        XCTAssertEqual(resources.strings.count, 2)
        XCTAssertEqual(resources.booleans[0x7f020000], false)
        var bad = APKFixture.resources()
        bad.replaceSubrange(8..<12, with: APKFixture.le32(2))
        XCTAssertThrowsError(try AndroidResourceTable(data: bad))
        XCTAssertThrowsError(try AndroidResourceTable(data: Data(bad.dropLast())))
    }

    func testAPKImportCombinesManifestResourcesMultidexAndABIs() throws {
        let data = APKFixture.zip([
            ("AndroidManifest.xml", APKFixture.manifest(), true),
            ("resources.arsc", APKFixture.resources(), false),
            ("classes.dex", Data("dex\n035\0first".utf8), false),
            ("classes2.dex", Data("dex\n035\0second".utf8), true),
            ("lib/arm64-v8a/libsample.so", Data([0x7f, 0x45, 0x4c, 0x46]), false)
        ])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".apk")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        let apk = try APKPackage(url: file)
        XCTAssertEqual(apk.metadata.displayName, "Example App")
        XCTAssertEqual(apk.dexData.count, 2)
        XCTAssertEqual(apk.nativeABIs, ["arm64-v8a"])
        XCTAssertEqual(apk.nativeLibraries, ["lib/arm64-v8a/libsample.so"])
    }
}

/// Small format fixtures are constructed explicitly, so tests cover the binary reader rather than
/// depending on a shell zip program or an installed Android SDK.
private enum APKFixture {
    static let android = "http://schemas.android.com/apk/res/android"
    struct Attr {
        let name: String
        let text: String?
        let type: UInt8
        let value: UInt32
        let namespace: Bool
        init(_ name: String, _ text: String, namespace: Bool = true) {
            self.name = name; self.text = text; type = 3; value = 0; self.namespace = namespace
        }
        init(_ name: String, type: UInt8, value: UInt32) {
            self.name = name; text = nil; self.type = type; self.value = value; namespace = true
        }
    }
    struct Node {
        let name: String
        let attributes: [Attr]
        let children: [Node]
        init(_ name: String, _ attributes: [Attr] = [], _ children: [Node] = []) {
            self.name = name; self.attributes = attributes; self.children = children
        }
    }

    static func manifest(exported: Bool = true, enabled: Bool = true, separateFilters: Bool = false,
                         alias: Bool = false, aliasTarget: String = ".MainActivity", exportedReference: UInt32? = nil) -> Data {
        let main = Node("action", [Attr("name", "android.intent.action.MAIN")])
        let category = Node("category", [Attr("name", "android.intent.category.LAUNCHER")])
        let filters = separateFilters ? [Node("intent-filter", [], [main]), Node("intent-filter", [], [category])]
            : [Node("intent-filter", [], [main, category])]
        let exportedAttr = exportedReference.map { Attr("exported", type: 1, value: $0) }
            ?? Attr("exported", type: 0x12, value: exported ? 1 : 0)
        let activity = Node("activity", [Attr("name", ".MainActivity"), exportedAttr,
                                         Attr("enabled", type: 0x12, value: enabled ? 1 : 0)], alias ? [] : filters)
        let aliasNode = Node("activity-alias", [Attr("name", ".Launcher"), Attr("targetActivity", aliasTarget)], filters)
        let app = Node("application", [Attr("label", type: 1, value: 0x7f010000), Attr("name", ".DemoApplication")],
                       alias ? [activity, aliasNode] : [activity])
        let root = Node("manifest", [Attr("package", "com.example.demo", namespace: false), Attr("versionName", "1.2")],
                        [Node("uses-sdk", [Attr("minSdkVersion", type: 0x10, value: 21)]),
                         Node("uses-permission", [Attr("name", "android.permission.INTERNET")]), app])
        var strings = [android]
        func collect(_ node: Node) {
            strings.append(node.name)
            for attr in node.attributes { strings.append(attr.name); if let text = attr.text { strings.append(text) } }
            node.children.forEach(collect)
        }
        collect(root)
        strings = strings.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        func id(_ value: String) -> UInt32 { UInt32(strings.firstIndex(of: value)!) }
        func encode(_ node: Node) -> Data {
            var start = concat(le32(UInt32.max), le32(id(node.name)), le16(20), le16(20), le16(UInt16(node.attributes.count)),
                               le16(0), le16(0), le16(0))
            for attr in node.attributes {
                start += le32(attr.namespace ? id(android) : UInt32.max) + le32(id(attr.name)) + le32(attr.text.map(id) ?? UInt32.max)
                start += le16(8) + Data([0, attr.type]) + le32(attr.text.map(id) ?? attr.value)
            }
            var result = chunk(0x0102, headerExtra: le32(1) + le32(UInt32.max), payload: start)
            for child in node.children { result += encode(child) }
            result += chunk(0x0103, headerExtra: le32(1) + le32(UInt32.max), payload: le32(UInt32.max) + le32(id(node.name)))
            return result
        }
        return chunk(3, payload: pool(strings) + encode(root))
    }

    static func resources() -> Data {
        let values = pool(["Example App", "Localized name"])
        let types = pool(["string", "bool"])
        let keys = pool(["app_name", "alias", "launch_allowed"])
        var packageHeader = le32(0x7f) + Data(repeating: 0, count: 256)
        packageHeader += concat(le32(288), le32(2), le32(UInt32(288 + types.count)), le32(3), le32(0))
        func type(locale: Bool) -> Data {
            var config = le32(28) + Data(repeating: 0, count: 24)
            if locale { config[8] = 0x65; config[9] = 0x73 }
            let entries = concat(le16(8), le16(0), le32(0), le16(8), Data([0, 3]), le32(locale ? 1 : 0),
                                 le16(8), le16(0), le32(1), le16(8), Data([0, 1]), le32(0x7f010000))
            let header = concat(Data([1, 0]), le16(0), le32(2), le32(56), config)
            return chunk(0x0201, headerExtra: header, payload: le32(0) + le32(16) + entries)
        }
        let boolHeader = concat(Data([2, 0]), le16(0), le32(1), le32(52), le32(28), Data(repeating: 0, count: 24))
        let boolEntry = concat(le16(8), le16(0), le32(2), le16(8), Data([0, 0x12]), le32(0))
        let boolType = chunk(0x0201, headerExtra: boolHeader, payload: le32(0) + boolEntry)
        let package = chunk(0x0200, headerExtra: packageHeader, payload: concat(types, keys, type(locale: false), type(locale: true), boolType))
        return chunk(2, headerExtra: le32(1), payload: values + package)
    }

    static func pool(_ strings: [String]) -> Data {
        var offsets = Data()
        var contents = Data()
        for string in strings {
            offsets += le32(UInt32(contents.count))
            func length(_ count: Int) -> Data {
                count < 128 ? Data([UInt8(count)]) : Data([UInt8(0x80 | (count >> 8)), UInt8(count & 0xff)])
            }
            contents += length(string.utf16.count) + length(string.utf8.count) + Data(string.utf8) + Data([0])
        }
        while contents.count % 4 != 0 { contents.append(0) }
        let header = concat(le32(UInt32(strings.count)), le32(0), le32(0x100), le32(UInt32(28 + offsets.count)), le32(0))
        return chunk(1, headerExtra: header, payload: offsets + contents)
    }
    static func chunk(_ type: UInt16, headerExtra: Data = Data(), payload: Data) -> Data {
        concat(le16(type), le16(UInt16(8 + headerExtra.count)), le32(UInt32(8 + headerExtra.count + payload.count)), headerExtra, payload)
    }
    static func concat(_ parts: Data...) -> Data {
        var output = Data()
        for part in parts { output.append(part) }
        return output
    }
    static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xff), UInt8(value >> 8)]) }
    static func le32(_ value: UInt32) -> Data { le16(UInt16(value & 0xffff)) + le16(UInt16(value >> 16)) }
    static func crc(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0) }
        }
        return crc ^ UInt32.max
    }
    static func deflate(_ data: Data) throws -> Data {
        var output = Data(count: Int(compressBound(uLong(data.count))))
        var stream = z_stream()
        let status: Int32 = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                let initialized = deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
                                                Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                guard initialized == Z_OK else { return initialized }
                defer { deflateEnd(&stream) }
                return CZlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw APKError.malformedArchive("Test fixture compression failed.") }
        output.count = Int(stream.total_out)
        return output
    }
    static func zip(_ files: [(String, Data, Bool)], compressedEntries: [String: Data] = [:]) -> Data {
        var local = Data()
        var central = Data()
        for (name, data, deflated) in files {
            let nameData = Data(name.utf8)
            let offset = local.count
            let compressed = compressedEntries[name]
                ?? (deflated ? Data([1]) + le16(UInt16(data.count)) + le16(~UInt16(data.count)) + data : data)
            let method: UInt16 = deflated ? 8 : 0
            let common = concat(le16(0), le16(method), le16(0), le16(0), le32(crc(data)), le32(UInt32(compressed.count)), le32(UInt32(data.count)))
            local += concat(le32(0x04034b50), le16(20), common, le16(UInt16(nameData.count)), le16(0), nameData, compressed)
            central += concat(le32(0x02014b50), le16(20), le16(20), common, le16(UInt16(nameData.count)), le16(0), le16(0),
                              le16(0), le16(0), le32(0), le32(UInt32(offset)), nameData)
        }
        let end = concat(le32(0x06054b50), le16(0), le16(0), le16(UInt16(files.count)), le16(UInt16(files.count)),
                         le32(UInt32(central.count)), le32(UInt32(local.count)), le16(0))
        return local + central + end
    }
}
