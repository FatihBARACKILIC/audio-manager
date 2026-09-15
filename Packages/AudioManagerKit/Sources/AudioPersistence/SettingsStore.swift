import AudioDomain
import Foundation

/// Why a load fell back to defaults. Surfaced to the user rather than swallowed: a
/// silently emptied profile list would look like the app lost their work.
public enum StoreLoadOutcome: Sendable, Equatable {
    case loaded
    case noFileYet
    case recoveredFromCorruptFile(description: String)
    case migrated(fromVersion: Int)
}

public struct StoreLoadResult: Sendable, Equatable {
    public var state: PersistedState
    public var outcome: StoreLoadOutcome

    public init(state: PersistedState, outcome: StoreLoadOutcome) {
        self.state = state
        self.outcome = outcome
    }
}

/// Reads and writes the single JSON document that holds all persistent state.
///
/// An actor because saves happen from the UI while the schedule may be writing too;
/// serialising them is simpler and cheaper than locking, and file IO never belongs on
/// the main thread.
public actor SettingsStore {
    public static let fileName = "settings.json"

    private let fileURL: URL
    private let fileManager: FileManager

    /// - Parameter directory: Container directory for the document. Injected so tests
    ///   run against a temporary directory and never touch the user's real settings.
    public init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent(SettingsStore.fileName)
        self.fileManager = fileManager
    }

    /// Default location inside the app's Application Support container.
    public static func defaultDirectory(
        bundleIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public var url: URL { fileURL }

    /// Loads the document, falling back to defaults for a missing or unreadable file.
    /// Never throws: the app must start even when its settings are damaged.
    public func load() -> StoreLoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return StoreLoadResult(state: .empty, outcome: .noFileYet)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            var state = try decoder.decode(PersistedState.self, from: data)
            if state.schemaVersion < PersistedState.currentSchemaVersion {
                let previous = state.schemaVersion
                state = Migration.migrate(state)
                return StoreLoadResult(state: state, outcome: .migrated(fromVersion: previous))
            }
            return StoreLoadResult(state: state, outcome: .loaded)
        } catch {
            return StoreLoadResult(
                state: .empty,
                outcome: .recoveredFromCorruptFile(description: String(describing: error))
            )
        }
    }

    /// Writes atomically so a crash mid-write cannot leave a half-written document.
    public func save(_ state: PersistedState) throws {
        var state = state
        state.schemaVersion = PersistedState.currentSchemaVersion

        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// Schema migrations. Every past version must have a path to the current one.
public enum Migration {
    public static func migrate(_ state: PersistedState) -> PersistedState {
        var state = state
        // Version 1 is the first shipped schema; nothing to migrate yet. Future
        // versions chain here, each step bumping `schemaVersion` as it goes.
        state.schemaVersion = PersistedState.currentSchemaVersion
        return state
    }
}
