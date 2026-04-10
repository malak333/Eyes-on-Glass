import Foundation
import os

public let appLogger = Logger(subsystem: "eyes.glass.app", category: "App")

/// Overrides the global print to route into the system's unified logging system.
public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let message = items.map { "\($0)" }.joined(separator: separator)
    appLogger.info("\(message, privacy: .public)")
}
