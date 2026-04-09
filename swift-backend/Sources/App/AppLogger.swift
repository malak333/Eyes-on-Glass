import Vapor
import Logging

public let appLogger = Logger(label: "eyes.glass.app")

public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let message = items.map { "\($0)" }.joined(separator: separator)
    appLogger.info(.init(stringLiteral: message))
}
