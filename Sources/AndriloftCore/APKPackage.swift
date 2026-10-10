import Foundation
import CZlib

public struct APKMetadata: Codable, Equatable {
    public let packageName: String
    public let displayName: String
    public let versionName: String
    /// The class to instantiate. For an activity-alias this is its targetActivity.
    public let mainActivity: String?
    public let applicationClass: String?
    public let minimumSDK: Int?
    public let targetSDK: Int?
}

public enum APKError: Error, LocalizedError {
    case malformedArchive(String)
    case unsupportedArchive(String)
    case missingEntry(String)
    case malformedManifest(String)
    case malformedResources(String)

    public var errorDescription: String? {
        switch self {
        case .malformedArchive(let reason): return "Invalid APK archive: \(reason)"
        case .unsupportedArchive(let reason): return "Unsupported APK archive: \(reason)"
        case .missingEntry(let name): return "The APK does not contain \(name)."
        case .malformedManifest(let reason): return "Invalid Android manifest: \(reason)"
        case .malformedResources(let reason): return "Invalid Android resources: \(reason)"
        }
    }
}

/// Reads APK files in memory, without extracting or executing their contents.
/// ZIP64, encryption, split APK merging and localized resource selection are unsupported.
public struct APKPackage {
    public let url: URL
    public let metadata: APKMetadata
    public let dexData: [Data]
    public let nativeLibraries: [String]
    public let strings: [UInt32: String]
    public let permissions: [String]
    public var nativeABIs: [String] {
        Array(Set(nativeLibraries.compactMap { path in
            let components = path.split(separator: "/")
            return components.count == 3 ? String(components[1]) : nil
        })).sorted()
    }

    public init(url: URL) throws {
        self.url = url
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size <= APKZIP.maximumArchiveSize else {
            throw APKError.unsupportedArchive("The APK must be a regular file no larger than 512 MiB.")
        }
        let archive = try APKZIP(data: Data(contentsOf: url, options: .mappedIfSafe))
        let booleans: [UInt32: Bool]
        if archive.contains("resources.arsc") {
            let resources = try AndroidResourceTable(data: archive.read("resources.arsc"))
            strings = resources.strings
            booleans = resources.booleans
        } else {
            strings = [:]
            booleans = [:]
        }
        let manifest = try AndroidManifest(data: archive.read("AndroidManifest.xml"), strings: strings, booleans: booleans)
        metadata = manifest.metadata
        permissions = manifest.permissions
        let dexNames = archive.names.compactMap { name -> (String, Int)? in
            if name == "classes.dex" { return (name, 1) }
            guard name.hasPrefix("classes"), name.hasSuffix(".dex") else { return nil }
            let suffix = String(name.dropFirst(7).dropLast(4))
            guard let index = Int(suffix), index >= 2, index <= 1000, String(index) == suffix else { return nil }
            return (name, index)
        }.sorted { $0.1 < $1.1 }
        guard dexNames.isEmpty || dexNames.enumerated().allSatisfy({ $0.element.1 == $0.offset + 1 }) else {
            throw APKError.malformedArchive("The classes.dex sequence contains a gap.")
        }
        dexData = try dexNames.map { try archive.read($0.0) }
        nativeLibraries = archive.names.filter { path in
            let components = path.split(separator: "/")
            return components.count == 3 && components[0] == "lib" && components[2].hasSuffix(".so")
        }.sorted()
    }
}

// Bounds-checked little-endian reads avoid unaligned loads of untrusted file data.
private struct APKBytes {
    let data: Data
    var count: Int { data.count }

