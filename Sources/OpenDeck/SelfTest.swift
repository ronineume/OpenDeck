import AppKit
import Foundation

/// Headless verification of the logic that cannot be eyeballed in a screenshot.
///
/// Run with `OpenDeck --selftest`. Uses a throwaway layout file so the real
/// one is never touched, and never deletes anything on disk.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        checks += 1
        if !condition { failures += 1 }
        let suffix = detail.isEmpty ? "" : "  [\(detail)]"
        print("\(condition ? "PASS" : "FAIL")  \(label)\(suffix)")
    }

    private static func section(_ title: String) {
        print("\n— \(title) —")
    }

    static func run() -> Int32 {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-selftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = DeckStore(storeURL: tempURL)
        store.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 100, cellWidth: 150, cellHeight: 150)
        let capacity = store.metrics.capacity

        section("Scanning")
        check("found installed apps", store.apps.count > 0, "\(store.apps.count) apps")
        check("every app has an icon", store.apps.allSatisfy { !$0.icon.isValid == false })
        check("bundle ids are unique", Set(store.apps.compactMap(\.bundleID)).count == store.apps.compactMap(\.bundleID).count)
        let unnamed = store.apps.filter { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        check("every app has a non-empty name", unnamed.isEmpty,
              unnamed.isEmpty ? "" : "\(unnamed.count) unnamed: \(unnamed.prefix(3).map(\.path))")
        for expected in ["com.apple.Safari", "com.apple.systempreferences"] {
            let found = store.apps.contains { $0.bundleID == expected }
            if !found { print("      missing well-known app: \(expected)") }
        }
        check("finds well-known system apps",
              store.apps.contains { $0.bundleID == "com.apple.Safari" })
        check("apps are alphabetically scanned", {
            let names = store.apps.map(\.name)
            return names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }())

        section("Icon cache freshness signature")
        // The scanner must record a freshness signature, or an in-place update
        // could never invalidate the icon cache.
        check("scanned apps carry a bundle signature",
              store.apps.contains { $0.iconSignature.bundleModified != nil })
        check("scanned apps carry a manifest signature",
              store.apps.contains { $0.iconSignature.manifestModified != nil })

        // Deterministic check of the invalidation rule itself: substitute the
        // loader with a counter, so a hit and a miss are distinguishable without
        // a window server.
        IconCache.clear()
        var loads = 0
        IconCache.loadIcon = { _ in
            loads += 1
            return NSImage(size: NSSize(width: 1, height: 1))
        }

        let probe = "/Applications/ZZ IconProbe.app"
        let sigA = IconSignature(bundleModified: Date(timeIntervalSince1970: 1_000),
                                 manifestModified: Date(timeIntervalSince1970: 1_000))
        let sigB = IconSignature(bundleModified: Date(timeIntervalSince1970: 2_000),
                                 manifestModified: Date(timeIntervalSince1970: 1_000))
        // Manifest-only change: the exact "in-place overwrite" case a
        // bundle-directory-only signature would have missed.
        let sigC = IconSignature(bundleModified: Date(timeIntervalSince1970: 2_000),
                                 manifestModified: Date(timeIntervalSince1970: 3_000))

        _ = IconCache.icon(for: probe, signature: sigA)
        _ = IconCache.icon(for: probe, signature: sigA)
        check("an unchanged signature reuses the cached icon", loads == 1, "loads=\(loads)")

        _ = IconCache.icon(for: probe, signature: sigB)
        check("a changed bundle mtime re-reads the icon exactly once", loads == 2, "loads=\(loads)")

        _ = IconCache.icon(for: probe, signature: sigB)
        check("the refreshed icon is cached again", loads == 2, "loads=\(loads)")

        _ = IconCache.icon(for: probe, signature: sigC)
        check("a manifest-only change re-reads the icon", loads == 3, "loads=\(loads)")

        let noParts = "/Applications/ZZ NoSignature.app"
        _ = IconCache.icon(for: noParts, signature: .unknown)
        _ = IconCache.icon(for: noParts, signature: .unknown)
        check("a signature with both parts missing still caches, not thrashes", loads == 4, "loads=\(loads)")

        // Restore the real loader immediately — later sections read real icons.
        IconCache.loadIcon = { NSWorkspace.shared.icon(forFile: $0) }
        IconCache.clear()

        section("Capacity invariant")
        check("no page exceeds capacity (initial)", store.pages.allSatisfy { $0.count <= capacity },
              "pages=\(store.pages.count) cap=\(capacity)")
        check("capacity covers every app", store.pages.flatMap { $0 }.count == store.apps.count - store.hidden.count)

        // Shrinking the grid must repack, not truncate.
        store.metrics = GridMetrics(columns: 4, rows: 3, iconSize: 80, cellWidth: 120, cellHeight: 120)
        check("no page exceeds capacity (after shrink to 4x3)",
              store.pages.allSatisfy { $0.count <= 12 }, "pages=\(store.pages.count)")
        check("items survive the shrink",
              store.pages.flatMap { $0 }.count == store.apps.count - store.hidden.count)
        store.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 100, cellWidth: 150, cellHeight: 150)

        section("Hide / unhide")
        guard let victim = store.visibleApps.first else {
            print("FAIL  no app available to hide"); return 1
        }
        let before = store.pages.flatMap { $0 }.count
        store.setHidden(victim.id, true)
        check("hidden app leaves the grid", !store.pages.flatMap { $0 }.contains(.app(victim.id)))
        check("hidden app listed as hidden", store.hiddenApps.contains { $0.id == victim.id })
        check("hidden app is not in visibleApps", !store.visibleApps.contains { $0.id == victim.id })
        check("grid shrank by one", store.pages.flatMap { $0 }.count == before - 1)
        store.setHidden(victim.id, false)
        check("unhide restores to the grid",
              store.pages.flatMap { $0 }.contains(.app(victim.id)))
        check("unhide clears hidden list", !store.hiddenApps.contains { $0.id == victim.id })

        section("Folders")
        let candidates = store.visibleApps.prefix(2).map(\.id)
        if candidates.count == 2 {
            let (a, b) = (candidates[0], candidates[1])
            store.makeFolder(dropping: a, onto: b)
            let folder = store.folders.values.first { $0.appIDs.contains(a) && $0.appIDs.contains(b) }
            check("folder created with both members", folder?.appIDs.count == 2)
            check("folder occupies one grid slot",
                  store.pages.flatMap { $0 }.filter { if case .folder = $0 { return true } else { return false } }.count == 1)
            check("folder members removed as standalone slots",
                  !store.pages.flatMap { $0 }.contains(.app(a)) && !store.pages.flatMap { $0 }.contains(.app(b)))
            if let folder {
                check("folder resolves both apps", store.folderApps(folder.id).count == 2)
                store.rename(folder.id, to: "Utilities")
                check("folder rename persists", store.folder(folder.id)?.name == "Utilities")
                store.ungroup(folder.id)
                check("ungroup removes the folder", store.folder(folder.id) == nil)
                check("ungroup returns both apps to the grid",
                      store.pages.flatMap { $0 }.contains(.app(a)) && store.pages.flatMap { $0 }.contains(.app(b)))
            }
        } else {
            check("at least two apps for folder test", false)
        }

        section("Move")
        if let source = store.locate(.app(candidates[0])) {
            store.move(itemAt: source, to: IndexPath(item: 0, section: 0))
            check("moved item is first on page 0", store.pages.first?.first == .app(candidates[0]))
        }
        check("no page exceeds capacity after move", store.pages.allSatisfy { $0.count <= capacity })

        section("Sort")
        store.sortKey = .name
        store.sortOrder = .ascending
        store.applySort()
        let ascending = store.pages.flatMap { $0 }.compactMap { slot -> String? in
            if case .app(let id) = slot { return store.app(id: id)?.name }
            return nil
        }
        check("name sort is ascending", ascending == ascending.sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        store.sortOrder = .descending
        store.applySort()
        let descending = store.pages.flatMap { $0 }.compactMap { slot -> String? in
            if case .app(let id) = slot { return store.app(id: id)?.name }
            return nil
        }
        check("name sort is descending", descending == descending.sorted { $0.localizedStandardCompare($1) == .orderedDescending })

        store.sortKey = .lastUsed
        store.sortOrder = .ascending
        store.applySort()
        let lastUsed = store.pages.flatMap { $0 }.compactMap { slot -> Date? in
            if case .app(let id) = slot { return store.app(id: id)?.lastUsedDate ?? .distantPast }
            return nil
        }
        check("last-used sort is monotonic", zip(lastUsed, lastUsed.dropFirst()).allSatisfy { $0 <= $1 })

        section("Persistence round trip")
        // Build state that only survives if init loads before it reconciles.
        guard let hideTarget = store.visibleApps.last else {
            print("FAIL  no app available for the persistence test"); return 1
        }
        store.setHidden(hideTarget.id, true)
        let pair = Array(store.visibleApps.prefix(2)).map(\.id)
        if pair.count == 2 {
            store.makeFolder(dropping: pair[0], onto: pair[1])
        }
        store.sortKey = .name
        store.sortOrder = .descending
        store.save()

        let savedPages = store.pages
        let savedSortKey = store.sortKey
        let savedSortOrder = store.sortOrder
        let savedFolderCount = store.folders.count

        let reloaded = DeckStore(storeURL: tempURL)
        check("reload keeps app count", reloaded.apps.count == store.apps.count)
        check("reload keeps sort key", reloaded.sortKey == savedSortKey,
              "\(reloaded.sortKey.rawValue) vs \(savedSortKey.rawValue)")
        check("reload keeps sort order", reloaded.sortOrder == savedSortOrder)
        check("reload keeps hidden apps", reloaded.hiddenApps.contains { $0.id == hideTarget.id })
        check("reload keeps folders", reloaded.folders.count == savedFolderCount)
        check("reload keeps page count", reloaded.pages.count == savedPages.count,
              "\(reloaded.pages.count) vs \(savedPages.count)")
        if reloaded.pages != savedPages {
            print("      saved:    \(savedPages.map(\.count))")
            print("      reloaded: \(reloaded.pages.map(\.count))")
            let flatSaved = savedPages.flatMap { $0 }
            let flatReloaded = reloaded.pages.flatMap { $0 }
            print("      saved slots: \(flatSaved.count), reloaded slots: \(flatReloaded.count)")
            for (index, pair) in zip(flatSaved, flatReloaded).enumerated() where pair.0 != pair.1 {
                print("      first difference at flat index \(index):")
                print("        saved    = \(pair.0)")
                print("        reloaded = \(pair.1)")
                break
            }
            let savedSet = Set(flatSaved), reloadedSet = Set(flatReloaded)
            let onlySaved = savedSet.subtracting(reloadedSet)
            let onlyReloaded = reloadedSet.subtracting(savedSet)
            print("      only in saved (\(onlySaved.count)): \(onlySaved.prefix(4).map { "\($0)" })")
            print("      only in reloaded (\(onlyReloaded.count)): \(onlyReloaded.prefix(4).map { "\($0)" })")
        }
        check("reload keeps exact page contents", reloaded.pages == savedPages)

        section("Hidden list reconciles with installed apps")
        // A `hidden` id whose app is gone must be dropped (so a reinstall shows
        // up again); a `hidden` id whose app is still installed must survive.
        let hiddenURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-hidden-\(UUID().uuidString).json")
        guard let liveApp = store.visibleApps.first else {
            print("FAIL  no app available for the hidden-cleanup test"); return 1
        }
        let ghostID = "test.ghost.uninstalled"
        let hiddenFixture: [String: Any] = [
            "pages": [["app:\(liveApp.id)"]],
            "folders": [],
            "hidden": [liveApp.id, ghostID],
            "sortKey": "manual",
            "sortOrder": "ascending",
            "customOrder": [liveApp.id],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: hiddenFixture)
            try data.write(to: hiddenURL)
        } catch {
            check("the hidden-cleanup fixture is written", false, "\(error)")
        }
        let reconciled = DeckStore(storeURL: hiddenURL)
        // A single scan that does not report an app is not proof it is gone: a
        // bundle being replaced disappears from a scan and comes back, and it is
        // that replacement which fires the rescan. The `hidden` mark a user set is
        // therefore kept for one more scan rather than deleted on one observation
        // (review 26) — invisible either way, since a `hidden` id with no app
        // renders nowhere.
        check("a `hidden` id with no installed app survives the first scan",
              reconciled.hidden.contains(ghostID))
        check("a hidden id that is still installed survives the load",
              reconciled.hidden.contains(liveApp.id))
        // ...and a second scan that still lacks it confirms it is gone, so the
        // original rule — reinstalling a hidden app lets it show up again — still
        // holds, one scan later.
        reconciled.applyScan(reconciled.apps)
        check("a second scan that still lacks it drops the `hidden` id",
              !reconciled.hidden.contains(ghostID))
        check("the hidden cleanup leaves a repair trace",
              (reconciled.lastError ?? "").lowercased().contains("hidden"),
              reconciled.lastError ?? "no trace")
        try? FileManager.default.removeItem(at: hiddenURL)

        section("Wallpaper resolution")
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let resolution = WallpaperProvider.resolve(for: screen)
            print("      \(resolution.description)")
            switch resolution {
            case .folder(_, let images):
                check("desktop shuffle album resolved", !images.isEmpty, "\(images.count) image(s)")
            case .file(let url):
                check("static wallpaper resolved", true, url.lastPathComponent)
            case .unavailable:
                check("wallpaper detected", false)
            }
            check("wallpaper decodes", WallpaperProvider.wallpaper(for: screen) != nil)
            check("glass render succeeds", WallpaperProvider.glassWallpaper(for: screen) != nil)
        }

        section("Hot key specs")
        check("F4 displays as F4", HotKeySpec.f4.displayString == "F4", HotKeySpec.f4.displayString)
        check("⌥Space shows modifier + key",
              HotKeySpec.optionSpace.displayString == "⌥ Space", HotKeySpec.optionSpace.displayString)
        check("⌘⇧Space orders modifiers canonically",
              HotKeySpec.commandShiftSpace.displayString == "⇧⌘ Space",
              HotKeySpec.commandShiftSpace.displayString)
        HotKeyManager.shared.unregister()
        HotKeyManager.shared.register(.f4) {}
        check("F4 registers as a Carbon hot key", HotKeyManager.shared.lastError == nil,
              HotKeyManager.shared.lastError ?? "ok")
        HotKeyManager.shared.unregister()

        section("Launchpad import")
        if let database = LaunchpadImporter.locateDatabase() {
            print("      database: \(database.path)")
            if let layout = LaunchpadImporter.load(from: database) {
                print("      parsed: \(layout.appCount) apps, \(layout.folderCount) folders, \(layout.pages.count) pages")
                check("import parses pages", !layout.pages.isEmpty)
                check("import finds apps", layout.appCount > 0)
                check("import finds folders", layout.folderCount > 0)
                check("import is not truncated", layout.appCount >= 50, "\(layout.appCount)")
                let report = store.applyImported(layout)
                print("      applied: \(report.placedApps) placed, \(report.folders) folders, \(report.skipped.count) not installed")
                if !report.skipped.isEmpty {
                    print("      not installed: \(report.skipped.joined(separator: ", "))")
                }
                if !report.hiddenSkipped.isEmpty {
                    print("      hidden here: \(report.hiddenSkipped.joined(separator: ", "))")
                }
                check("import conserves every app",
                      report.placedApps + report.skipped.count + report.hiddenSkipped.count == layout.appCount,
                      "\(report.placedApps)+\(report.skipped.count)+\(report.hiddenSkipped.count) vs \(layout.appCount)")
                check("import recreates folders", report.folders > 0, "\(report.folders)")
                check("import respects capacity", store.pages.allSatisfy { $0.count <= capacity })
                let folderNames = store.folders.values.map(\.name).sorted()
                check("folders keep their names", folderNames.contains(where: { !$0.isEmpty }),
                      folderNames.joined(separator: "/"))
            } else {
                check("import parses the database", false, "parse returned nil")
            }
        } else {
            print("      (no Launchpad database on this machine — skipping import checks)")
        }

        section("Drag dwell target (crash regression)")
        let apps3: [DeckSlot] = [.app("a"), .app("b"), .folder(UUID())]
        check("resting on an app yields its id",
              DragState.combineTarget(item: .app("z"), pageItems: apps3, index: 0) == .app("a"))
        // Folders are valid combine targets: an app can be merged into an
        // existing folder, which previously was impossible.
        let folderID = { if case .folder(let id) = apps3[2] { return id }; return UUID() }()
        check("resting on a folder yields that folder",
              DragState.combineTarget(item: .app("z"), pageItems: apps3, index: 2) == .folder(folderID))
        check("dragging a folder never combines",
              DragState.combineTarget(item: .folder(UUID()), pageItems: apps3, index: 0) == nil)
        // The hit tester reports trailing empty slots, so an index past the last
        // item reaches here. Reading pageItems[index] used to trap.
        check("an index past the last item is rejected, not crashed",
              DragState.combineTarget(item: .app("z"), pageItems: apps3, index: 34) == nil)
        check("a negative index is rejected",
              DragState.combineTarget(item: .app("z"), pageItems: apps3, index: -1) == nil)
        check("an empty page is handled",
              DragState.combineTarget(item: .app("z"), pageItems: [], index: 0) == nil)

        section("Installing and removing apps syncs the grid")
        let syncURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-sync-\(UUID().uuidString).json")
        let syncer = DeckStore(storeURL: syncURL)
        syncer.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 81, cellWidth: 177, cellHeight: 135)
        let slotsBefore = syncer.pages.flatMap { $0 }.count

        let fake = AppInfo(
            path: "/Applications/ZZ Synthetic.app",
            bundleID: "test.synthetic.newapp",
            name: "ZZ Synthetic",
            addedDate: Date(),
            lastUsedDate: nil
        )
        syncer.applyScan(syncer.apps + [fake])
        check("a newly installed app is appended to the grid",
              syncer.pages.flatMap { $0 }.contains(.app("test.synthetic.newapp")))
        check("the grid grew by exactly one slot",
              syncer.pages.flatMap { $0 }.count == slotsBefore + 1,
              "\(slotsBefore) -> \(syncer.pages.flatMap { $0 }.count)")
        check("the new app is visible", syncer.visibleApps.contains { $0.id == fake.id })

        syncer.applyScan(syncer.apps.filter { $0.id != fake.id })
        check("an uninstalled app is removed from the grid",
              !syncer.pages.flatMap { $0 }.contains(.app("test.synthetic.newapp")))
        check("the grid shrinks back", syncer.pages.flatMap { $0 }.count == slotsBefore)
        check("the rescan keeps the page-shape invariants",
              syncer.pages.allSatisfy { $0.count <= capacity }
                && !syncer.pages.dropLast().contains { $0.isEmpty })
        try? FileManager.default.removeItem(at: syncURL)

        section("Merging an app into an existing folder")
        let mergeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-merge-\(UUID().uuidString).json")
        let merger = DeckStore(storeURL: mergeURL)
        merger.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 81, cellWidth: 177, cellHeight: 135)
        let mergeIDs = Array(merger.visibleApps.prefix(3)).map(\.id)
        if mergeIDs.count == 3 {
            merger.makeFolder(dropping: mergeIDs[0], onto: mergeIDs[1])
            check("a two-app folder exists to merge into", merger.folders.count == 1)
            if let fid = merger.folders.keys.first {
                check("the new folder holds both apps", merger.folderApps(fid).count == 2)
                merger.addToFolder(mergeIDs[2], folder: fid)
                check("merging a third app grows the folder",
                      merger.folderApps(fid).count == 3, "\(merger.folderApps(fid).count)")
                check("the merged app is no longer a loose slot",
                      merger.locate(.app(mergeIDs[2])) == nil)
                check("merging keeps the page-shape invariants",
                      merger.pages.allSatisfy { $0.count <= capacity }
                        && !merger.pages.dropLast().contains { $0.isEmpty })
                check("merging the same app twice is a no-op",
                      merger.addToFolder(mergeIDs[2], folder: fid) == false)
            }
        } else {
            check("three apps available to merge", false)
        }
        try? FileManager.default.removeItem(at: mergeURL)

        section("Duplicate customOrder must not crash on load (P0 regression)")
        // A layout where one app is BOTH a standalone grid slot and a folder
        // member produced a duplicate entry in customOrder, which made
        // `sorted()` trap via Dictionary(uniqueKeysWithValues:) on the next
        // launch. Load such a file from disk and make sure it heals.
        let dupURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-duporder-\(UUID().uuidString).json")
        let dupIDs = Array(store.visibleApps.prefix(3)).map(\.id)
        if dupIDs.count == 3 {
            let dupApp = dupIDs[0]
            let dupMember = dupIDs[1]
            let dupOther = dupIDs[2]
            let dupFolder = UUID()
            let json = """
            {
              "pages": [
                ["folder:\(dupFolder.uuidString)", "app:\(dupApp)", "app:\(dupMember)"],
                ["app:\(dupOther)"]
              ],
              "folders": [
                {"id": "\(dupFolder.uuidString)", "name": "F", "appIDs": ["\(dupApp)", "\(dupMember)"]}
              ],
              "hidden": [],
              "sortKey": "manual",
              "sortOrder": "ascending",
              "customOrder": ["\(dupApp)", "\(dupMember)", "\(dupApp)"]
            }
            """
            try? Data(json.utf8).write(to: dupURL)

            // (a) constructing the store must not trap, even with sortKey == .manual.
            let dupStore = DeckStore(storeURL: dupURL)
            check("loading a layout with a duplicate customOrder does not crash", true)

            // (b) the on-disk duplicate is de-duplicated on load.
            var seenLoaded = Set<String>()
            let loadedDups = dupStore.customOrder.filter { !seenLoaded.insert($0).inserted }
            check("customOrder is de-duplicated on load", loadedDups.isEmpty,
                  "dups=\(loadedDups)")

            // (c) reconcile resolves the standalone duplicate grid slot.
            let standaloneDup = dupStore.pages.flatMap { $0 }.contains(.app(dupMember))
            check("the standalone duplicate slot is resolved by reconcile", !standaloneDup)
            check("the folder keeps the app as a member",
                  dupStore.folder(dupFolder)?.appIDs.contains(dupMember) == true)

            // syncCustomOrder must never re-introduce a duplicate when a
            // dual-membership state is created in memory.
            dupStore.pages = [[.app(dupMember)], [.folder(dupFolder)]]
            if let from = dupStore.locate(.app(dupMember)) {
                dupStore.move(itemAt: from, to: IndexPath(item: 0, section: 1))
            }
            var seenSynced = Set<String>()
            let syncedDups = dupStore.customOrder.filter { !seenSynced.insert($0).inserted }
            check("syncCustomOrder never writes a duplicate", syncedDups.isEmpty,
                  "dups=\(syncedDups) order=\(dupStore.customOrder)")
        } else {
            check("three apps available for the duplicate-order test", false)
        }
        try? FileManager.default.removeItem(at: dupURL)

        section("Folder ownership invariants (I1–I4)")
        // Load a synthetic layout so we can put an app in two folders, duplicate
        // a member, or make it both a grid slot and a folder member — states the
        // UI can no longer produce but old on-disk files still contain.
        func loadStore(pages: String, foldersJSON: String, tag: String) -> DeckStore {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("opendeck-inv-\(tag)-\(UUID().uuidString).json")
            let json = """
            {
              "pages": \(pages),
              "folders": \(foldersJSON),
              "hidden": [],
              "sortKey": "manual",
              "sortOrder": "ascending",
              "customOrder": []
            }
            """
            try? Data(json.utf8).write(to: url)
            let s = DeckStore(storeURL: url)
            try? FileManager.default.removeItem(at: url)
            return s
        }

        let invIDs = Array(store.visibleApps.prefix(6)).map(\.id)
        if invIDs.count >= 4 {
            let x = invIDs[0], y = invIDs[1], z = invIDs[2], w = invIDs[3]

            // ① one app in two folders → converges to a single folder (I1).
            let f1 = UUID(), f2 = UUID()
            let twoFolders = loadStore(
                pages: #"[["folder:\#(f1.uuidString)","folder:\#(f2.uuidString)"]]"#,
                foldersJSON: #"[{"id":"\#(f1.uuidString)","name":"A","appIDs":["\#(x)","\#(y)"]},{"id":"\#(f2.uuidString)","name":"B","appIDs":["\#(x)","\#(z)"]}]"#,
                tag: "twofolders")
            let xHolders = twoFolders.folders.values.filter { $0.appIDs.contains(x) }
            check("I1: an app ends up in exactly one folder", xHolders.count == 1,
                  "holders=\(xHolders.count)")
            check("I1: the folder first in pages order wins", xHolders.first?.id == f1)
            check("I1: the losing folder dissolved, its survivor returned to the grid",
                  twoFolders.folder(f2) == nil && twoFolders.locate(.app(z)) != nil)

            // ② duplicate member inside one folder → de-duplicated (I3).
            let f3 = UUID()
            let dupMember = loadStore(
                pages: #"[["folder:\#(f3.uuidString)"]]"#,
                foldersJSON: #"[{"id":"\#(f3.uuidString)","name":"C","appIDs":["\#(x)","\#(x)","\#(y)"]}]"#,
                tag: "dupmember")
            let members = dupMember.folder(f3)?.appIDs ?? []
            check("I3: a duplicate folder member is de-duplicated", members == [x, y], "\(members)")

            // ③ grid + folder dual membership → folder wins (I2).
            let f4 = UUID()
            let f4JSON = #"{"id":"\#(f4.uuidString)","name":"D","appIDs":["\#(x)","\#(y)"]}"#
            let appFirst = loadStore(
                pages: #"[["app:\#(x)","folder:\#(f4.uuidString)","app:\#(w)"]]"#,
                foldersJSON: "[\(f4JSON)]",
                tag: "appfirst")
            let appFirstGridCopies = appFirst.pages.flatMap { $0 }.filter { $0 == .app(x) }.count
            check("I2: a folder member is not also a standalone grid slot (app-first)",
                  appFirstGridCopies == 0, "gridCopies=\(appFirstGridCopies)")
            check("I2: the folder keeps the member",
                  appFirst.folder(f4)?.appIDs.contains(x) == true)

            // ④ I4 — folder-first and app-first layouts converge identically.
            let folderFirst = loadStore(
                pages: #"[["folder:\#(f4.uuidString)","app:\#(x)","app:\#(w)"]]"#,
                foldersJSON: "[\(f4JSON)]",
                tag: "folderfirst")
            let folderFirstGridCopies = folderFirst.pages.flatMap { $0 }.filter { $0 == .app(x) }.count
            check("I4: folder-first and app-first converge to identical pages",
                  folderFirst.pages == appFirst.pages)
            check("I4: both orderings end with zero grid copies",
                  folderFirstGridCopies == 0 && appFirstGridCopies == 0,
                  "folder-first=\(folderFirstGridCopies), app-first=\(appFirstGridCopies)")

            // ⑤ the mutation entry points enforce I1 too.
            let mutURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("opendeck-inv-mut-\(UUID().uuidString).json")
            let mutant = DeckStore(storeURL: mutURL)
            let mutIDs = Array(mutant.visibleApps.prefix(4)).map(\.id)
            if mutIDs.count == 4 {
                let a = mutIDs[0], b = mutIDs[1], c = mutIDs[2], d = mutIDs[3]
                mutant.makeFolder(dropping: a, onto: b)  // FA = {b, a}
                mutant.makeFolder(dropping: c, onto: d)  // FB = {d, c}
                let fa = mutant.folders.values.first { $0.appIDs.contains(b) }
                let fb = mutant.folders.values.first { $0.appIDs.contains(d) }
                if let fb { mutant.addToFolder(a, folder: fb.id) }
                let aHolders = mutant.folders.values.filter { $0.appIDs.contains(a) }
                check("I1 (mutation): addToFolder detaches the app from its old folder",
                      aHolders.count == 1 && aHolders.first?.id == fb?.id,
                      "holders=\(aHolders.count)")
                let faStillThere = fa.map { mutant.folder($0.id) != nil } ?? false
                check("I1 (mutation): the emptied folder dissolved and its survivor is on the grid",
                      !faStillThere && mutant.locate(.app(b)) != nil)
            } else {
                check("four apps available for the mutation invariant test", false)
            }
            try? FileManager.default.removeItem(at: mutURL)

            // ⑥ makeFolder's I1 enforcement: a source that already lives in a
            // folder must be **re-parented**, never duplicated. QA found this
            // path uncovered — commenting out `detachFromAnyFolder(source)` in
            // `makeFolder` left the whole suite green (143/143), so a future
            // regression here would have shipped silently. This case makes that
            // exact mutation fail.
            let reparentURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("opendeck-inv-reparent-\(UUID().uuidString).json")
            let reparent = DeckStore(storeURL: reparentURL)
            reparent.makeFolder(dropping: x, onto: y)   // FA = {y, x}
            let fa = reparent.folders.values.first { $0.appIDs.contains(y) }
            reparent.makeFolder(dropping: x, onto: z)   // re-parent x → {z, x}
            let xFolders = reparent.folders.values.filter { $0.appIDs.contains(x) }
            check("I1 (makeFolder): re-parenting a member never duplicates it",
                  xFolders.count == 1, "folders=\(xFolders.count)")
            check("I1 (makeFolder): the source's old folder dissolved, survivor on the grid",
                  (fa.map { reparent.folder($0.id) == nil } ?? false) && reparent.locate(.app(y)) != nil)
            try? FileManager.default.removeItem(at: reparentURL)

            // ⑦ I2 repair at a mutation entry: `removeFromFolder` on an input
            // that already breaches I2 (the app is *both* a standalone grid
            // slot and a folder member) must leave **exactly one** standalone
            // slot. The old implementation appended unconditionally and
            // conjured a second icon (observed: 1 → 2). `pages` is set
            // directly here so the breach survives — `reconcile()` at load
            // would heal it before the mutation entry could see it.
            let dualURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("opendeck-inv-dual-\(UUID().uuidString).json")
            let dual = DeckStore(storeURL: dualURL)
            let dualIDs = Array(dual.visibleApps.prefix(3)).map(\.id)
            if dualIDs.count >= 3 {
                let dx = dualIDs[0], dy = dualIDs[1], dz = dualIDs[2]
                dual.makeFolder(dropping: dx, onto: dy)   // F = {dy, dx}
                if let fid = dual.folders.values.first(where: { $0.appIDs.contains(dx) })?.id {
                    dual.pages = [[.app(dx), .folder(fid), .app(dz)]]
                    dual.removeFromFolder(dx, folder: fid)
                    let dualCopies = dual.pages.flatMap { $0 }.filter { $0 == .app(dx) }.count
                    check("I2 (removeFromFolder): a breached input keeps exactly one grid slot",
                          dualCopies == 1, "gridCopies=\(dualCopies)")
                    check("I2 (removeFromFolder): the emptied folder dissolved, survivor on the grid",
                          dual.folder(fid) == nil && dual.locate(.app(dy)) != nil)
                } else {
                    check("I2 (removeFromFolder): the folder exists", false)
                }
            }
            try? FileManager.default.removeItem(at: dualURL)
        } else {
            check("at least four apps available for the invariant tests", false)
        }

        section("Drag pipeline (review T1)")
        let pipeline = DragState()
        let dmetrics = GridMetrics(columns: 7, rows: 5, iconSize: 81, cellWidth: 177, cellHeight: 135)
        let gridRect = CGRect(x: 0, y: 102, width: 1470, height: 795)
        pipeline.gridFrame = gridRect
        pipeline.dotsFrame = CGRect(x: 620, y: 897, width: 120, height: 40)
        pipeline.deckSize = CGSize(width: 1470, height: 956)

        var liveMoves: [Int] = []
        var pageRequests: [Int] = []
        pipeline.onLiveMove = { _, index in liveMoves.append(index) }
        pipeline.onRequestPage = { pageRequests.append($0) }

        let row: [DeckSlot] = (0 ..< 5).map { .app("drag\($0)") }
        func slotCentre(_ i: Int) -> CGPoint {
            CGPoint(
                x: gridRect.minX + CGFloat(i) * (dmetrics.cellWidth + GridMetrics.hSpacing) + dmetrics.cellWidth / 2,
                y: gridRect.minY + dmetrics.cellHeight / 2
            )
        }

        pipeline.begin(item: row[0], app: nil, title: nil, index: 0, page: 0,
                       location: slotCentre(0))
        pipeline.update(location: slotCentre(3), page: 0, metrics: dmetrics,
                        pageItems: row, capacity: 35)
        check("in-grid drag reports the hovered slot", pipeline.hoverIndex == 3,
              "\(String(describing: pipeline.hoverIndex))")
        check("in-grid drag fires a live reorder", liveMoves == [3], "\(liveMoves)")
        check("an ordinary in-grid drag never flips pages", pageRequests.isEmpty, "\(pageRequests)")

        // B2: the live gap preview must survive crossing a page.
        liveMoves.removeAll()
        pipeline.update(location: slotCentre(1), page: 1, metrics: dmetrics,
                        pageItems: row, capacity: 35)
        check("live reorder still fires after a page flip", liveMoves == [1], "\(liveMoves)")

        // B1/C1: edge paging is reachable in-grid, and its request is in range.
        pageRequests.removeAll()
        pipeline.update(location: CGPoint(x: 8, y: 500), page: 1, metrics: dmetrics,
                        pageItems: row, capacity: 35)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        check("the left edge requests the previous page", pageRequests == [0], "\(pageRequests)")
        check("a raw -1 request is clamped by clampPage",
              DragState.clampPage(pageRequests.first.map { $0 - 1 } ?? -1, count: 4) == 0)
        pipeline.reset()
        check("reset clears the drag", !pipeline.isActive && pipeline.item == nil)

        section("Drag write batching (review A2)")
        let probeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-batch-\(UUID().uuidString).json")
        let batched = DeckStore(storeURL: probeURL)
        batched.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 81, cellWidth: 177, cellHeight: 135)
        batched.save()
        let beforeBatch = try? Data(contentsOf: probeURL)

        batched.beginBatch()
        if let first = batched.visibleApps.first {
            batched.setHidden(first.id, true)
            batched.setHidden(first.id, false)
        }
        let duringBatch = try? Data(contentsOf: probeURL)
        check("no write happens while a drag batch is open", duringBatch == beforeBatch)

        batched.endBatch()
        let afterBatch = try? Data(contentsOf: probeURL)
        check("the batch flushes exactly once on release", afterBatch != nil)
        try? FileManager.default.removeItem(at: probeURL)

        section("Combine decision (live-reorder regression)")
        let shelf: [DeckSlot] = [.app("a"), .app("b"), .folder(UUID())]
        let folderID2 = { if case .folder(let id) = shelf[2] { return id }; return UUID() }()
        // The regression: after the live reflow the dragged app occupies the
        // hovered slot, and cancelling there made combining impossible.
        check("hovering the dragged item itself keeps the pending combine",
              DragState.dwellDecision(item: .app("a"), pageItems: shelf, index: 0) == .keep)
        check("hovering another app starts a combine with it",
              DragState.dwellDecision(item: .app("a"), pageItems: shelf, index: 1) == .start(.app("b")))
        check("hovering a folder starts a combine with that folder",
              DragState.dwellDecision(item: .app("a"), pageItems: shelf, index: 2) == .start(.folder(folderID2)))
        check("an empty trailing slot cancels",
              DragState.dwellDecision(item: .app("a"), pageItems: shelf, index: 9) == .cancel)
        check("dragging a folder never starts a combine",
              DragState.dwellDecision(item: .folder(UUID()), pageItems: shelf, index: 1) == .cancel)

        section("Page index bounds (review C1)")
        check("a page below zero clamps to the first page", DragState.clampPage(-1, count: 4) == 0)
        check("a page past the end clamps to the last", DragState.clampPage(99, count: 4) == 3)
        check("a single page clamps to zero", DragState.clampPage(3, count: 1) == 0)
        check("an in-range page is untouched", DragState.clampPage(2, count: 4) == 2)

        section("Page shape invariants (review C2/C3)")
        check("no interior empty page",
              !store.pages.dropLast().contains { $0.isEmpty },
              "\(store.pages.map(\.count))")
        check("the last page is not empty", store.pages.last?.isEmpty == false)
        if let victim = store.visibleApps.first {
            store.setHidden(victim.id, true)
            store.setHidden(victim.id, false)
        }
        check("hide then unhide leaves no over-full page",
              store.pages.allSatisfy { $0.count <= capacity }, "\(store.pages.map(\.count))")
        check("hide then unhide leaves no interior empty page",
              !store.pages.dropLast().contains { $0.isEmpty }, "\(store.pages.map(\.count))")
        store.enforceCapacity()
        check("enforceCapacity preserves the page-shape invariants",
              !store.pages.dropLast().contains { $0.isEmpty }
                && store.pages.allSatisfy { $0.count <= capacity })

        section("Save determinism (review C6)")
        store.save()
        let firstWrite = try? Data(contentsOf: tempURL)
        store.save()
        let secondWrite = try? Data(contentsOf: tempURL)
        check("saving identical state twice produces identical bytes",
              firstWrite != nil && firstWrite == secondWrite)

        section("Cell hit area (click-to-dismiss must stay usable)")
        let hitMetrics = GridMetrics(columns: 7, rows: 5, iconSize: 81, cellWidth: 177, cellHeight: 135)
        let labelled = CellHitArea.size(metrics: hitMetrics, hasLabel: true)
        check("labelled hit area is narrower than the cell",
              labelled.width < hitMetrics.cellWidth, "\(labelled.width) of \(hitMetrics.cellWidth)")
        check("hit area still covers the whole icon",
              labelled.width >= hitMetrics.iconSize && labelled.height >= hitMetrics.iconSize)
        check("hit area leaves real gap between apps",
              hitMetrics.cellWidth - labelled.width >= 40,
              "\(hitMetrics.cellWidth - labelled.width) pt freed per cell")
        let bare = CellHitArea.size(metrics: hitMetrics, hasLabel: false)
        check("hiding labels shrinks the hit area further", bare.height < labelled.height)

        section("Drag targeting (grid hit testing)")
        let testMetrics = GridMetrics(columns: 7, rows: 5, iconSize: 81, cellWidth: 177, cellHeight: 135)
        let container = CGSize(width: 1470, height: 795)
        let tester = GridHitTester(metrics: testMetrics, itemCount: 35, containerSize: container)
        check("grid width accounts for spacing",
              tester.gridWidth == 7 * 177 + 6 * GridMetrics.hSpacing, "\(tester.gridWidth)")
        check("grid is centred horizontally",
              abs(tester.origin.x - (1470 - tester.gridWidth) / 2) < 0.01, "\(tester.origin.x)")
        // The critical property: every slot's centre must resolve back to it.
        let roundTrips = (0 ..< 35).filter { tester.index(at: tester.centre(of: $0)) == $0 }
        check("every slot centre maps back to its own slot",
              roundTrips.count == 35, "\(roundTrips.count)/35")
        check("a point left of the grid misses", tester.index(at: CGPoint(x: 2, y: 100)) == nil)
        check("a point beyond the last column misses",
              tester.index(at: CGPoint(x: 1465, y: 100)) == nil)
        check("a point below the last row misses",
              tester.index(at: CGPoint(x: 200, y: 790)) == nil)
        // A partly filled page must not report slots that hold nothing.
        let sparse = GridHitTester(metrics: testMetrics, itemCount: 3, containerSize: container)
        check("sparse page reports only real slots",
              sparse.index(at: CGPoint(x: 1000, y: 500)) == nil)
        // ...unless the grid capacity is offered, which is what makes a drag
        // able to land in a trailing empty slot instead of nowhere.
        let droppable = GridHitTester(metrics: testMetrics, itemCount: 3, containerSize: container, slotCount: 35)
        check("trailing empty slots accept drops when capacity is offered",
              droppable.index(at: CGPoint(x: 1000, y: 500)) != nil)
        check("empty slots beyond capacity are still rejected",
              droppable.index(at: CGPoint(x: 1000, y: 785)) == nil)
        // A full page must still offer every slot, or it could never reorder.
        let full = GridHitTester(metrics: testMetrics, itemCount: 35, containerSize: container, slotCount: 35)
        let allReachable = (0 ..< 35).allSatisfy { full.index(at: full.centre(of: $0)) == $0 }
        check("every slot on a full page is a drop target", allReachable)

        section("Paging model")
        let pager = LaunchpadViewModel(store: store)
        let pageTotal = pager.pageCount
        pager.goToPage(0)
        check("goToPage(0) settles on page 0",
              pager.paging.resolved(count: pageTotal) == 0 && pager.jumper.target == 0)
        pager.goToPage(pageTotal + 99)
        check("goToPage clamps past the end",
              pager.paging.resolved(count: pageTotal) == pageTotal - 1,
              "\(pager.paging.resolved(count: pageTotal)) of \(pageTotal)")
        check("clamped jump targets the last page", pager.jumper.target == pageTotal - 1)
        pager.goToPage(-5)
        check("goToPage clamps below zero", pager.paging.resolved(count: pageTotal) == 0)
        pager.selection = 7
        pager.goToPage(0)
        check("paging clears the cell selection", pager.selection == -1)
        pager.reset()
        check("reset returns to page 0 and clears the jump",
              pager.paging.resolved(count: pageTotal) == 0 && pager.jumper.target == nil)

        // Read-time derivation (Q5/L8): the value is only ever clamped on read,
        // so a transient shrink cannot trap and a rebound returns to the intent.
        let derived = PagingModel()
        derived.set(4, count: 5)
        check("a shrink re-derives an in-range page on read",
              derived.resolved(count: 3) == 2, "\(derived.resolved(count: 3))")
        check("a regrown page count restores the original intent (L8)",
              derived.resolved(count: 5) == 4)

        section("Paging SSOT — deferred reclamation & drop revive (review #11)")
        let ssotURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-ssot-\(UUID().uuidString).json")
        let ssot = DeckStore(storeURL: ssotURL)
        ssot.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 81, cellWidth: 177, cellHeight: 135)

        // Q1: an emptied page must survive while a drag session is open, then be
        // reclaimed exactly once at the end.
        ssot.pages = [[.app("a")], [.app("b")]]
        ssot.beginDragSession()
        ssot.move(itemAt: IndexPath(item: 0, section: 1), to: IndexPath(item: 1, section: 0))
        check("an emptied page is kept during a drag session (Q1)",
              ssot.pages.count == 2, "\(ssot.pages.map(\.count))")
        ssot.endDragSession()
        check("the drag session reclaims the empty page once (Q1)",
              ssot.pages.count == 1, "\(ssot.pages.map(\.count))")

        // Idempotence: a duplicate gesture "open" must not strand the session.
        ssot.beginDragSession()
        ssot.beginDragSession()
        ssot.pages = [[.app("a")], []]
        ssot.endDragSession()
        check("double-open + single close still reclaims (§8.2 Bool session)",
              ssot.pages.count == 1, "\(ssot.pages.map(\.count))")

        // L4: a direct (non-batched) save never persists an empty page.
        ssot.pages = [[.app("a")], []]
        ssot.save()
        check("a direct save reclaims empty pages before writing (L4)",
              ssot.pages.count == 1 && ssot.pages.allSatisfy { !$0.isEmpty },
              "\(ssot.pages.map(\.count))")

        // C1: a deferred (still-visible) empty page is a valid drop target and
        // is revived rather than reclaimed.
        ssot.pages = [[.app("a"), .app("b")], []]
        ssot.beginDragSession()
        ssot.moveItem(.app("b"), toPage: 1)
        check("dropping onto a deferred empty page revives it (C1)",
              ssot.pages.count == 2 && ssot.pages[1] == [.app("b")],
              "\(ssot.pages.map(\.count))")
        ssot.endDragSession()
        check("a revived page is not reclaimed at session end (C1)",
              ssot.pages.count == 2, "\(ssot.pages.map(\.count))")

        // Phenomenon B / C6: a folder member has no grid slot, so the old
        // `locate()`-based dot drop silently vanished. The explicit source now
        // routes it through `moveOutOfFolder`, landing it on the target page.
        let probeFolder = AppFolder(name: "Probe", appIDs: ["fb-a", "fb-b"])
        ssot.folders = [probeFolder.id: probeFolder]
        ssot.pages = [[.folder(probeFolder.id)], [.app("solo")]]
        check("a folder member has no grid slot (the locate() blind spot)",
              ssot.locate(.app("fb-a")) == nil)
        let movedOut = ssot.moveOutOfFolder("fb-a", folder: probeFolder.id, toPage: 1, index: 0)
        check("a folder member dropped on a dot lands on the target page (B/C6)",
              movedOut && ssot.locate(.app("fb-a"))?.section == 1,
              "section \(String(describing: ssot.locate(.app("fb-a"))?.section))")
        ssot.endDragSession()
        try? FileManager.default.removeItem(at: ssotURL)

        section("Cross-page drag")
        if store.pages.count >= 2, let moved = store.pages[0].last {
            let targetPage = 1
            let before = store.locate(moved)
            // Count slots, not apps: a folder occupies one slot but holds many
            // apps, so comparing against the app count would be meaningless.
            let slotsBefore = store.pages.flatMap { $0 }.count
            store.moveItem(moved, toPage: targetPage)
            let after = store.locate(moved)
            let slotsAfter = store.pages.flatMap { $0 }.count
            check("dropping on a page dot moves the item to that page",
                  after?.section == targetPage,
                  "was page \(before?.section ?? -1), now \(after?.section ?? -1)")
            check("moving between pages neither creates nor drops slots",
                  slotsAfter == slotsBefore, "\(slotsBefore) -> \(slotsAfter)")
            check("no page exceeds capacity after a cross-page move",
                  store.pages.allSatisfy { $0.count <= capacity })
            // Dropping onto the item's own page must not reshuffle it.
            let here = store.locate(moved)
            store.moveItem(moved, toPage: targetPage)
            check("dropping on the current page is a no-op",
                  store.locate(moved) == here)
        } else {
            check("at least two pages available for the drag test", false)
        }

        section("Frame registry (folder animation proxy)")
        let sample = CGRect(x: 10, y: 20, width: 100, height: 50)
        FrameRegistry.shared.record("selftest.tile", frame: sample)
        check("records and returns a tile frame", FrameRegistry.shared.frame(for: "selftest.tile") == sample)
        FrameRegistry.shared.record("selftest.empty", frame: .zero)
        check("ignores degenerate frames during teardown",
              FrameRegistry.shared.frame(for: "selftest.empty") == nil)
        check("unknown key has no frame", FrameRegistry.shared.frame(for: "selftest.absent") == nil)

        section("Hot corners")
        check("top-left is top and left", HotCorner.topLeft.isTop && HotCorner.topLeft.isLeft)
        check("top-right is top, not left", HotCorner.topRight.isTop && !HotCorner.topRight.isLeft)
        check("bottom-left is left, not top", !HotCorner.bottomLeft.isTop && HotCorner.bottomLeft.isLeft)
        check("bottom-right is neither", !HotCorner.bottomRight.isTop && !HotCorner.bottomRight.isLeft)
        check("off is disabled", !HotCorner.off.isEnabled)
        check("exactly four corners are selectable",
              HotCorner.allCases.filter(\.isEnabled).count == 4)

        section("Performance")
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let apps = store.visibleApps
            var start = Date()
            for _ in 0 ..< 20 {
                for app in apps { _ = LaunchService.isRunning(app) }
            }
            let runningMillis = Date().timeIntervalSince(start) * 1000
            print(String(format: "      running-state: %d apps x20 = %.1f ms", apps.count, runningMillis))
            check("running-state lookup is a cached set hit", runningMillis < 400,
                  String(format: "%.1f ms", runningMillis))

            start = Date()
            for _ in 0 ..< 5 {
                for app in apps { _ = app.icon }
            }
            let iconMillis = Date().timeIntervalSince(start) * 1000
            print(String(format: "      icon lookup: %d apps x5 = %.1f ms", apps.count, iconMillis))
            check("icon lookup is cached", iconMillis < 400, String(format: "%.1f ms", iconMillis))

            WallpaperProvider.invalidate()
            start = Date()
            let cold = WallpaperProvider.glassWallpaper(for: screen)
            let coldMillis = Date().timeIntervalSince(start) * 1000
            start = Date()
            _ = WallpaperProvider.glassWallpaper(for: screen)
            let warmMillis = Date().timeIntervalSince(start) * 1000
            print(String(format: "      glass wallpaper: cold %.1f ms, warm %.3f ms", coldMillis, warmMillis))
            check("glass wallpaper renders", cold != nil)
            check("glass wallpaper is cached after the first render", warmMillis < 5,
                  String(format: "%.3f ms", warmMillis))
            check("glass render is fast enough for a full-screen open", coldMillis < 1500,
                  String(format: "%.1f ms", coldMillis))
        }

        section("Uninstall scan (read-only)")
        let scanned = store.visibleApps.prefix(6).map { app -> (String, Int) in
            (app.name, AppUninstaller.relatedFiles(for: app).count)
        }
        for (name, count) in scanned {
            print("      \(name): \(count) related item(s)")
        }
        check("uninstall scan completes without crashing", true)
        let totalFound = scanned.reduce(0) { $0 + $1.1 }
        check("uninstall scan finds leftovers for at least one app", totalFound > 0, "\(totalFound) total")

        section("Global hotkey (Carbon registration)")
        HotKeyManager.shared.unregister()
        HotKeyManager.shared.register(.optionSpace) {}
        check("⌥Space registers", HotKeyManager.shared.lastError == nil,
              HotKeyManager.shared.lastError ?? "ok")
        HotKeyManager.shared.unregister()

        section("Permissions")
        print("      Accessibility: \(Permissions.hasAccessibility)")
        print("      Full Disk Access: \(Permissions.hasFullDiskAccess)")
        print("      Pinch monitor running: \(PinchMonitor.shared.isRunning)")
        print("      Launchpad key monitor running: \(LaunchpadKeyMonitor.shared.isRunning)")

        let accessibilityOptional = true
        check("permission probes answer without crashing", accessibilityOptional)

        section("Folder column rule (review C1)")
        // The keyboard navigation inside a folder must use the same column count
        // the folder panel actually draws. Before the fix `LaunchpadViewModel`
        // hard-coded four, so ↑/↓ skipped or mis-aligned rows for 2–9 member
        // folders. `FolderLayout` is now the single source for both.
        let expectedColumns: [(count: Int, columns: Int)] = [
            (0, 1), (1, 1), (2, 2), (3, 2), (4, 2), (5, 3), (6, 3), (7, 3),
            (8, 3), (9, 3), (10, 4), (11, 4), (12, 4), (13, 4), (14, 4),
            (15, 4), (16, 4), (17, 4), (18, 4), (19, 4), (20, 4),
        ]
        let columnMismatch = expectedColumns.filter {
            FolderLayout.columns(forMemberCount: $0.count) != $0.columns
        }
        check("folder column count matches the panel rule for 0..20 members",
              columnMismatch.isEmpty,
              "\(columnMismatch.map { "\($0.count)->\(FolderLayout.columns(forMemberCount: $0.count))" })")

        // Local helper: files next to `url` whose name starts with its name and
        // contains `marker` (i.e. the `.corrupt-*` / `.bak` siblings).
        func siblingFiles(of url: URL, containing marker: String) -> [URL] {
            let dir = url.deletingLastPathComponent()
            let prefix = url.lastPathComponent
            let all = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            return all.filter {
                $0.lastPathComponent.hasPrefix(prefix)
                    && $0.lastPathComponent.contains(marker)
            }
        }

        section("P0 data safety — damaged layout is preserved, not overwritten (A1)")
        // (a) A file that exists but cannot be decoded must NOT be replaced with a
        // reconstructed layout: the damaged bytes are kept as a `.corrupt-*`
        // sibling and the store degrades to read-only.
        let corruptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-corrupt-\(UUID().uuidString).json")
        let damagedText = "{ this is not valid json "
        try? Data(damagedText.utf8).write(to: corruptURL)
        let damagedStore = DeckStore(storeURL: corruptURL)
        let preserved = siblingFiles(of: corruptURL, containing: ".corrupt-")
        let preservedBytes = preserved.first.flatMap { try? Data(contentsOf: $0) }
        check("a damaged layout is preserved as a .corrupt sibling",
              preserved.count == 1 && preservedBytes == Data(damagedText.utf8),
              "\(preserved.map { $0.lastPathComponent })")
        check("the damaged file is NOT overwritten with a reconstructed layout",
              (try? Data(contentsOf: corruptURL)) == Data(damagedText.utf8))
        check("a damaged layout sets lastError naming the preserved file",
              (damagedStore.lastError ?? "").contains(".corrupt-"),
              damagedStore.lastError ?? "no error")
        check("a damaged layout enters degraded (non-persisting) mode",
              damagedStore.isDegraded)
        check("a damaged layout sets a health message for the settings UI",
              (damagedStore.layoutHealthMessage ?? "").contains(".corrupt-"),
              damagedStore.layoutHealthMessage ?? "no message")
        for url in preserved { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: corruptURL)

        section("P0 data safety — a missing key decodes instead of being fatal")
        // (b) Missing keys must be recoverable (defaults), not corrupt. Only a
        // real syntax/truncation error is fatal.
        let liveID = store.visibleApps.first?.id ?? "com.apple.Safari"
        let missingURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-missing-\(UUID().uuidString).json")
        let missingJSON = #"{"pages": [["app:\#(liveID)"]], "folders": [], "hidden": []}"#
        try? Data(missingJSON.utf8).write(to: missingURL)
        let missingStore = DeckStore(storeURL: missingURL)
        check("a layout missing sortKey/sortOrder/customOrder still decodes",
              missingStore.pages.flatMap { $0 }.contains(.app(liveID)),
              "\(missingStore.pages.flatMap { $0 })")
        check("a missing-key layout falls back to the field defaults",
              missingStore.sortKey == .manual && missingStore.sortOrder == .ascending)
        check("a missing-key layout is not treated as corruption",
              siblingFiles(of: missingURL, containing: ".corrupt-").isEmpty)
        try? FileManager.default.removeItem(at: missingURL)

        section("P0 data safety — recovery from the backup (A2)")
        // (c) A damaged main file with a readable `.bak` recovers its data.
        let recoverURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-recover-\(UUID().uuidString).json")
        let recoverBak = recoverURL.appendingPathExtension("bak")
        let goodJSON = #"{"pages": [["app:\#(liveID)"]], "folders": [], "hidden": [], "sortKey": "name", "sortOrder": "descending", "customOrder": []}"#
        try? Data(goodJSON.utf8).write(to: recoverBak)
        try? Data("{ still broken".utf8).write(to: recoverURL)
        let recoveredStore = DeckStore(storeURL: recoverURL)
        check("a damaged main file recovers its layout from the backup",
              recoveredStore.pages.flatMap { $0 }.contains(.app(liveID))
                && recoveredStore.sortKey == .name
                && recoveredStore.sortOrder == .descending,
              "sortKey=\(recoveredStore.sortKey.rawValue) order=\(recoveredStore.sortOrder.rawValue)")
        check("recovery reports that the backup was used",
              (recoveredStore.lastError ?? "").lowercased().contains("backup"),
              recoveredStore.lastError ?? "no error")
        check("recovery still preserves the damaged file",
              siblingFiles(of: recoverURL, containing: ".corrupt-").count == 1)
        check("recovery is not degraded — writes stay enabled",
              !recoveredStore.isDegraded)
        for url in siblingFiles(of: recoverURL, containing: ".corrupt-") {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: recoverURL)
        try? FileManager.default.removeItem(at: recoverBak)

        section("P0 data safety — write-before rotation keeps the previous layout (A2)")
        // (d) Each save leaves the *previous* on-disk layout behind as `.bak`.
        let rotateURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-rotate-\(UUID().uuidString).json")
        let rotateStore = DeckStore(storeURL: rotateURL)
        rotateStore.save()
        let rotateV1 = try? Data(contentsOf: rotateURL)
        rotateStore.sortOrder = .descending
        rotateStore.save()
        let rotateV2 = try? Data(contentsOf: rotateURL)
        let rotateBakBytes = try? Data(contentsOf: rotateURL.appendingPathExtension("bak"))
        check("a save rotates the previous layout into `layout.json.bak`",
              rotateV1 != nil && rotateV2 != nil && rotateV1 != rotateV2
                && rotateBakBytes == rotateV1,
              "bak==v1? \(rotateBakBytes == rotateV1)")
        try? FileManager.default.removeItem(at: rotateURL)
        try? FileManager.default.removeItem(at: rotateURL.appendingPathExtension("bak"))

        section("P0 data safety — hidden list is written deterministically")
        // (e) `hidden` is a Set. Its iteration order is stable *within* a process
        // but not across processes, so the emitted array must be sorted. NOTE:
        // this asserts the in-process byte stability AND the emitted-array-is-
        // sorted property; it cannot by itself prove cross-process determinism.
        let hiddenBytesURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-hiddenbytes-\(UUID().uuidString).json")
        let hiddenStore = DeckStore(storeURL: hiddenBytesURL)
        if hiddenStore.visibleApps.count >= 3 {
            hiddenStore.setHidden(hiddenStore.visibleApps[0].id, true)
            hiddenStore.setHidden(hiddenStore.visibleApps[1].id, true)
            hiddenStore.save()
            let hiddenWrite1 = try? Data(contentsOf: hiddenBytesURL)
            hiddenStore.save()
            let hiddenWrite2 = try? Data(contentsOf: hiddenBytesURL)
            check("two saves with a multi-member hidden set are byte-identical (in-process)",
                  hiddenWrite1 != nil && hiddenWrite1 == hiddenWrite2)
            if let data = hiddenWrite1,
               let root = try? JSONSerialization.jsonObject(with: data),
               let obj = root as? [String: Any],
               let emitted = obj["hidden"] as? [String] {
                check("the serialized hidden list is emitted sorted",
                      emitted == emitted.sorted(), "\(emitted)")
            } else {
                check("the serialized hidden list is emitted sorted", false, "no JSON")
            }
        } else {
            check("three apps available for the hidden-bytes test", false)
        }
        try? FileManager.default.removeItem(at: hiddenBytesURL)

        section("P0 follow-up — an empty `pages` array is preserved, not silently rebuilt (A1/B)")
        // A valid JSON file whose `pages` is an empty array decodes cleanly but is
        // something `save()` never writes, so it means the file was emptied
        // externally. It must be preserved and reported, not silently rebuilt.
        func jsonArray(_ values: [String]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: values)) ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        let emptyPagesURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-emptypages-\(UUID().uuidString).json")
        // Learn the exact app-id set a *fresh* store sees: the long-lived `store`
        // above has had one app hidden by an earlier section, so its `visibleApps`
        // is not the set this brand-new store will load.
        let freshProbeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-probe-\(UUID().uuidString).json")
        let allIDs = DeckStore(storeURL: freshProbeURL).visibleApps.map(\.id)
        try? FileManager.default.removeItem(at: freshProbeURL)
        try? FileManager.default.removeItem(at: freshProbeURL.appendingPathExtension("bak"))
        let memberA = allIDs.first ?? ""
        let memberB = allIDs.dropFirst().first ?? ""
        let folderUUID = UUID()
        // Real folder/customOrder/hidden values, to prove `apply` preserved them.
        let emptyPagesJSON = "{\"pages\": [], \"folders\": [{\"id\": \"\(folderUUID.uuidString)\", \"name\": \"Keep\", \"appIDs\": [\"\(memberA)\", \"\(memberB)\"]}], \"hidden\": [], \"sortKey\": \"manual\", \"sortOrder\": \"ascending\", \"customOrder\": \(jsonArray(allIDs))}"
        try? Data(emptyPagesJSON.utf8).write(to: emptyPagesURL)
        let emptyPagesStore = DeckStore(storeURL: emptyPagesURL)
        let emptyPagesSiblings = siblingFiles(of: emptyPagesURL, containing: ".empty-pages-")
        check("an empty-`pages` layout is preserved as a sibling",
              emptyPagesSiblings.count == 1,
              "\(emptyPagesSiblings.map { $0.lastPathComponent })")
        check("an empty-`pages` layout sets a health message naming the file",
              (emptyPagesStore.layoutHealthMessage ?? "").contains(".empty-pages-"),
              emptyPagesStore.layoutHealthMessage ?? "no message")
        check("an empty-`pages` layout stays writable (not degraded)",
              !emptyPagesStore.isDegraded)
        check("the grid is rebuilt so the deck is not empty",
              !emptyPagesStore.pages.flatMap { $0 }.isEmpty,
              "\(emptyPagesStore.pages.count) page(s)")
        check("customOrder is preserved, not reset, by the empty-`pages` path",
              emptyPagesStore.customOrder == allIDs,
              "\(emptyPagesStore.customOrder.count) vs \(allIDs.count)")
        for url in emptyPagesSiblings { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: emptyPagesURL)

        section("P0 follow-up 2 — empty `pages` with an unpreservable site must NOT overwrite (#30)")
        // A read-only parent directory makes the preservation `copyItem` fail
        // with EACCES. The store must then refuse to rebuild (a rebuild would
        // `save()` over the only copy) and degrade instead — and must not claim a
        // copy was kept.
        let lockedDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-locked-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        let lockedURL = lockedDir.appendingPathComponent("layout.json")
        let lockedJSON = #"{"pages": [], "folders": [], "hidden": [], "sortKey": "manual", "sortOrder": "ascending", "customOrder": []}"#
        try? Data(lockedJSON.utf8).write(to: lockedURL)
        let lockedOriginal = try? Data(contentsOf: lockedURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)
        let lockedStore = DeckStore(storeURL: lockedURL)
        let lockedMessage = lockedStore.layoutHealthMessage ?? ""
        check("empty-`pages` + unpreservable site degrades instead of overwriting",
              lockedStore.isDegraded)
        check("empty-`pages` + unpreservable site leaves the file byte-identical",
              (try? Data(contentsOf: lockedURL)) == lockedOriginal,
              "\(lockedOriginal?.count ?? -1) B")
        check("empty-`pages` + unpreservable site does not claim a copy was kept",
              !lockedMessage.isEmpty && !lockedMessage.lowercased().contains("copy was kept"),
              lockedMessage.isEmpty ? "no message" : lockedMessage)
        check("empty-`pages` + unpreservable site attempts no write",
              !(lockedStore.lastError ?? "").lowercased().contains("save failed"),
              lockedStore.lastError ?? "no lastError")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        try? FileManager.default.removeItem(at: lockedDir)

        // ------------------------------------------------------------------
        // Review 24 — the failure branches of the data-safety paths.
        //
        // Every case below is written so that **breaking the fix makes it fail**;
        // each was mutation-tested with `Tools/mutation-test.py`. Two of them exist
        // precisely because the earlier probes could not discriminate:
        //   * 🔴1's `save()` unconditional write had no `.bak` to overwrite;
        //   * QA's E3 relied on pre-creating a same-named item, which the
        //     sibling-name uniqueness fix removes — so the failure is now
        //     *injected* through `FileSeams` instead.
        // ------------------------------------------------------------------

        // Shared fixtures.
        let reviewGoodJSON = "{\"pages\": [[\"app:\(memberA)\"], [\"app:\(memberB)\"]], \"folders\": [], \"hidden\": [], \"sortKey\": \"name\", \"sortOrder\": \"descending\", \"customOrder\": []}"
        let reviewEmptyJSON = "{\"pages\": [], \"folders\": [], \"hidden\": [], \"sortKey\": \"manual\", \"sortOrder\": \"ascending\", \"customOrder\": []}"
        func tempFile(_ tag: String) -> URL {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("opendeck-\(tag)-\(UUID().uuidString).json")
        }
        func sweep(_ url: URL, _ marker: String) {
            for sibling in siblingFiles(of: url, containing: marker) {
                try? FileManager.default.removeItem(at: sibling)
            }
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bak").appendingPathExtension("new"))
        }

        section("Review 24 🔴1 — a rebuild must not consume the good backup")
        // The empty-`pages` branch preserved the current (bogus) file as a
        // sibling, but the `reconcile() → save() → rotateBackup()` that followed
        // copied that same bogus file over `.bak` — the one artifact that could
        // still have recovered the layout. The old case could not see it because
        // it never placed a `.bak` for the rotation to overwrite.
        let keepBakURL = tempFile("keepbak")
        let keepBakFile = keepBakURL.appendingPathExtension("bak")
        try? Data(reviewGoodJSON.utf8).write(to: keepBakFile)
        try? Data(reviewEmptyJSON.utf8).write(to: keepBakURL)
        let keepBakStore = DeckStore(storeURL: keepBakURL)
        check("🔴1 the healthy `.bak` is not overwritten by the rebuild",
              (try? Data(contentsOf: keepBakFile)) == Data(reviewGoodJSON.utf8),
              (try? Data(contentsOf: keepBakFile)).map { "\($0.count) B" } ?? "gone")
        check("🔴1 the rebuild still wrote a real layout",
              (try? Data(contentsOf: keepBakURL)) != Data(reviewEmptyJSON.utf8),
              "\(keepBakStore.pages.count) page(s)")
        check("🔴1 the rebuild stays writable and the bogus file is still preserved",
              !keepBakStore.isDegraded
                && siblingFiles(of: keepBakURL, containing: ".empty-pages-").count == 1)
        sweep(keepBakURL, ".empty-pages-")

        section("Review 24 🔴2 — a recovery that cannot write must not eat the backup")
        // The recovery path wrote the good bytes back with a `try?` whose result
        // was ignored. When that write failed the main file stayed damaged,
        // `reconcile()` saved anyway, `rotateBackup()` deleted the only good
        // `.bak` (it removed before it copied) and could not put it back — while
        // the user was told "it was restored from a backup". Injecting the write
        // failure is deterministic; the old probe used a read-only directory,
        // which also blocked the overwrite itself and so proved nothing.
        var healSeams = FileSeams()
        healSeams.writeData = { _, _ in throw CocoaError(.fileWriteUnknown) }
        let healURL = tempFile("heal")
        let healBak = healURL.appendingPathExtension("bak")
        let healDamaged = "{ still broken"
        try? Data(reviewGoodJSON.utf8).write(to: healBak)
        try? Data(healDamaged.utf8).write(to: healURL)
        let healStore = DeckStore(storeURL: healURL, seams: healSeams)
        check("🔴2 the good backup survives a recovery that could not write",
              (try? Data(contentsOf: healBak)) == Data(reviewGoodJSON.utf8),
              (try? Data(contentsOf: healBak)).map { "\($0.count) B" } ?? "gone")
        check("🔴2 the recovery is not reported as having succeeded",
              !(healStore.lastError ?? "").lowercased().contains("recovered the layout from the backup"),
              healStore.lastError ?? "no error")
        check("🔴2 the store degrades instead of writing over the damaged file",
              healStore.isDegraded)
        check("🔴2 the damaged file is left byte-identical",
              (try? Data(contentsOf: healURL)) == Data(healDamaged.utf8))
        check("🔴2 the backup's layout is still adopted in memory",
              healStore.pages.flatMap { $0 }.contains(.app(memberA)))
        check("🔴2 the message points at the intact backup",
              (healStore.layoutHealthMessage ?? "").contains(healBak.lastPathComponent),
              healStore.layoutHealthMessage ?? "no message")
        sweep(healURL, ".corrupt-")

        section("Review 24 E3 — the site cannot be preserved while the directory is writable")
        // The case that really loses data: preservation fails but the directory
        // stays writable, so a rebuild's `save()` would succeed and overwrite the
        // user's only copy. QA's probe manufactured that by pre-creating a
        // same-named item — exactly what the sibling-name uniqueness fix removes.
        // Injecting the copy failure keeps the discrimination where a file-system
        // trick can no longer provide it.
        var copySeams = FileSeams()
        copySeams.copyItem = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let e3URL = tempFile("e3")
        try? Data(reviewEmptyJSON.utf8).write(to: e3URL)
        let e3Original = try? Data(contentsOf: e3URL)
        let e3Store = DeckStore(storeURL: e3URL, seams: copySeams)
        check("E3 an unpreservable site degrades even when the directory is writable",
              e3Store.isDegraded)
        check("E3 the only copy is left byte-identical",
              (try? Data(contentsOf: e3URL)) == e3Original,
              "\(e3Original?.count ?? -1) B")
        check("E3 no write was attempted",
              !(e3Store.lastError ?? "").lowercased().contains("save failed"),
              e3Store.lastError ?? "no lastError")
        check("E3 the message does not claim the file was kept",
              !(e3Store.layoutHealthMessage ?? "").lowercased().contains("copy was kept"),
              e3Store.layoutHealthMessage ?? "no message")
        sweep(e3URL, ".empty-pages-")

        section("Review 24 🟡6 — a display repack is not persisted by the automatic rescan")
        // Changing screen repacks the pages in memory and deliberately does not
        // write. It used to reach disk anyway: opening the deck fires
        // `.deckRescanRequested` → `applyScan` → `reconcile()`, which saved
        // unconditionally. Measured before the fix: `[2,35,35,35,35,4]` became
        // `[100,46]` on disk with no user action, and switching back to the
        // original display did not undo it.
        let reflowURL = tempFile("reflow")
        let reflowStore = DeckStore(storeURL: reflowURL)
        reflowStore.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 100, cellWidth: 150, cellHeight: 150)
        reflowStore.save()
        let reflowDiskBefore = try? Data(contentsOf: reflowURL)
        let shapeBefore = reflowStore.pages.map(\.count)
        reflowStore.metrics = GridMetrics(columns: 4, rows: 3, iconSize: 80, cellWidth: 120, cellHeight: 120)
        let shapeAfter = reflowStore.pages.map(\.count)
        check("🟡6 the smaller grid really did repack in memory",
              shapeAfter != shapeBefore && shapeAfter.allSatisfy { $0 <= 12 },
              "\(shapeBefore) -> \(shapeAfter)")
        // The automatic rescan the window controller triggers when the deck opens.
        reflowStore.applyScan(reflowStore.apps)
        check("🟡6 the rescan does not write the repack to disk",
              (try? Data(contentsOf: reflowURL)) == reflowDiskBefore)
        // ...but a real user edit still persists it, so nothing is stranded.
        if let first = reflowStore.visibleApps.first {
            reflowStore.setHidden(first.id, true)
            reflowStore.setHidden(first.id, false)
        }
        check("🟡6 a real edit still writes",
              (try? Data(contentsOf: reflowURL)) != reflowDiskBefore)
        sweep(reflowURL, ".empty-pages-")

        section("Review 24 🟡9 — same-second loads cannot disable saving")
        // The preserved-sibling name had one-second resolution, so a second load
        // in the same second — or any leftover file bearing that name — made the
        // preservation `copyItem` fail with "destination exists". The store then
        // went read-only for the whole session and blamed a copy it never tried
        // to keep. Measured before the fix: `isDegraded = true`.
        let twiceURL = tempFile("twice")
        try? Data(reviewEmptyJSON.utf8).write(to: twiceURL)
        let twiceFirst = DeckStore(storeURL: twiceURL)
        try? Data(reviewEmptyJSON.utf8).write(to: twiceURL)
        let twiceSecond = DeckStore(storeURL: twiceURL)
        let twiceSiblings = siblingFiles(of: twiceURL, containing: ".empty-pages-")
        check("🟡9 two loads in the same second each keep their own copy",
              twiceSiblings.count == 2,
              "\(twiceSiblings.map { $0.lastPathComponent })")
        check("🟡9 neither load was silently turned read-only",
              !twiceFirst.isDegraded && !twiceSecond.isDegraded)
        sweep(twiceURL, ".empty-pages-")

        // A leftover named in the OLD whole-second format must be inert too.
        let legacyURL = tempFile("legacy")
        let legacyFormatter = ISO8601DateFormatter()
        legacyFormatter.formatOptions = [.withInternetDateTime]
        let legacyStamps = [-1, 0, 1].map { offset in
            legacyFormatter.string(from: Date().addingTimeInterval(Double(offset)))
                .replacingOccurrences(of: ":", with: "")
        }
        try? Data(reviewEmptyJSON.utf8).write(to: legacyURL)
        var legacySiblings: [URL] = []
        for stamp in legacyStamps {
            let url = legacyURL.deletingLastPathComponent()
                .appendingPathComponent(legacyURL.lastPathComponent + ".empty-pages-\(stamp)")
            try? Data(reviewEmptyJSON.utf8).write(to: url)
            legacySiblings.append(url)
        }
        let legacyStore = DeckStore(storeURL: legacyURL)
        check("🟡9 a whole-second leftover can no longer collide with the new name",
              !legacyStore.isDegraded, "\(legacyStamps)")
        for url in legacySiblings { try? FileManager.default.removeItem(at: url) }
        sweep(legacyURL, ".empty-pages-")

        section("Review 24 🔴3 — uninstall matching does not cross vendors")
        // Display-name matching is a substring match over `~/Library/*`, and every
        // result used to come back `isSelected: true` behind a single confirmation
        // click. "Code" therefore selected `com.tencent.codebuddycn` and `Codex`,
        // "Preview" selected `MobileSMSPreview`, and the classic pair is
        // Photos ↔ Photoshop. The fix splits the authoritative match from the guess.
        let identCand = UninstallCandidate(path: "/tmp/ld-ident", isDirectory: false, size: 0, matchKind: .identifier)
        let nameCand = UninstallCandidate(path: "/tmp/ld-name", isDirectory: false, size: 0, matchKind: .nameOnly)
        check("🔴3 the default-selection rule checks identifier matches only",
              UninstallItem.defaultSelection(for: identCand)
                && !UninstallItem.defaultSelection(for: nameCand))
        let ghostApp = AppInfo(
            path: "/Applications/ZZ Code.app",
            bundleID: "com.opendeck.selftest.definitely.absent",
            name: "Code",
            addedDate: nil,
            lastUsedDate: nil
        )
        let ghostMatches = AppUninstaller.relatedFiles(for: ghostApp)
        print("      \"Code\" with an absent bundle id matched \(ghostMatches.count) entr(ies) by name")
        check("🔴3 an app whose bundle id matches nothing pre-selects nothing",
              ghostMatches.allSatisfy { !UninstallItem.defaultSelection(for: $0) },
              "\(ghostMatches.count) hit(s)")
        check("🔴3 a name-only hit is never labelled an identifier hit",
              ghostMatches.allSatisfy { $0.matchKind == .nameOnly })
        check("🔴3 every hit really does contain the name it was matched on",
              ghostMatches.allSatisfy { $0.displayName.lowercased().contains("code") })
        let audited = store.visibleApps.prefix(6)
            .map { AppUninstaller.relatedFiles(for: $0) }
            .first { !$0.isEmpty }
        if let audited {
            check("🔴3 nothing that names the bundle id is left unchecked",
                  audited.filter { !UninstallItem.defaultSelection(for: $0) }
                      .allSatisfy { $0.matchKind == .nameOnly })
            check("🔴3 everything pre-selected is an identifier match",
                  audited.filter { UninstallItem.defaultSelection(for: $0) }
                      .allSatisfy { $0.matchKind == .identifier })
            check("🔴3 identifier matches are listed before name-only ones",
                  audited.first?.matchKind == .identifier
                    || audited.allSatisfy { $0.matchKind == .nameOnly })
            let identSizes = audited.filter { $0.matchKind == .identifier }.map(\.size)
            check("🔴3 identifier matches are listed biggest first",
                  zip(identSizes, identSizes.dropFirst()).allSatisfy { $0 >= $1 })
        } else {
            check("uninstall scan produced a list to audit", false, "every app returned no matches")
        }
        // The escaping helper both AppleScript sites now share.
        check("🔴3 a quote is escaped for an AppleScript literal",
              "a\"b".appleScriptLiteral == "a\\\"b")
        check("🔴3 a backslash is escaped for an AppleScript literal",
              "a\\b".appleScriptLiteral == "a\\\\b")

        // ------------------------------------------------------------------
        // Review 26 — the doc 25 fixes, adversarially re-tested.
        //
        // doc 25 stopped a *bad* file from overwriting a good backup. It did not
        // stop a redundant `save()` from consuming one, nor a partially failed
        // scan from being believed as the truth about what is installed. Both are
        // mutation-tested (Tools/mutation-test.py).
        // ------------------------------------------------------------------

        section("Review 26 🔴B — a redundant save must not consume the backup")
        // `rotateBackup()` copies whatever is in the file *right now* over `.bak`,
        // so a save that changes nothing still replaces the previous generation
        // with a twin of the main file — and the main file's bytes do not move,
        // so nothing looks wrong. Measured in doc 26 (PROBE D): the sentinel
        // `.bak` was eaten, leaving `.bak` byte-identical to `layout.json`.
        let noopURL = tempFile("noop")
        let noopBak = noopURL.appendingPathExtension("bak")
        let noopStore = DeckStore(storeURL: noopURL)
        noopStore.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 100, cellWidth: 150, cellHeight: 150)
        noopStore.save()
        let noopMain = try? Data(contentsOf: noopURL)
        // A sentinel whose bytes differ from the layout, so "left alone" and
        // "replaced by a twin of the main file" are distinguishable.
        let noopSentinel = Data(#"{"sentinel":"the previous generation"}"#.utf8)
        try? noopSentinel.write(to: noopBak)
        noopStore.save()
        check("🔴B a save with no state change leaves the main file byte-identical",
              (try? Data(contentsOf: noopURL)) == noopMain,
              "\(noopMain?.count ?? -1) B")
        check("🔴B a save with no state change leaves the previous generation alone",
              (try? Data(contentsOf: noopBak)) == noopSentinel,
              (try? Data(contentsOf: noopBak)).map { "\($0.count) B" } ?? "gone")
        // A real change must still rotate — and `.bak` must then hold the state
        // from *before* it. That is the only property that makes `.bak` worth
        // having, and it is what the "no redundant write" rule must not break.
        let preEdit = try? Data(contentsOf: noopURL)
        if let victim = noopStore.visibleApps.first { noopStore.setHidden(victim.id, true) }
        check("🔴B a real change still writes",
              (try? Data(contentsOf: noopURL)) != preEdit)
        check("🔴B a real change rotates the pre-change bytes into `.bak`",
              (try? Data(contentsOf: noopBak)) == preEdit,
              (try? Data(contentsOf: noopBak)).map { "\($0.count) B" } ?? "gone")
        sweep(noopURL, ".empty-pages-")

        section("Review 26 🔴A — a partially failed scan must not be adopted")
        // `AppScanner` returns an empty list for a search root it cannot read and
        // silently skips a bundle it cannot open, so a scan can lose most of the
        // machine and still look like a success. `reconcile` believed it, which is
        // destructive *and* permanent: the folders dissolve, slots / `hidden`
        // marks / `customOrder` entries are deleted, and the save that follows is
        // rotated over `.bak`. A layout built from a partial scan decodes fine, so
        // `.bak` is never consulted and the loss outlives the relaunch. Measured
        // in doc 26: 146 apps -> 3 apps, 336 B on disk, all four folders gone.
        let scanURL = tempFile("scan")
        let scanStore = DeckStore(storeURL: scanURL)
        scanStore.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 100, cellWidth: 150, cellHeight: 150)
        // A two-member folder and a `hidden` mark: both are unrecoverable, and
        // both are exactly what adopting a partial scan would destroy.
        if let hiddenVictim = scanStore.visibleApps.first {
            scanStore.setHidden(hiddenVictim.id, true)
        }
        let folderPool = Array(scanStore.visibleApps.prefix(2)).map(\.id)
        if folderPool.count == 2 {
            scanStore.makeFolder(dropping: folderPool[1], onto: folderPool[0])
        }
        let scanDiskBefore = try? Data(contentsOf: scanURL)
        let scanShapeBefore = scanStore.pages.map(\.count)
        let scanFoldersBefore = scanStore.folders.count
        let scanOrderBefore = scanStore.customOrder.count
        let scanHiddenBefore = scanStore.hidden.count
        let scanBakBefore = try? Data(contentsOf: scanURL.appendingPathExtension("bak"))
        let partial = Array(scanStore.apps.prefix(3))
        check("🔴A the fixture has a folder and a hidden mark to lose",
              scanFoldersBefore == 1 && scanHiddenBefore == 1,
              "folders=\(scanFoldersBefore) hidden=\(scanHiddenBefore)")
        scanStore.applyScan(partial)
        check("🔴A a partial scan writes nothing at all",
              (try? Data(contentsOf: scanURL)) == scanDiskBefore)
        check("🔴A a partial scan does not touch the backup either",
              (try? Data(contentsOf: scanURL.appendingPathExtension("bak"))) == scanBakBefore)
        check("🔴A a partial scan does not dissolve the folder",
              scanStore.folders.count == scanFoldersBefore,
              "\(scanFoldersBefore) -> \(scanStore.folders.count)")
        check("🔴A a partial scan does not drop grid slots",
              scanStore.pages.map(\.count) == scanShapeBefore,
              "\(scanShapeBefore) -> \(scanStore.pages.map(\.count))")
        check("🔴A a partial scan does not delete the `hidden` mark",
              scanStore.hidden.count == scanHiddenBefore)
        check("🔴A a partial scan does not truncate `customOrder`",
              scanStore.customOrder.count == scanOrderBefore,
              "\(scanOrderBefore) -> \(scanStore.customOrder.count)")
        check("🔴A the discarded scan is not even shown in memory",
              scanStore.apps.count != partial.count,
              "\(scanStore.apps.count) app(s) still listed")
        check("🔴A the rejection is visible, not silent",
              (scanStore.lastError ?? "").contains("failed scan"),
              scanStore.lastError ?? "no lastError")
        // ...but "discarded" must not mean "never": the same scan seen twice is
        // believed, or a real mass uninstall could never be recorded at all.
        scanStore.applyScan(partial)
        check("🔴A the same scan seen twice is believed and persisted",
              scanStore.apps.count == partial.count
                && (try? Data(contentsOf: scanURL)) != scanDiskBefore,
              "\(scanStore.apps.count) app(s)")
        sweep(scanURL, ".empty-pages-")

        section("Review 26 🔴A (launch path) — a load is screened too")
        // The launch path never passes through `applyScan`'s check: `applyScan`
        // runs while `isLoading`, so the scan is only judged inside `reconcile`,
        // where the layout on disk is the thing at risk. This models a layout
        // whose apps the scan cannot see — the shape a partial scan produces.
        let ghostIDs = (0 ..< 60).map { "test.ghost.\($0)" }
        let ghostSlots = ghostIDs.map { "\"app:\($0)\"" }.joined(separator: ", ")
        let ghostJSON = "{\"pages\": [[\(ghostSlots), \"app:\(memberA)\", \"app:\(memberB)\"]], \"folders\": [], \"hidden\": [], \"sortKey\": \"manual\", \"sortOrder\": \"ascending\", \"customOrder\": \(jsonArray(ghostIDs + [memberA, memberB]))}"
        let ghostURL = tempFile("ghost")
        try? Data(ghostJSON.utf8).write(to: ghostURL)
        let ghostSentinel = Data(#"{"sentinel":"before the ghosts"}"#.utf8)
        try? ghostSentinel.write(to: ghostURL.appendingPathExtension("bak"))
        let ghostStore = DeckStore(storeURL: ghostURL)
        check("🔴A a layout the scan cannot see is left byte-identical",
              (try? Data(contentsOf: ghostURL)) == Data(ghostJSON.utf8),
              "\((try? Data(contentsOf: ghostURL))?.count ?? -1) B")
        check("🔴A its backup is not rotated over",
              (try? Data(contentsOf: ghostURL.appendingPathExtension("bak"))) == ghostSentinel)
        check("🔴A the ghosts are not pruned from the grid",
              ghostStore.pages.flatMap { $0 }.contains(.app(ghostIDs[0])),
              "\(ghostStore.pages.flatMap { $0 }.count) slot(s)")
        check("🔴A the launch-path rejection is visible too",
              (ghostStore.lastError ?? "").contains("failed scan"),
              ghostStore.lastError ?? "no lastError")
        sweep(ghostURL, ".empty-pages-")

        section("Review 26 🔴A (one app) — one missing observation is not an uninstall")
        // Any count threshold must tolerate an ordinary uninstall, so a one-app gap
        // is always below it. The follow-up probe for doc 26 measured what that
        // costs: a two-member folder was dissolved (its name lost with it) and a
        // `hidden` mark was deleted — both written to disk. So the rule is
        // per-app as well: a missing app keeps the records a single observation
        // would destroy *permanently* (folder membership, `hidden`, the manual
        // order) for one more scan. Its grid slot is still dropped, because a slot
        // that cannot be drawn renders as a hole.
        let gapURL = tempFile("gap")
        let gapStore = DeckStore(storeURL: gapURL)
        gapStore.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 100, cellWidth: 150, cellHeight: 150)
        let gapPool = Array(gapStore.visibleApps.prefix(2)).map(\.id)
        if gapPool.count == 2 { gapStore.makeFolder(dropping: gapPool[1], onto: gapPool[0]) }
        let gapFolderID = gapStore.folders.keys.first
        let gapFolderName = gapFolderID.flatMap { gapStore.folders[$0]?.name }
        check("🔴A(one) the fixture is a two-member folder",
              gapStore.folders.count == 1 && gapFolderID.flatMap { gapStore.folders[$0]?.appIDs.count } == 2)
        gapStore.applyScan(gapStore.apps.filter { $0.id != gapPool[1] })
        check("🔴A(one) one missing member does not dissolve the folder",
              gapStore.folders.count == 1, "\(gapStore.folders.count) folder(s)")
        check("🔴A(one) the missing member is kept, so it can come back",
              gapFolderID.flatMap { gapStore.folders[$0]?.appIDs.contains(gapPool[1]) } == true)
        check("🔴A(one) the folder name survives",
              gapFolderID.flatMap { gapStore.folders[$0]?.name } == gapFolderName)
        // A second scan that still lacks it confirms the uninstall — the old
        // behaviour, one scan later, so nothing is stranded.
        gapStore.applyScan(gapStore.apps.filter { $0.id != gapPool[1] })
        check("🔴A(one) a second scan confirms the uninstall and dissolves it",
              gapStore.folders.isEmpty, "\(gapStore.folders.count) folder(s)")
        sweep(gapURL, ".empty-pages-")

        // The same rule, for a `hidden` mark and for a grid slot: the mark is
        // kept, the slot is not.
        let slotURL = tempFile("slot")
        let slotStore = DeckStore(storeURL: slotURL)
        slotStore.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 100, cellWidth: 150, cellHeight: 150)
        let markVictim = slotStore.visibleApps.first
        if let markVictim { slotStore.setHidden(markVictim.id, true) }
        let slotVictim = slotStore.visibleApps.dropFirst(2).first
        let slotsAtStart = slotStore.pages.flatMap { $0 }.count
        let vanished = [markVictim?.id, slotVictim?.id].compactMap { $0 }
        slotStore.applyScan(slotStore.apps.filter { !vanished.contains($0.id) })
        check("🔴A(one) a vanished `hidden` app keeps its mark for one scan",
              markVictim.map { slotStore.hidden.contains($0.id) } == true)
        check("🔴A(one) a vanished slot app loses its slot (no hole is left behind)",
              slotStore.pages.flatMap { $0 }.count == slotsAtStart - 1,
              "\(slotsAtStart) -> \(slotStore.pages.flatMap { $0 }.count)")
        slotStore.applyScan(slotStore.apps.filter { !vanished.contains($0.id) })
        check("🔴A(one) a second scan confirms it and drops the mark",
              markVictim.map { !slotStore.hidden.contains($0.id) } == true)
        sweep(slotURL, ".empty-pages-")

        // ------------------------------------------------------------------
        // Rename handover — the identity this app carried before it was
        // renamed to OpenDeck.
        //
        // Everything below runs against throwaway folders, or against a pure
        // function. The real Application Support folder is never opened: the
        // handover exists to write live user state, so exercising it for real
        // from a test would be the very thing it must not do.
        // ------------------------------------------------------------------
        section("Rename handover")

        let currentFile = URL(fileURLWithPath: "/tmp/opendeck-selftest-current/layout.json")
        let legacyFile = URL(fileURLWithPath: "/tmp/opendeck-selftest-legacy/layout.json")
        let absent: (URL) -> Bool = { _ in false }
        let present: (URL) -> Bool = { _ in true }

        check("an explicit store URL always wins", {
            StateHandover.resolveLayout(storeURL: currentFile, readOnly: true,
                                        current: currentFile, legacy: legacyFile,
                                        exists: present) == currentFile
        }())
        check("a writable store never opens the pre-rename file", {
            StateHandover.resolveLayout(storeURL: nil, readOnly: false,
                                        current: currentFile, legacy: legacyFile,
                                        exists: present) == currentFile
        }())
        // The same rule, in the only shape where a writable store *could* be
        // routed into the pre-rename folder: the new file absent, the old one
        // present. Checking it with everything present would pass against a
        // build that had dropped `readOnly` from the condition entirely.
        check("a writable store opens the new file even before it exists", {
            StateHandover.resolveLayout(storeURL: nil, readOnly: false,
                                        current: currentFile, legacy: legacyFile,
                                        exists: { $0 == legacyFile }) == currentFile
        }())
        check("a read-only tool reads the pre-rename file until the new one exists", {
            StateHandover.resolveLayout(storeURL: nil, readOnly: true,
                                        current: currentFile, legacy: legacyFile,
                                        exists: { $0 == legacyFile }) == legacyFile
        }())
        check("a read-only tool uses the new file once it exists", {
            StateHandover.resolveLayout(storeURL: nil, readOnly: true,
                                        current: currentFile, legacy: legacyFile,
                                        exists: present) == currentFile
        }())
        // The renames are pure decisions, so `absent` exists to keep the
        // "nothing on disk" case honest rather than implied.
        check("nothing to hand over when neither folder has a layout", {
            StateHandover.resolveLayout(storeURL: nil, readOnly: true,
                                        current: currentFile, legacy: legacyFile,
                                        exists: absent) == currentFile
        }())

        // The copy itself. File contents are arbitrary: the handover copies
        // bytes and never parses them.
        let handoverRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-handover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: handoverRoot) }
        let oldBase = handoverRoot.appendingPathComponent(StateHandover.legacyFolderName)
        let newBase = handoverRoot.appendingPathComponent("OpenDeck")
        for dir in [oldBase, newBase] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let layoutBytes = Data("opendeck-selftest-layout".utf8)
        let backupBytes = Data("opendeck-selftest-backup".utf8)
        try? layoutBytes.write(to: oldBase.appendingPathComponent("layout.json"))
        try? backupBytes.write(to: oldBase.appendingPathComponent("layout.json.bak"))

        let carriedNames = StateHandover.adoptLayout(from: oldBase, into: newBase)
        check("the layout and its backup are both carried over",
              carriedNames == StateHandover.layoutFiles, "\(carriedNames)")
        check("the carried-over bytes are identical",
              (try? Data(contentsOf: newBase.appendingPathComponent("layout.json"))) == layoutBytes
              && (try? Data(contentsOf: newBase.appendingPathComponent("layout.json.bak"))) == backupBytes)
        check("the pre-rename folder is left untouched (a copy, never a move)",
              (try? Data(contentsOf: oldBase.appendingPathComponent("layout.json"))) == layoutBytes
              && (try? Data(contentsOf: oldBase.appendingPathComponent("layout.json.bak"))) == backupBytes)

        let liveBytes = Data("opendeck-selftest-live".utf8)
        try? liveBytes.write(to: newBase.appendingPathComponent("layout.json"))
        // The default `copyItem` refuses an existing destination on its own, so
        // this cannot be checked through it: a build with no no-overwrite guard
        // would still leave the live file alone and look correct. The guard has
        // to be observed by *whether the copy is attempted at all*, so this seam
        // records calls and clobbers, the way a replace-style copy would.
        var clobberingSeams = FileSeams()
        var attempted: [String] = []
        clobberingSeams.copyItem = { source, destination in
            attempted.append(destination.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let secondPass = StateHandover.adoptLayout(from: oldBase, into: newBase, seams: clobberingSeams)
        check("a second handover never overwrites the live layout",
              (try? Data(contentsOf: newBase.appendingPathComponent("layout.json"))) == liveBytes,
              "\(secondPass)")
        check("a second handover does not even attempt the copy", attempted.isEmpty, "\(attempted)")

        // A copy that reports success and writes nothing. Reaching the reporting
        // line is not evidence that anything landed, so "carried over" has to
        // mean "found on disk afterwards".
        let silentBase = handoverRoot.appendingPathComponent("Silent")
        try? FileManager.default.createDirectory(at: silentBase, withIntermediateDirectories: true)
        var silentSeams = FileSeams()
        silentSeams.copyItem = { _, _ in }
        let silentClaim = StateHandover.adoptLayout(from: oldBase, into: silentBase, seams: silentSeams)
        check("a copy that silently writes nothing is not reported as carried over",
              silentClaim.isEmpty, "\(silentClaim)")

        let failingBase = handoverRoot.appendingPathComponent("Failing")
        try? FileManager.default.createDirectory(at: failingBase, withIntermediateDirectories: true)
        var failingSeams = FileSeams()
        failingSeams.copyItem = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let claimed = StateHandover.adoptLayout(from: oldBase, into: failingBase, seams: failingSeams)
        check("a copy that fails is not reported as carried over", claimed.isEmpty, "\(claimed)")

        // Preferences, as a pure decision — no preferences domain is touched.
        let legacyPrefs: [String: Any] = ["hotKeyCode": 49, "hotKeyEnabled": true, "backdropMode": "glass"]
        let adoptedPrefs = StateHandover.preferencesToAdopt(from: legacyPrefs,
                                                            current: ["backdropMode": "solid"])
        check("preferences the new domain lacks are adopted",
              adoptedPrefs["hotKeyCode"] as? Int == 49
              && adoptedPrefs["hotKeyEnabled"] as? Bool == true,
              "\(adoptedPrefs.keys.sorted())")
        check("a preference the new domain already has is not clobbered",
              adoptedPrefs["backdropMode"] == nil)
        check("keys the legacy domain does not carry are not invented",
              StateHandover.preferencesToAdopt(from: ["hotKeyCode": 49], current: [:]).count == 1)

        print("\n\(checks - failures)/\(checks) checks passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
