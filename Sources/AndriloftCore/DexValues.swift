import Foundation

public enum DexValue {
    case int(Int32)
    case long(Int64)
    case float(Float)
    case double(Double)
    case string(String)
    case object(DexObject)
    case array(DexArray)
    case null

    public var intValue: Int32 {
        if case .int(let value) = self { return value }
        return 0
    }
    public var objectValue: DexObject? {
        if case .object(let value) = self { return value }
        return nil
    }
    public var text: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .long(let value): return String(value)
        case .float(let value): return String(value)
        case .double(let value): return String(value)
        case .null: return "null"
        case .object(let value): return value.type
        case .array(let value): return "[\(value.values.count) values]"
        }
    }
}

public final class DexObject {
    public let id = UUID()
    public let type: String
    public var fields: [String: DexValue] = [:]
    public init(type: String) { self.type = type }
}

public final class DexArray {
    public let type: String
    public var values: [DexValue]
    public init(type: String, values: [DexValue]) {
        self.type = type
        self.values = values
    }
}

public protocol DexHost: AnyObject {
    func invoke(method: DexMethodReference, receiver: DexValue?, arguments: [DexValue], vm: DexVM) throws -> DexValue
}