    func check(_ offset: Int, _ length: Int, limit: Int? = nil) throws {
        let end = limit ?? count
        guard offset >= 0, length >= 0, end <= count, offset <= end, length <= end - offset else {
            throw APKError.malformedArchive("A binary field extends beyond its container.")
        }
    }
    func u8(_ offset: Int) throws -> UInt8 {
        try check(offset, 1)
        return data[offset]
    }
    func u16(_ offset: Int) throws -> UInt16 {
        try check(offset, 2)
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
    func u32(_ offset: Int) throws -> UInt32 {
        try check(offset, 4)
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
    func bytes(_ offset: Int, _ length: Int) throws -> Data {
        try check(offset, length)
        return data.subdata(in: offset..<(offset + length))
    }
    func chunk(_ offset: Int, limit: Int) throws -> AndroidChunk {
        try check(offset, 8, limit: limit)
        let header = Int(try u16(offset + 2))
        let size = Int(try u32(offset + 4))
        guard header >= 8, size >= header else {
            throw APKError.malformedArchive("Invalid Android chunk size.")
        }
        try check(offset, size, limit: limit)
        return AndroidChunk(type: try u16(offset), offset: offset, headerSize: header, size: size)
    }
}

private struct AndroidChunk {
    let type: UInt16
    let offset: Int
    let headerSize: Int
    let size: Int
    var end: Int { offset + size }
}

struct APKZIP {
    static let maximumArchiveSize = 512 * 1024 * 1024
    private static let maximumEntrySize = 128 * 1024 * 1024
    private struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let dataOffset: Int
    }
    private let bytes: APKBytes
    private let entries: [String: Entry]
    var names: [String] { Array(entries.keys) }
    func contains(_ name: String) -> Bool { entries[name] != nil }

    init(data: Data) throws {
        guard data.count >= 22, data.count <= Self.maximumArchiveSize else {
            throw APKError.malformedArchive("The archive size is invalid.")
        }
        let bytes = APKBytes(data: data)
        var endOffset: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try bytes.u32(offset) == 0x06054b50,
               offset + 22 + Int(try bytes.u16(offset + 20)) == data.count {
                endOffset = offset
                break
            }
        }
        guard let end = endOffset else { throw APKError.malformedArchive("ZIP end record is missing.") }
        let count = Int(try bytes.u16(end + 10))
        guard try bytes.u16(end + 4) == 0, try bytes.u16(end + 6) == 0,
              try bytes.u16(end + 8) == UInt16(count) else {
            throw APKError.unsupportedArchive("Multi-disk ZIP files are unsupported.")
        }
        let directorySize = Int(try bytes.u32(end + 12))
        let directoryOffset = Int(try bytes.u32(end + 16))
        guard count != 65_535, directorySize != Int(UInt32.max), directoryOffset != Int(UInt32.max) else {
            throw APKError.unsupportedArchive("ZIP64 APK files are unsupported.")
        }
        guard count <= 20_000, directoryOffset <= end, directorySize == end - directoryOffset else {
            throw APKError.malformedArchive("Invalid ZIP central directory.")
        }
        var cursor = directoryOffset
        var entries: [String: Entry] = [:]
        var canonicalNames = Set<String>()
        var ranges: [Range<Int>] = []
        var totalSize = 0
        for _ in 0..<count {
            try bytes.check(cursor, 46, limit: end)
            guard try bytes.u32(cursor) == 0x02014b50 else {
                throw APKError.malformedArchive("Invalid ZIP entry signature.")
            }
            let flags = try bytes.u16(cursor + 8)
            let method = try bytes.u16(cursor + 10)
            guard flags & 0x0041 == 0 else { throw APKError.unsupportedArchive("Encrypted APK files are unsupported.") }
            guard method == 0 || method == 8 else { throw APKError.unsupportedArchive("ZIP compression method \(method) is unsupported.") }
            let crc = try bytes.u32(cursor + 16)
            let compressed = Int(try bytes.u32(cursor + 20))
            let size = Int(try bytes.u32(cursor + 24))
            let nameLength = Int(try bytes.u16(cursor + 28))
            let extraLength = Int(try bytes.u16(cursor + 30))
            let commentLength = Int(try bytes.u16(cursor + 32))
            let localOffset = Int(try bytes.u32(cursor + 42))
            guard try bytes.u16(cursor + 34) == 0, size != Int(UInt32.max),
                  compressed != Int(UInt32.max), localOffset != Int(UInt32.max) else {
                throw APKError.unsupportedArchive("ZIP64 or multi-disk entries are unsupported.")
            }
            try bytes.check(cursor + 46, nameLength + extraLength + commentLength, limit: end)
            let nameBytes = try bytes.bytes(cursor + 46, nameLength)
            guard let name = String(data: nameBytes, encoding: .utf8), !name.isEmpty,
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !name.dropLast(name.hasSuffix("/") ? 1 : 0).split(separator: "/", omittingEmptySubsequences: false)
                    .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw APKError.malformedArchive("A ZIP entry has an unsafe or invalid filename.")
            }
            // Android ZIP paths are case-sensitive. We read entries in memory and
            // never extract them onto a case-insensitive host filesystem.
            guard entries[name] == nil, canonicalNames.insert(name.precomposedStringWithCanonicalMapping).inserted else {
                throw APKError.malformedArchive("Duplicate or ambiguous ZIP entry: \(name).")
            }
            guard size <= Self.maximumEntrySize,
                  size <= Self.maximumArchiveSize - totalSize,
                  size == 0 || compressed > 0 else {
                throw APKError.unsupportedArchive("ZIP expansion limits exceeded by \(name).")
            }
            // Valid APKs can contain zero-filled assets that compress by more than
            // 1,000 times. Absolute entry/total limits bound expansion, and read()
            // inflates into a fixed-size buffer and checks the declared length.
            totalSize += size
            try bytes.check(localOffset, 30, limit: directoryOffset)
            guard try bytes.u32(localOffset) == 0x04034b50,
                  try bytes.u16(localOffset + 6) == flags, try bytes.u16(localOffset + 8) == method else {
                throw APKError.malformedArchive("Local and central headers disagree for \(name).")
            }
            let localNameLength = Int(try bytes.u16(localOffset + 26))
            let localExtraLength = Int(try bytes.u16(localOffset + 28))
            try bytes.check(localOffset + 30, localNameLength + localExtraLength, limit: directoryOffset)
            guard try bytes.bytes(localOffset + 30, localNameLength) == nameBytes else {
                throw APKError.malformedArchive("ZIP filenames disagree for \(name).")
            }
            let localCRC = try bytes.u32(localOffset + 14)
            let localCompressed = Int(try bytes.u32(localOffset + 18))
            let localSize = Int(try bytes.u32(localOffset + 22))
            let descriptor = flags & 0x0008 != 0
            guard (localCRC == crc || (descriptor && localCRC == 0)),
                  (localCompressed == compressed || (descriptor && localCompressed == 0)),
                  (localSize == size || (descriptor && localSize == 0)) else {
                throw APKError.malformedArchive("ZIP entry sizes or checksums disagree for \(name).")
            }
            guard method != 0 || compressed == size else {
                throw APKError.malformedArchive("Stored ZIP entry sizes disagree for \(name).")
            }
            let dataOffset = localOffset + 30 + localNameLength + localExtraLength
            try bytes.check(dataOffset, compressed, limit: directoryOffset)
            ranges.append(localOffset..<(dataOffset + compressed))
            entries[name] = Entry(name: name, method: method, crc: crc, compressedSize: compressed, size: size, dataOffset: dataOffset)
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard cursor == end else { throw APKError.malformedArchive("ZIP directory count or length disagrees.") }
        let orderedRanges = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<max(1, orderedRanges.count) {
            guard orderedRanges[index - 1].upperBound <= orderedRanges[index].lowerBound else {
                throw APKError.malformedArchive("ZIP entries overlap.")
            }
        }
        self.bytes = bytes
        self.entries = entries
    }

