import CoreAudio
import Foundation

/// Typed access to Core Audio's property API.
///
/// The C interface is a maze of selectors, sizes and out-pointers; keeping every call
/// behind these helpers means selectors appear once, sizes are computed rather than
/// guessed, and no call site can forget to check its status.
public enum AudioObjectProperty {

    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func hasProperty(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(objectID, &address)
    }

    public static func dataSize(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var address = address
        var size: UInt32 = 0
        try CoreAudioError.check(
            AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
            "AudioObjectGetPropertyDataSize(\(address.mSelector))"
        )
        return size
    }

    /// Reads a fixed-size value such as a `pid_t`, `UInt32` or `AudioStreamBasicDescription`.
    public static func value<Value>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        of type: Value.Type = Value.self
    ) throws -> Value {
        var address = address
        var size = UInt32(MemoryLayout<Value>.size)
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<Value>.size,
            alignment: MemoryLayout<Value>.alignment
        )
        defer { buffer.deallocate() }

        try CoreAudioError.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer),
            "AudioObjectGetPropertyData(\(address.mSelector))"
        )
        return buffer.assumingMemoryBound(to: Value.self).pointee
    }

    /// Reads a value, returning `nil` instead of throwing when the property is absent.
    public static func optionalValue<Value>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        of type: Value.Type = Value.self
    ) -> Value? {
        guard hasProperty(objectID, address) else { return nil }
        return try? value(objectID, address, of: type)
    }

    /// Reads a `CFString` property as a Swift `String`.
    public static func string(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress
    ) -> String? {
        guard hasProperty(objectID, address) else { return nil }
        var address = address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// Reads an array-valued property such as the process or device list.
    public static func objectIDs(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress
    ) throws -> [AudioObjectID] {
        let size = try dataSize(objectID, address)
        guard size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        var address = address
        var mutableSize = size

        let status = ids.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return noErr }
            return AudioObjectGetPropertyData(objectID, &address, 0, nil, &mutableSize, base)
        }
        try CoreAudioError.check(status, "AudioObjectGetPropertyData(list \(address.mSelector))")

        // The list can shrink between sizing and reading, so trust the returned size.
        let returned = Int(mutableSize) / MemoryLayout<AudioObjectID>.size
        return Array(ids.prefix(returned))
    }

    public static func setValue<Value>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        to value: Value
    ) throws {
        var address = address
        let selector = address.mSelector
        try withUnsafeBytes(of: value) { bytes in
            guard let base = bytes.baseAddress else { return }
            try CoreAudioError.check(
                AudioObjectSetPropertyData(objectID, &address, 0, nil, UInt32(bytes.count), base),
                "AudioObjectSetPropertyData(\(selector))"
            )
        }
    }
}

/// Selectors used by this app, named once so no four-character code is repeated at a
/// call site.
public enum AudioSelectors {
    public static let processList = kAudioHardwarePropertyProcessObjectList
    public static let defaultOutputDevice = kAudioHardwarePropertyDefaultOutputDevice
    public static let deviceUID = kAudioDevicePropertyDeviceUID
    public static let deviceNominalSampleRate = kAudioDevicePropertyNominalSampleRate
    public static let processPID = kAudioProcessPropertyPID
    public static let processBundleID = kAudioProcessPropertyBundleID
    public static let processIsRunningOutput = kAudioProcessPropertyIsRunningOutput
    public static let tapFormat = kAudioTapPropertyFormat
}
