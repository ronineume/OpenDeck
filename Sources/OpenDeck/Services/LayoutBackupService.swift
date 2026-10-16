import AppKit
import UniformTypeIdentifiers

/// Export / Import Backup — LaunchOS's "Layout Data Backup" (report 56 §3).
///
/// The panels and alerts are the only impure part; the container itself is
/// `LayoutBackup` and the adoption is `DeckStore.adoptBackupPayload`. Wording
/// is LaunchOS's own: `Export Backup`, `Import Backup`,
/// `Backup exported successfully to:\n%@`, `Confirm Import?`.
///
/// Every entry point refuses to run headless — a self-test must never write a
/// file into the user's home or put a panel on screen — the same contract the
/// uninstall and Dock changes keep.
@MainActor
enum LayoutBackupService {

    /// Asks where to save, then writes the container.
    static func export(store: DeckStore) {
        guard DeckSettings.shared.mayPersist else { return }
        guard let layoutData = store.layoutFileData() else {
            report(title: "Export Failed",
                   message: "The layout file could not be read.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Backup"
        panel.message = "Please select a folder to save the backup file"
        panel.nameFieldStringValue = "OpenDeck Layout.\(LayoutBackup.fileExtension)"
        if let type = UTType(filenameExtension: LayoutBackup.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let backup = LayoutBackup.make(layoutData: layoutData,
                                            appCount: store.visibleApps.count,
                                            pageCount: store.pages.count,
                                            exportedAt: Date()) else {
            report(title: "Export Failed", message: "The backup could not be encoded.")
            return
        }
        do {
            try backup.write(to: url)
            report(title: "Export Success",
                   message: "Backup exported successfully to:\n\(url.path)")
        } catch {
            report(title: "Export Failed", message: error.localizedDescription)
        }
    }

    /// Asks for a backup, validates it, confirms, then adopts the payload.
    static func importBackup(into store: DeckStore) {
        guard DeckSettings.shared.mayPersist else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Backup"
        panel.message = "Please select an OpenDeck backup file to import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            report(title: "Import Failed", message: "Failed to read backup file")
            return
        }
        switch LayoutBackup.parse(data) {
        case .failure(let error):
            report(title: "Import Failed", message: error.message)
        case .success(let payload):
            // Confirmation first — an import replaces everything the user has
            // arranged, and the panel has already told us which file it is.
            let header = LayoutBackup.summary(data)
            let alert = NSAlert()
            alert.messageText = "Confirm Import?"
            alert.informativeText = [
                "This will replace your current layout with the backup.",
                header.map { "Backup: \($0.appCount) app(s), \($0.pageCount) page(s), exported \($0.exportedAt)." },
            ].compactMap { $0 }.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            if store.adoptBackupPayload(payload) {
                report(title: "Import Success",
                       message: "The layout was replaced with the backup.")
            } else {
                report(title: "Import Failed",
                       message: "The backup does not contain a usable layout.")
            }
        }
    }

    private static func report(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
