import Foundation

/// OpenDeck's layout backup container — LaunchOS's "Export Backup" /
/// "Import Backup" (report 56 §3).
///
/// LaunchOS's own vocabulary, decoded from its strings and type metadata:
/// `BackupManager` / `BackupContainer` / `BackupMetadata` / `BackupPayload` /
/// `BackupImportError`, the UTI `app.remixdesign.LaunchOS.backup`, and the
/// messages this file reuses verbatim — `Export Backup`, `Import Backup`,
/// `Backup exported successfully to:\n%@`, `Backup file not found`,
/// `Backup version is not supported`, `Confirm Import?`.
///
/// The container is JSON: a small header (format, version, when, how many apps
/// and pages) around the layout file's **verbatim** bytes, so an import is
/// byte-identical to the layout the user exported and every future layout
/// field survives the round trip.
///
/// Pure: no file system, no dialogs — the reading and writing live in
/// `LayoutBackupService`.
enum LayoutBackup {
    /// Bumped when the container's own shape changes. A backup from a newer
    /// OpenDeck is refused rather than half-read.
    static let formatVersion = 1
    /// The marker that says "this JSON is ours". A stray `.json` in the panel
    /// is refused with the same message as a corrupt file.
    static let formatMarker = "OpenDeck.LayoutBackup"
    /// The file extension the save panel offers.
    static let fileExtension = "opendeckbackup"

    struct Container: Codable, Equatable {
        var format: String
        var version: Int
        /// ISO 8601, so a backup read on another machine still says when.
        var exportedAt: String
        var appCount: Int
        var pageCount: Int
        /// The layout file's bytes, byte for byte.
        var payload: String
    }

    enum ImportError: Error, Equatable {
        /// The file is not JSON, or not one of ours.
        case notABackup
        /// No payload, or an empty one — nothing to apply.
        case missingPayload
        /// Written by a newer OpenDeck than this one.
        case unsupportedVersion(Int)

        /// The user-facing sentence, LaunchOS's own wording.
        var message: String {
            switch self {
            case .notABackup: return "Failed to read backup file"
            case .missingPayload: return "Backup file not found"
            case .unsupportedVersion(let v): return "Backup version is not supported (\(v))"
            }
        }
    }

    /// Build the container around a layout file's bytes.
    ///
    /// - Parameters:
    ///   - exportedAt: injected, so a test can pin the header exactly.
    static func make(layoutData: Data, appCount: Int, pageCount: Int, exportedAt: Date) -> Data? {
        guard let payload = String(data: layoutData, encoding: .utf8) else { return nil }
        let container = Container(
            format: formatMarker,
            version: formatVersion,
            exportedAt: ISO8601DateFormatter().string(from: exportedAt),
            appCount: appCount,
            pageCount: pageCount,
            payload: payload
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(container)
    }

    /// The layout bytes inside a backup, or why it cannot be used.
    static func parse(_ data: Data) -> Result<Data, ImportError> {
        guard let container = try? JSONDecoder().decode(Container.self, from: data),
              container.format == formatMarker else {
            return .failure(.notABackup)
        }
        guard container.version <= formatVersion else {
            return .failure(.unsupportedVersion(container.version))
        }
        let payload = container.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, let bytes = container.payload.data(using: .utf8) else {
            return .failure(.missingPayload)
        }
        return .success(bytes)
    }

    /// The header of a backup, for the confirmation the user is asked to read
    /// (`Confirm Import?`).
    static func summary(_ data: Data) -> Container? {
        try? JSONDecoder().decode(Container.self, from: data)
    }
}