    func read(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw APKError.missingEntry(name) }
        let compressed = try bytes.bytes(entry.dataOffset, entry.compressedSize)
        let output: Data
        if entry.method == 0 {
            output = compressed
        } else {
            // An extra byte detects streams that exceed their declared size, including empty entries.
            var result = Data(count: entry.size + 1)
            var stream = z_stream()
            let status: Int32 = compressed.withUnsafeBytes { input in
                result.withUnsafeMutableBytes { buffer in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(input.count)
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    let initialized = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                    guard initialized == Z_OK else { return initialized }
                    defer { inflateEnd(&stream) }
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size,
                  stream.total_in == entry.compressedSize else {
                throw APKError.malformedArchive("Invalid deflate stream for \(name).")
            }
            result.removeLast()
            output = result
        }
        let computedCRC = output.withUnsafeBytes { buffer in
            crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
        }
        guard UInt32(computedCRC) == entry.crc else {
            throw APKError.malformedArchive("Checksum mismatch for \(name).")
        }
        return output
    }
}

private struct AndroidStringPool {
    let strings: [String]

    init(bytes: APKBytes, chunk: AndroidChunk) throws {
        guard chunk.type == 0x0001, chunk.headerSize >= 28 else {
            throw APKError.malformedArchive("Invalid Android string pool header.")
        }
        let count = Int(try bytes.u32(chunk.offset + 8))
        let styleCount = Int(try bytes.u32(chunk.offset + 12))
        let flags = try bytes.u32(chunk.offset + 16)
        let stringStart = Int(try bytes.u32(chunk.offset + 20))
        let styleStart = Int(try bytes.u32(chunk.offset + 24))
        guard count <= 1_000_000, styleCount <= count,
              stringStart >= chunk.headerSize + (count + styleCount) * 4,
              stringStart <= chunk.size, styleStart == 0 || (styleStart >= stringStart && styleStart <= chunk.size) else {
            throw APKError.malformedArchive("Invalid Android string pool offsets.")
        }
        try bytes.check(chunk.offset + chunk.headerSize, (count + styleCount) * 4, limit: chunk.end)
        let stringEnd = styleStart == 0 ? chunk.end : chunk.offset + styleStart
        var strings: [String] = []
        var decodedOffsets: [Int: String] = [:]
        var decodedBytes = 0
        strings.reserveCapacity(count)
        for index in 0..<count {
            let relative = Int(try bytes.u32(chunk.offset + chunk.headerSize + index * 4))
            if let cached = decodedOffsets[relative] {
                strings.append(cached)
                continue
            }
            var cursor = chunk.offset + stringStart + relative
            guard cursor < stringEnd else { throw APKError.malformedArchive("String offset exceeds its pool.") }
            if flags & 0x0100 != 0 {
                let utf16Length = try Self.length8(bytes, &cursor, end: stringEnd)
                let utf8Length = try Self.length8(bytes, &cursor, end: stringEnd)
                try bytes.check(cursor, utf8Length + 1, limit: stringEnd)
                guard try bytes.u8(cursor + utf8Length) == 0,
                      let value = String(data: try bytes.bytes(cursor, utf8Length), encoding: .utf8),
                      value.utf16.count == utf16Length else {
                    throw APKError.malformedArchive("Invalid UTF-8 Android string.")
                }
                guard value.utf8.count <= 128 * 1024 * 1024 - decodedBytes else {
                    throw APKError.malformedArchive("Decoded Android strings exceed the memory limit.")
                }
                decodedBytes += value.utf8.count
                decodedOffsets[relative] = value
                strings.append(value)
            } else {
                try bytes.check(cursor, 2, limit: stringEnd)
                let first = Int(try bytes.u16(cursor)); cursor += 2
                let length: Int
                if first & 0x8000 != 0 {
                    try bytes.check(cursor, 2, limit: stringEnd)
                    length = ((first & 0x7fff) << 16) | Int(try bytes.u16(cursor)); cursor += 2
                } else { length = first }
                guard length <= 16_777_216 else { throw APKError.malformedArchive("Android string is too large.") }
                try bytes.check(cursor, length * 2 + 2, limit: stringEnd)
                guard try bytes.u16(cursor + length * 2) == 0,
                      let value = String(data: try bytes.bytes(cursor, length * 2), encoding: .utf16LittleEndian) else {
                    throw APKError.malformedArchive("Invalid UTF-16 Android string.")
                }
                guard value.utf8.count <= 128 * 1024 * 1024 - decodedBytes else {
                    throw APKError.malformedArchive("Decoded Android strings exceed the memory limit.")
                }
                decodedBytes += value.utf8.count
                decodedOffsets[relative] = value
                strings.append(value)
            }
        }
        self.strings = strings
    }
    func string(_ index: UInt32) throws -> String {
        guard Int(index) < strings.count else { throw APKError.malformedArchive("Android string index is out of range.") }
        return strings[Int(index)]
    }
    private static func length8(_ bytes: APKBytes, _ cursor: inout Int, end: Int) throws -> Int {
        try bytes.check(cursor, 1, limit: end)
        let first = Int(try bytes.u8(cursor)); cursor += 1
        if first & 0x80 != 0 {
            try bytes.check(cursor, 1, limit: end)
            let second = Int(try bytes.u8(cursor)); cursor += 1
            return ((first & 0x7f) << 8) | second
        }
        return first
    }
}

private struct AndroidAttribute {
    let raw: String?
    let type: UInt8
    let value: UInt32
    let poolString: String?
    func text(resources: [UInt32: String]) -> String? {
        if type == 0x01 { return resources[value] }
        if type == 0x03 { return poolString }
        if type >= 0x10 && type <= 0x1f { return String(value) }
        return raw
    }
    func boolean(resources: [UInt32: Bool]) throws -> Bool {
        if type == 0x12 { return value != 0 }
        if type == 0x01, let result = resources[value] { return result }
        if type == 0x03 {
            if poolString == "true" { return true }
            if poolString == "false" { return false }
        }
        throw APKError.malformedManifest("An enabled/exported attribute has an invalid or unavailable boolean value.")
    }
}

private final class AndroidXMLNode {
    let name: String
    let namespace: String?
    let attributes: [String: AndroidAttribute]
    var children: [AndroidXMLNode] = []
    init(name: String, namespace: String?, attributes: [String: AndroidAttribute]) {
        self.name = name; self.namespace = namespace; self.attributes = attributes
    }
    func android(_ name: String) -> AndroidAttribute? {
        attributes["http://schemas.android.com/apk/res/android|\(name)"]
    }
    func plain(_ name: String) -> AndroidAttribute? { attributes["|\(name)"] }
    func androidBoolean(_ name: String, resources: [UInt32: Bool], fallback: Bool = true) throws -> Bool {
        guard let attribute = android(name) else { return fallback }
        return try attribute.boolean(resources: resources)
    }
}

private struct AndroidBinaryXML {
    let root: AndroidXMLNode
    init(data: Data) throws {
        let bytes = APKBytes(data: data)
        let container = try bytes.chunk(0, limit: bytes.count)
        guard container.type == 0x0003, container.size == bytes.count else {
            throw APKError.malformedManifest("Expected compiled binary Android XML.")
        }
        var pool: AndroidStringPool?
        var root: AndroidXMLNode?
        var stack: [AndroidXMLNode] = []
        var cursor = container.headerSize
        var nodeCount = 0
        while cursor < container.end {
            let chunk = try bytes.chunk(cursor, limit: container.end)
            if chunk.type == 0x0001 {
                guard pool == nil, root == nil else { throw APKError.malformedManifest("Duplicate or misplaced string pool.") }
                pool = try AndroidStringPool(bytes: bytes, chunk: chunk)
            } else if chunk.type == 0x0102 {
                guard let pool = pool, chunk.headerSize >= 16, stack.count < 256 else {
                    throw APKError.malformedManifest("Missing string pool or excessive XML nesting.")
                }
                let ext = cursor + chunk.headerSize
                try bytes.check(ext, 20, limit: chunk.end)
                let ns = try bytes.u32(ext)
                let name = try pool.string(bytes.u32(ext + 4))
                let attributeStart = Int(try bytes.u16(ext + 8))
                let attributeSize = Int(try bytes.u16(ext + 10))
                let attributeCount = Int(try bytes.u16(ext + 12))
                guard attributeStart >= 20, attributeSize >= 20, attributeCount <= 1024 else {
                    throw APKError.malformedManifest("Invalid attribute array.")
                }
                try bytes.check(ext + attributeStart, attributeSize * attributeCount, limit: chunk.end)
                var attributes: [String: AndroidAttribute] = [:]
                for index in 0..<attributeCount {
                    let at = ext + attributeStart + index * attributeSize
                    let attributeNS = try bytes.u32(at)
                    let attributeName = try pool.string(bytes.u32(at + 4))
                    let raw = try bytes.u32(at + 8)
                    let type = try bytes.u8(at + 15)
                    let value = try bytes.u32(at + 16)
                    guard try bytes.u16(at + 12) == 8, try bytes.u8(at + 14) == 0 else {
                        throw APKError.malformedManifest("Invalid typed attribute value.")
                    }
                    let namespace = attributeNS == UInt32.max ? "" : try pool.string(attributeNS)
                    let key = namespace + "|" + attributeName
                    guard attributes[key] == nil else { throw APKError.malformedManifest("Duplicate attribute \(attributeName).") }
                    attributes[key] = AndroidAttribute(raw: raw == UInt32.max ? nil : try pool.string(raw), type: type,
                                                       value: value, poolString: type == 0x03 ? try pool.string(value) : nil)
                }
                nodeCount += 1
                guard nodeCount <= 100_000 else { throw APKError.malformedManifest("The XML has too many elements.") }
                let node = AndroidXMLNode(name: name, namespace: ns == UInt32.max ? nil : try pool.string(ns), attributes: attributes)
                if let parent = stack.last { parent.children.append(node) }
                else {
                    guard root == nil else { throw APKError.malformedManifest("Multiple XML root elements.") }
                    root = node
                }
                stack.append(node)
            } else if chunk.type == 0x0103 {
                guard let pool = pool, let node = stack.last, chunk.headerSize >= 16 else {
                    throw APKError.malformedManifest("Unexpected XML end element.")
                }
                let ext = cursor + chunk.headerSize
                try bytes.check(ext, 8, limit: chunk.end)
                let ns = try bytes.u32(ext)
                guard try pool.string(bytes.u32(ext + 4)) == node.name,
                      (ns == UInt32.max ? nil : try pool.string(ns)) == node.namespace else {
                    throw APKError.malformedManifest("Mismatched XML end element.")
                }
                stack.removeLast()
            } else if chunk.type == 0x0100 || chunk.type == 0x0101 {
                guard let pool = pool, chunk.headerSize >= 16 else { throw APKError.malformedManifest("Invalid namespace node.") }
                let ext = cursor + chunk.headerSize
                try bytes.check(ext, 8, limit: chunk.end)
                let prefix = try bytes.u32(ext)
                if prefix != UInt32.max { _ = try pool.string(prefix) }
                _ = try pool.string(bytes.u32(ext + 4))
            } else if chunk.type == 0x0180 {
                guard root == nil, (chunk.size - chunk.headerSize) % 4 == 0 else {
                    throw APKError.malformedManifest("Invalid resource map.")
                }
            } else if chunk.type == 0x0104 {
                guard !stack.isEmpty, chunk.headerSize >= 16 else { throw APKError.malformedManifest("Invalid XML text node.") }
                try bytes.check(cursor + chunk.headerSize, 12, limit: chunk.end)
            } else {
                throw APKError.malformedManifest("Unexpected XML chunk type \(chunk.type).")
            }
            cursor = chunk.end
        }
        guard let root = root, stack.isEmpty else { throw APKError.malformedManifest("The XML tree is incomplete.") }
        self.root = root
    }
}

struct AndroidManifest {
    let metadata: APKMetadata
    let permissions: [String]

