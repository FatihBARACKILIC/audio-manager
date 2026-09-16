import AudioDomain
import Foundation

/// The file the user exports and keeps.
///
/// An envelope rather than the bare `PersistedState`, because every field of that type
/// decodes with a default: any JSON object at all would parse as a valid, empty
/// settings document, and importing a stray file would silently wipe everything. The
/// `format` marker is what makes "this is not an Audio Manager file" answerable.
public struct SettingsDocument: Codable, Sendable, Equatable {
    public static let formatIdentifier = "com.barackilic.AudioManager.settings"

    public var format: String
    /// When the export was made, so a folder of them can be told apart. Not required:
    /// a hand-edited file without it still imports.
    public var exportedAt: Date?
    public var settings: PersistedState

    public init(
        format: String = SettingsDocument.formatIdentifier,
        exportedAt: Date? = nil,
        settings: PersistedState
    ) {
        self.format = format
        self.exportedAt = exportedAt
        self.settings = settings
    }
}

/// Reads and writes the settings document as a file the user keeps.
///
/// The point is outliving the app: an export made today has to still import after the
/// app is deleted and reinstalled, or moved to another Mac. So it is plain, versioned
/// JSON — readable, diffable, and carried through the same migration path as the
/// app's own stored settings.
public enum SettingsTransfer {

    /// Extension for the exported document. Plain `.json` on purpose: nothing here is
    /// secret or binary, and the user should be able to open it and see what they kept.
    public static let fileExtension = "json"

    /// Suggested file name, without the extension.
    public static let suggestedFileName = "Audio Manager Settings"

    public static func data(for state: PersistedState, exportedAt: Date = Date()) throws -> Data {
        var settings = state
        settings.schemaVersion = PersistedState.currentSchemaVersion

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(SettingsDocument(exportedAt: exportedAt, settings: settings))
    }

    /// Decodes an exported document.
    ///
    /// Throws rather than falling back to defaults: a failed import must say what was
    /// wrong and change nothing. Silently replacing the user's settings with blanks
    /// because their file was unreadable would be the worst possible outcome here.
    public static func state(from data: Data) throws -> PersistedState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let document: SettingsDocument
        do {
            document = try decoder.decode(SettingsDocument.self, from: data)
        } catch {
            throw SettingsTransferError.unreadable
        }

        guard document.format == SettingsDocument.formatIdentifier else {
            throw SettingsTransferError.unreadable
        }

        // A file from a future version may lean on fields this build does not know how
        // to honour, and guessing would quietly lose settings.
        let state = document.settings
        guard state.schemaVersion <= PersistedState.currentSchemaVersion else {
            throw SettingsTransferError.newerThanThisApp(version: state.schemaVersion)
        }

        return state.schemaVersion < PersistedState.currentSchemaVersion
            ? Migration.migrate(state)
            : state
    }
}

/// Why an import was refused. Every case is something the user can act on.
///
/// Deliberately not `LocalizedError`: this package ships no string catalog, so any text
/// it carried could never be translated. The app owns every user-facing string and
/// turns these cases into localized messages.
public enum SettingsTransferError: Error, Equatable, Sendable {
    /// Not JSON, or not this app's document.
    case unreadable
    /// Written by a newer version of Audio Manager than this one.
    case newerThanThisApp(version: Int)
}
