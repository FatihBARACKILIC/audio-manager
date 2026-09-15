import CoreAudio
import Foundation

/// A failed Core Audio call, with the four-character code the C API actually returns.
///
/// Every `OSStatus` in this module goes through `CoreAudioError.check`; none are
/// discarded. Core Audio reports real, recoverable conditions this way (a device that
/// vanished, a tap that was refused), and swallowing them is how audio apps end up
/// silently broken.
public struct CoreAudioError: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }

    /// Throws when `status` is not `noErr`.
    @discardableResult
    public static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws -> OSStatus {
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: operation())
        }
        return status
    }

    /// Core Audio statuses are usually packed ASCII, e.g. 'nope' or '!obj'.
    public var codeDescription: String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let text = String(bytes: bytes, encoding: .ascii) else {
            return String(status)
        }
        return "'\(text)' (\(status))"
    }

    public var description: String {
        "\(operation) failed: \(codeDescription)"
    }
}