    init(data: Data, strings: [UInt32: String], booleans: [UInt32: Bool] = [:]) throws {
        do {
            let root = try AndroidBinaryXML(data: data).root
            guard root.name == "manifest", root.namespace == nil,
                  let packageName = root.plain("package")?.text(resources: strings),
                  Self.validClassName(packageName), packageName.contains(".") else {
                throw APKError.malformedManifest("Missing or invalid package name.")
            }
            let applications = root.children.filter { $0.name == "application" && $0.namespace == nil }
            guard applications.count == 1, let application = applications.first else {
                throw APKError.malformedManifest("Expected one application element.")
            }
            let applicationEnabled = try application.androidBoolean("enabled", resources: booleans)
            let activities = application.children.filter { ($0.name == "activity" || $0.name == "activity-alias") && $0.namespace == nil }
            var activityClasses = Set<String>()
            for activity in activities where activity.name == "activity" {
                if let name = activity.android("name")?.text(resources: strings) {
                    activityClasses.insert(try Self.canonical(name, package: packageName))
                }
            }
            var launcher: AndroidXMLNode?
            var mainActivity: String?
            if applicationEnabled {
                for activity in activities {
                    guard try activity.androidBoolean("enabled", resources: booleans),
                          try activity.androidBoolean("exported", resources: booleans) else { continue }
                    let isLauncher = activity.children.contains { filter in
                        guard filter.name == "intent-filter", filter.namespace == nil else { return false }
                        let main = filter.children.contains { $0.name == "action" && $0.namespace == nil && $0.android("name")?.text(resources: strings) == "android.intent.action.MAIN" }
                        let category = filter.children.contains { $0.name == "category" && $0.namespace == nil && $0.android("name")?.text(resources: strings) == "android.intent.category.LAUNCHER" }
                        return main && category
                    }
                    guard isLauncher else { continue }
                    let attribute = activity.name == "activity-alias" ? "targetActivity" : "name"
                    guard let name = activity.android(attribute)?.text(resources: strings) else {
                        throw APKError.malformedManifest("Launcher is missing \(attribute).")
                    }
                    let canonical = try Self.canonical(name, package: packageName)
                    guard activity.name != "activity-alias" || activityClasses.contains(canonical) else {
                        throw APKError.malformedManifest("Launcher alias targets an undeclared activity.")
                    }
                    launcher = activity
                    mainActivity = canonical
                    break
                }
            }
            let appClass = try application.android("name")?.text(resources: strings).map { try Self.canonical($0, package: packageName) }
            let displayName = launcher?.android("label")?.text(resources: strings)
                ?? application.android("label")?.text(resources: strings) ?? packageName
            let sdk = root.children.first { $0.name == "uses-sdk" && $0.namespace == nil }
            metadata = APKMetadata(packageName: packageName, displayName: displayName,
                                   versionName: root.android("versionName")?.text(resources: strings) ?? "Unknown",
                                   mainActivity: mainActivity, applicationClass: appClass,
                                   minimumSDK: sdk?.android("minSdkVersion")?.text(resources: strings).flatMap(Int.init),
                                   targetSDK: sdk?.android("targetSdkVersion")?.text(resources: strings).flatMap(Int.init))
            permissions = Array(Set(root.children.filter { ($0.name == "uses-permission" || $0.name == "uses-permission-sdk-23") && $0.namespace == nil }
                .compactMap { $0.android("name")?.text(resources: strings) })).sorted()
        } catch let error as APKError {
            switch error {
            case .malformedArchive(let reason): throw APKError.malformedManifest(reason)
            default: throw error
            }
        }
    }
    private static func canonical(_ name: String, package: String) throws -> String {
        let result = name.hasPrefix(".") ? package + name : (name.contains(".") ? name : package + "." + name)
        guard validClassName(result) else { throw APKError.malformedManifest("Invalid Android class name: \(name).") }
        return result
    }
    private static func validClassName(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { component in
            guard let first = component.unicodeScalars.first,
                  CharacterSet.letters.contains(first) || first == "_" || first == "$" else { return false }
            return component.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" }
        }
    }
}

struct AndroidResourceTable {
    let strings: [UInt32: String]
    let booleans: [UInt32: Bool]

