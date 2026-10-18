import Foundation

public enum ConvertError: Error, CustomStringConvertible {
    case unreadable(String)
    case unsupported(String)
    case failed(String)

    public var description: String {
        switch self {
        case .unreadable(let name): return "Could not read \(name)"
        case .unsupported(let message): return message
        case .failed(let message): return message
        }
    }
}
