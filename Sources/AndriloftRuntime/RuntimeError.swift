import Foundation
import AndriloftCore

public enum AndroidRuntimeError: LocalizedError {
    case unsupportedAPI(String)
    case invalidArgument(String)
    case missingActivity
    case missingObject(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedAPI(let call): return "Android API is not implemented yet: \(call)"
        case .invalidArgument(let message): return message
        case .missingActivity: return "This APK has no launcher activity."
        case .missingObject(let type): return "No native control exists for \(type)."
        }
    }
}

extension DexValue {
    var numericFloat: CGFloat {
        switch self {
        case .float(let value): return CGFloat(value)
        case .int(let value): return CGFloat(Float(bitPattern: UInt32(bitPattern: value)))
        case .double(let value): return CGFloat(value)
        default: return 0
        }
    }
}
