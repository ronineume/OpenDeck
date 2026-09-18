import SwiftUI
import AppKit

/// Selectable file row in the uninstall confirmation list.
struct UninstallItem: Identifiable {
    let candidate: UninstallCandidate
    var isSelected: Bool
    var id: String { candidate.path }

    /// The default check state for a scan result.
    ///
    /// Only authoritative (bundle-identifier) matches are pre-checked. Every
    /// result used to be `isSelected: true` and the confirmation is a single
    /// click, so uninstalling "Code" moved `com.tencent.codebuddycn` and `Codex`
    /// to the Trash with it, and "Preview" took `MobileSMSPreview` along. A
    /// name-only hit is a guess: it stays listed for the user to opt into, but it
    /// does not start out selected.
    static func defaultSelection(for candidate: UninstallCandidate) -> Bool {
        candidate.matchKind == .identifier
    }
}

/// Backing state for the uninstall window.
final class UninstallViewModel: ObservableObject {
    let app: AppInfo
    @Published var items: [UninstallItem] = []
    @Published var isScanning = true
    @Published var message: String?

    init(app: AppInfo) {
        self.app = app
    }

    var selectedCount: Int { items.filter(\.isSelected).count }

    /// Entries attributed by display name alone: shown, but never pre-selected,
    /// because the match is a substring guess that crosses vendors.
    var nameOnlyCount: Int { items.filter { $0.candidate.matchKind == .nameOnly }.count }

    var selectedSize: Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.candidate.size }
    }

    func scan() {
        isScanning = true
        let app = self.app
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AppUninstaller.relatedFiles(for: app)
            DispatchQueue.main.async {
                self.items = found.map {
                    UninstallItem(candidate: $0, isSelected: UninstallItem.defaultSelection(for: $0))
                }
                self.isScanning = false
            }
        }
    }

    func toggleAll(_ selected: Bool) {
        for index in items.indices { items[index].isSelected = selected }
    }

    func performUninstall(completion: @escaping (Bool) -> Void) {
        let chosen = items.filter(\.isSelected).map(\.candidate)
        let app = self.app

        // Sizing a large bundle (Xcode and friends) walks tens of thousands of
        // files. On the main thread that froze the window for seconds with no
        // progress feedback; the scan already runs off the main thread, so this
        // now matches it. The rest stays on the main thread — the authorized
        // retry drives Finder through AppleScript.
        DispatchQueue.global(qos: .userInitiated).async {
            let appSize = AppUninstaller.size(of: app.path, isDirectory: true)
            DispatchQueue.main.async {
                self.finishUninstall(app: app, chosen: chosen, appSize: appSize, completion: completion)
            }
        }
    }

    private func finishUninstall(
        app: AppInfo,
        chosen: [UninstallCandidate],
        appSize: Int64,
        completion: @escaping (Bool) -> Void
    ) {
        // Always include the app bundle itself first. It is an identifier match by
        // definition — it *is* the app.
        let appCandidate = UninstallCandidate(
            path: app.path,
            isDirectory: true,
            size: appSize,
            matchKind: .identifier
        )
        var targets = [appCandidate]
        targets.append(contentsOf: chosen.filter { $0.path != app.path })

        let failures = AppUninstaller.trash(targets)
        if failures.isEmpty {
            message = "Moved \(targets.count) item(s) to the Trash."
            completion(true)
            return
        }

        // Usually /Applications ownership: retry with administrator rights.
        let retry = targets.filter { failures.contains($0.path) }
        if AppUninstaller.trashWithAuthorization(retry) {
            message = "Moved \(targets.count) item(s) to the Trash (with authorization)."
            completion(true)
        } else {
            // Name what is still there, not what was attempted: the retry only
            // ever covered the failures, so quoting `targets.count` overstated
            // what had been done.
            message = "Could not remove \(failures.count) of \(targets.count) item(s). Full Disk Access may be required."
            completion(false)
        }
    }
}

struct UninstallView: View {
    @ObservedObject var vm: UninstallViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: vm.app.icon)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall \(vm.app.name)")
                        .font(.system(size: 15, weight: .semibold))
                    Text("The app and its related files are moved to the Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if vm.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning for related files…").font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                HStack {
                    Text("\(vm.items.count) related item(s) · \(AppUninstaller.formattedSize(vm.selectedSize)) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Select All") { vm.toggleAll(true) }
                        .buttonStyle(.link)
                    Button("Select None") { vm.toggleAll(false) }
                        .buttonStyle(.link)
                }

                // A name-only match is a substring guess: "Photos" also matches
                // "Photoshop". Say so instead of letting them be selected unseen.
                if vm.nameOnlyCount > 0 {
                    Text("\(vm.nameOnlyCount) item(s) matched by the app's name alone — they may belong to a different app, so they are not selected. Review them before choosing.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach($vm.items) { $item in
                            HStack(spacing: 8) {
                                Toggle("", isOn: $item.isSelected)
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.candidate.displayName)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(item.candidate.displayPath)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                if item.candidate.matchKind == .nameOnly {
                                    Text("name only")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.orange)
                                        .help("This entry only contains the app's name, so it may belong to a different app.")
                                }
                                Spacer()
                                Text(AppUninstaller.formattedSize(item.candidate.size))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }

            if let message = vm.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") {
                    vm.performUninstall { _ in onClose() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.isScanning)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }
}
