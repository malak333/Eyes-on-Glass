import Foundation

func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let message = items.map { "\($0)" }.joined(separator: separator)
    Swift.print("[\(timestamp)] \(message)", terminator: terminator)
}

print("Testing 1 2 3")
