import AppKit
import ApplicationServices

/// TCC permission checks and requests.
enum Permissions {
    /// Accessibility (needed for event taps: the Launchpad key on Apple keyboards).
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Full Disk Access (needed to remove an app's files under ~/Library/Containers).
    ///
    /// macOS exposes no API for this, so probe a path that only FDA can read.
    static var hasFullDiskAccess: Bool {
        let probe = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        return FileManager.default.isReadableFile(atPath: probe)
    }

    static func openFullDiskAccessSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAccessibilitySettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }
}
