import AppKit
import SwiftUI

/// The level the Reorganize sheet sits at.
///
/// The same value the uninstall panel uses (report 51): LaunchOS's sheet
/// presenters end with `mov w8, #0x3e8` + `mov w8, #0x1` →
/// `NSWindow.Level.+` → `setLevel:` — i.e. `.screenSaver + 1`, a fixed level
/// above everything. The sheet is opened from the deck's own menu, so the
/// deck is still on screen behind it at 499; a `.normal` window would be
/// invisible behind the full-screen deck.
enum ReorganizePanelLevel {
    static let panel: NSWindow.Level = .screenSaver + 1
}

/// Pure validation for the sheet, so the rules are assertable headlessly.
enum ReorganizeRules {
    /// LaunchOS's own copy: with `Selected Pages` chosen and nothing
    /// selected, the apply button stays disabled and the hint explains why
    /// (`Select at least one page`, `localization.json` en/zh-Hans).
    static func canApply(options: OrganizeOptions, pageCount: Int) -> Bool {
        guard pageCount > 0 else { return false }
        if options.pageScope == .selectedPages, options.scope(pageCount: pageCount).isEmpty {
            return false
        }
        return true
    }

    /// The hint shown under the page picker, or nil when there is nothing to
    /// say. Kept as a function of the options so the wording cannot drift
    /// from the rule.
    static func hint(options: OrganizeOptions, pageCount: Int) -> String? {
        if options.pageScope == .selectedPages, options.scope(pageCount: pageCount).isEmpty {
            return "Select at least one page"
        }
        return nil
    }
}

/// Sheet state: the rule set plus everything the view needs to render it.
@MainActor
final class ReorganizeViewModel: ObservableObject {
    @Published var options: OrganizeOptions
    /// Live page count, so the selection can be clamped and validated.
    @Published var pageCount: Int
    /// Called with the final options when the user confirms.
    var onApply: ((OrganizeOptions) -> Void)?

    init(options: OrganizeOptions, pageCount: Int) {
        self.options = options
        self.pageCount = pageCount
    }

    var canApply: Bool { ReorganizeRules.canApply(options: options, pageCount: pageCount) }
    var hint: String? { ReorganizeRules.hint(options: options, pageCount: pageCount) }

    /// The sort keys the sheet offers. Custom is excluded on purpose: it is
    /// the user's own arrangement, and "reorganizing" it would destroy
    /// exactly what it protects.
    var sortMethods: [SortKey] { [.name, .dateAdded, .lastUsed] }
}

/// The Reorganize Layout sheet (LaunchOS Pro feature, report 53).
///
/// Mirrors the reversed sheet: page scope (with per-page checkboxes when
/// `Selected Pages`), `Reorganize Across Pages`, `Apple App Placement`,
/// `Folder Placement`, `Sort By` + direction, `Also Sort Apps in Folders`
/// (with the ungroup footnote when on) and `Ungroup All Folders`.
struct ReorganizeSheetView: View {
    @ObservedObject var vm: ReorganizeViewModel
    /// Called when the sheet should dismiss itself (cancel / applied).
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reorganize Layout")
                .font(.headline)

            Picker("Pages", selection: $vm.options.pageScope) {
                ForEach(OrganizePageScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            if vm.options.pageScope == .selectedPages {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0 ..< vm.pageCount, id: \.self) { page in
                        Toggle(isOn: Binding(
                            get: { vm.options.selectedPages.contains(page) },
                            set: { on in
                                if on { vm.options.selectedPages.insert(page) }
                                else { vm.options.selectedPages.remove(page) }
                            }
                        )) {
                            Text("Page \(page + 1)")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }

            if let hint = vm.hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Toggle("Reorganize Across Pages", isOn: $vm.options.acrossPages)

            Picker("Apple App Placement", selection: $vm.options.appleAppPlacement) {
                ForEach(AppleAppPlacement.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            Picker("Folder Placement", selection: $vm.options.folderPlacement) {
                ForEach(FolderPlacement.allCases) { p in
                    Text(p.label).tag(p)
                }
            }

            HStack {
                Picker("Sort By", selection: $vm.options.sortMethod) {
                    ForEach(vm.sortMethods) { key in
                        Text(key.label).tag(key)
                    }
                }
                Picker("Order", selection: $vm.options.sortDirection) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                .frame(width: 150)
            }

            Toggle("Also Sort Apps in Folders", isOn: $vm.options.alsoSortInFolders)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Ungroup All Folders", isOn: $vm.options.ungroupAllFolders)
                if vm.options.ungroupAllFolders {
                    Text("Ungrouped apps are added to the end of their original page. "
                         + "If the page is full, they continue onto the next page and "
                         + "may shift apps on later pages.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Reorganize layout based on selected rules") {
                    vm.onApply?(vm.options)
                    onDismiss()
                }
                .disabled(!vm.canApply)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Hosts the Reorganize sheet. Same contract as the settings and uninstall
/// panels (reports 47/51): raised above the deck, never taking the deck down,
/// and the deck gets the keyboard back when the sheet closes.
@MainActor
final class ReorganizeWindowController: NSObject {
    private var window: NSWindow?

    /// Runs when the sheet is closed by the user (the red button).
    var onClose: (() -> Void)?

    func show(options: OrganizeOptions, pageCount: Int,
              above level: NSWindow.Level,
              onApply: @escaping (OrganizeOptions) -> Void) {
        let vm = ReorganizeViewModel(options: options, pageCount: pageCount)
        vm.onApply = onApply

        if let window {
            window.level = level
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = ReorganizeSheetView(vm: vm, onDismiss: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(x: 0, y: 0, width: 460, height: 560)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Reorganize Layout"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.level = level
        window.delegate = self
        window.center()

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

extension ReorganizeWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            window = nil
            onClose?()
        }
    }
}