    init(data: Data) throws {
        do {
            let bytes = APKBytes(data: data)
            let container = try bytes.chunk(0, limit: bytes.count)
            guard container.type == 0x0002, container.headerSize >= 12, container.size == bytes.count else {
                throw APKError.malformedResources("Invalid resource table header.")
            }
            let expectedPackages = Int(try bytes.u32(8))
            guard expectedPackages <= 255 else { throw APKError.malformedResources("Too many resource packages.") }
            var valuePool: AndroidStringPool?
            var packages: [AndroidChunk] = []
            var cursor = container.headerSize
            while cursor < container.end {
                let chunk = try bytes.chunk(cursor, limit: container.end)
                if chunk.type == 0x0001 {
                    guard valuePool == nil else { throw APKError.malformedResources("Duplicate resource value pool.") }
                    valuePool = try AndroidStringPool(bytes: bytes, chunk: chunk)
                } else if chunk.type == 0x0200 { packages.append(chunk) }
                cursor = chunk.end
            }
            guard packages.count == expectedPackages, let pool = valuePool else {
                throw APKError.malformedResources("Resource package count or value pool is missing.")
            }
            var values: [UInt32: (UInt8, UInt32)] = [:]
            var priorities: [UInt32: Int] = [:]
            var resourceTypes: [UInt32: String] = [:]
            var packageIDs = Set<UInt32>()
            for package in packages {
                guard package.headerSize >= 284 else { throw APKError.malformedResources("Invalid resource package header.") }
                let packageID = try bytes.u32(package.offset + 8)
                guard packageID >= 1, packageID <= 255, packageIDs.insert(packageID).inserted else {
                    throw APKError.malformedResources("Invalid or duplicate resource package ID.")
                }
                let typeOffset = package.headerSize >= 288 ? try bytes.u32(package.offset + 284) : 0
                let typePoolOffset = Int(try bytes.u32(package.offset + 268))
                let keyPoolOffset = Int(try bytes.u32(package.offset + 276))
                guard typePoolOffset >= package.headerSize, keyPoolOffset >= package.headerSize else {
                    throw APKError.malformedResources("Inherited resource packages are unsupported.")
                }
                let typePool = try AndroidStringPool(bytes: bytes, chunk: bytes.chunk(package.offset + typePoolOffset, limit: package.end))
                let keyPool = try AndroidStringPool(bytes: bytes, chunk: bytes.chunk(package.offset + keyPoolOffset, limit: package.end))
                var child = package.offset + package.headerSize
                while child < package.end {
                    let chunk = try bytes.chunk(child, limit: package.end)
                    if chunk.type == 0x0201 {
                        guard chunk.headerSize >= 24 else { throw APKError.malformedResources("Invalid resource type header.") }
                        let typeID = UInt32(try bytes.u8(child + 8))
                        let flags = try bytes.u8(child + 9)
                        let entryCount = Int(try bytes.u32(child + 12))
                        let entriesStart = Int(try bytes.u32(child + 16))
                        let configSize = Int(try bytes.u32(child + 20))
                        guard typeID > 0, typeID + typeOffset <= 255, entryCount <= 65_536,
                              configSize >= 4, configSize <= chunk.headerSize - 20,
                              entriesStart >= chunk.headerSize, entriesStart <= chunk.size,
                              flags & ~0x03 == 0, flags & 0x03 != 0x03 else {
                            throw APKError.malformedResources("Invalid resource type offsets or flags.")
                        }
                        let resourceType = try typePool.string(typeID - 1)
                        // Prefer the default configuration. Locale variants are ignored deliberately.
                        let localized = try configSize >= 12 && bytes.u32(child + 28) != 0
                        let config = try bytes.bytes(child + 24, configSize - 4)
                        let priority = config.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
                        let indexWidth = flags & 0x02 != 0 ? 2 : 4
                        try bytes.check(child + chunk.headerSize, entryCount * indexWidth, limit: child + entriesStart)
                        var previousSparseID = -1
                        for index in 0..<entryCount {
                            var entryID = index
                            let offset: Int
                            if flags & 0x01 != 0 {
                                let at = child + chunk.headerSize + index * 4
                                entryID = Int(try bytes.u16(at))
                                guard entryID > previousSparseID else {
                                    throw APKError.malformedResources("Sparse resource entries are not strictly ordered.")
                                }
                                previousSparseID = entryID
                                offset = Int(try bytes.u16(at + 2)) * 4
                            } else if flags & 0x02 != 0 {
                                let encoded = try bytes.u16(child + chunk.headerSize + index * 2)
                                if encoded == UInt16.max { continue }
                                offset = Int(encoded) * 4
                            } else {
                                let encoded = try bytes.u32(child + chunk.headerSize + index * 4)
                                if encoded == UInt32.max { continue }
                                offset = Int(encoded)
                            }
                            let at = child + entriesStart + offset
                            try bytes.check(at, 8, limit: chunk.end)
                            let entryFlags = try bytes.u16(at + 2)
                            let compact = entryFlags & 0x0008 != 0
                            let key = compact ? UInt32(try bytes.u16(at)) : try bytes.u32(at + 4)
                            _ = try keyPool.string(key)
                            let size = compact ? 8 : Int(try bytes.u16(at))
                            guard size >= 8 else { throw APKError.malformedResources("Invalid resource entry size.") }
                            try bytes.check(at, size, limit: chunk.end)
                            if entryFlags & 0x0001 != 0 {
                                guard !compact, size >= 16 else { throw APKError.malformedResources("Invalid complex resource entry.") }
                                let maps = Int(try bytes.u32(at + 12))
                                guard maps <= 1_000_000 else { throw APKError.malformedResources("Too many resource map values.") }
                                try bytes.check(at + size, maps * 12, limit: chunk.end)
                                continue
                            }
                            let type: UInt8
                            let value: UInt32
                            if compact { type = UInt8(entryFlags >> 8); value = try bytes.u32(at + 4) }
                            else {
                                try bytes.check(at + size, 8, limit: chunk.end)
                                guard try bytes.u16(at + size) == 8, try bytes.u8(at + size + 2) == 0 else {
                                    throw APKError.malformedResources("Invalid resource value.")
                                }
                                type = try bytes.u8(at + size + 3)
                                value = try bytes.u32(at + size + 4)
                            }
                            if type == 0x03 { _ = try pool.string(value) }
                            guard !localized, type == 0x03 || type == 0x01 || type == 0x12 else { continue }
                            let resourceID = (packageID << 24) | ((typeID + typeOffset) << 16) | UInt32(entryID)
                            if priorities[resourceID].map({ priority < $0 }) ?? true {
                                values[resourceID] = (type, value); priorities[resourceID] = priority
                                resourceTypes[resourceID] = resourceType
                            }
                        }
                    }
                    child = chunk.end
                }
            }
            var result: [UInt32: String] = [:]
            var booleanResult: [UInt32: Bool] = [:]
            for (id, initial) in values {
                var value = initial
                var seen: Set<UInt32> = [id]
                for _ in 0..<64 {
                    if value.0 == 0x03 {
                        if resourceTypes[id] == "string" { result[id] = try pool.string(value.1) }
                        break
                    }
                    if value.0 == 0x12 {
                        if resourceTypes[id] == "bool" { booleanResult[id] = value.1 != 0 }
                        break
                    }
                    guard seen.insert(value.1).inserted, let next = values[value.1] else { break }
                    value = next
                }
            }
            strings = result
            booleans = booleanResult
        } catch let error as APKError {
            switch error {
            case .malformedArchive(let reason): throw APKError.malformedResources(reason)
            default: throw error
            }
        }
    }
}
