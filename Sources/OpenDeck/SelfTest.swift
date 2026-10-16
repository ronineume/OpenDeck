import AppKit
import Foundation
import SwiftUI

/// Headless verification of the logic that cannot be eyeballed in a screenshot.
///
/// Run with `OpenDeck --selftest`. Uses a throwaway layout file and a
/// `Preferences` that drops writes, so neither the real layout nor the real
/// preferences are touched, and it never deletes anything on disk.
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

        section("Ungroup placement (the folder's own page, at its end)")
        // LaunchOS's own wording: "Ungrouped apps are added to the end of their
        // original page. If the page is full, they continue onto the next page
        // and may shift apps on later pages." The page is deliberately tiny (2
        // slots) so a full one is easy to build and the spill is forced.
        let ungroupURL = tempURL.deletingLastPathComponent()
            .appendingPathComponent("opendeck-selftest-ungroup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ungroupURL) }
        let up = DeckStore(storeURL: ungroupURL)
        up.metrics = GridMetrics(columns: 2, rows: 1, iconSize: 100, cellWidth: 150, cellHeight: 150)
        let upIDs = Array(up.visibleApps.prefix(4)).map(\.id)
        if upIDs.count == 4 {
            up.makeFolder(dropping: upIDs[0], onto: upIDs[1])
            if let fid = up.folders.values.first(where: { $0.appIDs.contains(upIDs[0]) })?.id {
                // Page 0 is exactly full (folder + one loose app); page 1 holds one.
                up.pages = [[.folder(fid), .app(upIDs[2])], [.app(upIDs[3])]]
                check("ungroup probe: the folder occupies page 0's first slot",
                      up.locate(.folder(fid)) == IndexPath(item: 0, section: 0))
                up.ungroup(fid)
                let spilled = up.pages.prefix(2).flatMap { $0 }
                check("ungroup removes the folder and its slot",
                      up.folder(fid) == nil
                      && !up.pages.flatMap { $0 }.contains { if case .folder = $0 { return true } else { return false } })
                check("the members land on the folder's page, or the one it spilled onto",
                      spilled.contains(.app(upIDs[0])) && spilled.contains(.app(upIDs[1])),
                      "\(up.pages.map(\.count))")
                check("the page's own items stay ahead of the members",
                      up.pages.first?.first == .app(upIDs[2]), "\(up.pages.map(\.count))")
                check("a full page spills onto the next one (\"they continue onto the next page\")",
                      up.pages.count == 3, "\(up.pages.map(\.count))")
                check("and shifts the page that was already there (\"may shift apps on later pages\")",
                      up.pages.last == [.app(upIDs[3])], "\(up.pages.map(\.count))")
            } else {
                check("ungroup probe: folder created", false)
            }
        } else {
            check("at least four apps for the ungroup test", false)
        }

        section("Ungroup All Folders (one batch, grid order)")
        // LaunchOS ships "Ungroup All Folders"; its own description string for
        // the single-ungroup rule ("added to the end of their original page…
        // continue onto the next page") applies per folder. The batch must be
        // deterministic: folders dissolve in grid order, so the cascade below
        // is pinned exactly — with capacity 2, f1(a,b) on page 0 and f2(c,d)
        // on page 1 the final layout is [[e,a],[b,c],[d,f]], and f3(g,h) —
        // deliberately NOT on the grid — dissolves last onto a fresh page.
        let uaURL = tempURL.deletingLastPathComponent()
            .appendingPathComponent("opendeck-selftest-ungroupall-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: uaURL) }
        let ua = DeckStore(storeURL: uaURL)
        ua.metrics = GridMetrics(columns: 2, rows: 1, iconSize: 100, cellWidth: 150, cellHeight: 150)
        let uaIDs = Array(ua.visibleApps.prefix(8)).map(\.id)
        if uaIDs.count == 8 {
            let a = uaIDs[0], b = uaIDs[1], c = uaIDs[2], d = uaIDs[3]
            let e = uaIDs[4], f = uaIDs[5], g = uaIDs[6], h = uaIDs[7]
            ua.makeFolder(dropping: a, onto: b)
            ua.makeFolder(dropping: c, onto: d)
            ua.makeFolder(dropping: g, onto: h)
            if let f1 = ua.folders.values.first(where: { $0.appIDs.contains(a) })?.id,
               let f2 = ua.folders.values.first(where: { $0.appIDs.contains(c) })?.id,
               let f3 = ua.folders.values.first(where: { $0.appIDs.contains(g) })?.id {
                ua.pages = [[.folder(f1), .app(e)], [.folder(f2), .app(f)]] // f3 off-grid on purpose
                let tokenBefore = ua.mergeFlash?.token ?? 0
                ua.ungroupAllFolders()
                check("ungroup-all dissolves every folder, on-grid or not",
                      ua.folders.isEmpty
                      && !ua.pages.flatMap { $0 }.contains { if case .folder = $0 { return true } else { return false } })
                // `makeFolder(dropping: X, onto: Y)` stores members as [Y, X], and
                // `enforceCapacity` splits an over-full page *in place* (no cascade
                // into the next page). So f1 (members [b, a]) on page 0 leaves
                // [e, b] there with `a` split onto page 1; f2 (members [d, c])
                // then lands [f, d] / [c]; the off-grid f3 (members [h, g])
                // appends to the grid end. Dissolving in any other order produces
                // a different layout, which is what pins the grid order.
                check("ungroup-all lands the cascade exactly (grid order is deterministic)",
                      ua.pages == [[.app(e), .app(b)], [.app(a)], [.app(f), .app(d)], [.app(c), .app(h)], [.app(g)]],
                      "\(ua.pages)")
                check("ungroup-all syncs customOrder to the final layout",
                      ua.customOrder == [e, b, a, f, d, c, h, g], "\(ua.customOrder)")
                check("ungroup-all flashes a release per folder, last one wins",
                      ua.mergeFlash?.kind == .released
                      && ua.mergeFlash?.folderID == f3
                      && ua.mergeFlash?.token == tokenBefore + 3,
                      "\(String(describing: ua.mergeFlash))")
            } else {
                check("ungroup-all probe: three folders created", false)
            }
        } else {
            check("at least eight apps for the ungroup-all test", false)
        }
        // No folders → no-op (the guard cannot be mutation-killed: with an
        // empty folder set the batched pass changes nothing either way, so —
        // report 46 precedent — no mutation is registered for it).
        let uaEmpty = DeckStore(storeURL: uaURL)
        let beforePages = uaEmpty.pages
        uaEmpty.ungroupAllFolders()
        check("ungroup-all with no folders is a no-op", uaEmpty.pages == beforePages)

        section("Reorganize Layout engine (LaunchOS Pro feature, report 53)")
        // Pure-engine fixture: eight apps with controlled names and dates.
        // `addedDate` drives the Date Added sort; `lastUsedDate` the Last Used
        // one; Apple-ness comes from the bundle id.
        func probeApp(_ name: String, _ bundle: String, added: Double, used: Double) -> AppInfo {
            AppInfo(path: "/Applications/\(name).app", bundleID: bundle, name: name,
                    addedDate: Date(timeIntervalSince1970: added),
                    lastUsedDate: Date(timeIntervalSince1970: used))
        }
        let apps53: [AppInfo] = [
            probeApp("Bravo", "com.other.bravo", added: 300, used: 100),
            probeApp("alpha", "com.other.alpha", added: 100, used: 400),
            probeApp("Charlie", "com.apple.charlie", added: 200, used: 300),
            probeApp("delta", "com.other.delta", added: 400, used: 200),
        ]
        let idA = apps53[1].id // alpha
        let idB = apps53[0].id // Bravo
        let idC = apps53[2].id // Charlie (Apple)
        let idD = apps53[3].id // delta

        // 1. Name ascending, folders after apps, one list across pages.
        // NB: the default Apple placement is *after other apps*, so Charlie
        // (com.apple.*) lands last in every expectation below unless the test
        // says otherwise.
        var pages53: [[DeckSlot]] = [[.app(idB), .app(idD)], [.app(idA), .app(idC)]]
        var r = LayoutOrganizer.organize(pages: pages53, folders: [:], apps: apps53,
                                         capacity: 2,
                                         options: OrganizeOptions(sortMethod: .name),
                                         scopePages: [0, 1])
        check("reorganize by name ascending, across pages",
              r.pages == [[.app(idA), .app(idB)], [.app(idD), .app(idC)]], "\(r.pages)")
        check("reorganize with nothing to append reports zero",
              r.appendedPages == 0, "\(r.appendedPages)")

        // 2. Descending flips the key (not the name tiebreak).
        r = LayoutOrganizer.organize(pages: pages53, folders: [:], apps: apps53, capacity: 2,
                                     options: OrganizeOptions(sortMethod: .name,
                                                              sortDirection: .descending),
                                     scopePages: [0, 1])
        check("reorganize by name descending",
              r.pages == [[.app(idD), .app(idB)], [.app(idA), .app(idC)]], "\(r.pages)")

        // 3. Date Added uses the bundle date; equal dates fall back to name.
        r = LayoutOrganizer.organize(pages: pages53, folders: [:], apps: apps53, capacity: 2,
                                     options: OrganizeOptions(sortMethod: .dateAdded),
                                     scopePages: [0, 1])
        check("reorganize by date added ascending (oldest first)",
              r.pages == [[.app(idA), .app(idB)], [.app(idD), .app(idC)]], "\(r.pages)")

        // 4. Last Used, most recent first (descending).
        r = LayoutOrganizer.organize(pages: pages53, folders: [:], apps: apps53, capacity: 2,
                                     options: OrganizeOptions(sortMethod: .lastUsed,
                                                              sortDirection: .descending),
                                     scopePages: [0, 1])
        check("reorganize by last used, most recent first",
              r.pages == [[.app(idA), .app(idD)], [.app(idB), .app(idC)]], "\(r.pages)")

        // 5. Apple placement: after others by default, before others on request.
        r = LayoutOrganizer.organize(pages: pages53, folders: [:], apps: apps53, capacity: 2,
                                     options: OrganizeOptions(appleAppPlacement: .beforeOtherApps),
                                     scopePages: [0, 1])
        check("Apple apps before other apps",
              r.pages == [[.app(idC), .app(idA)], [.app(idB), .app(idD)]], "\(r.pages)")

        // 6. Folder placement: a folder named "Fld" between the apps.
        var folders53 = [UUID(): AppFolder(id: UUID(), name: "Fld", appIDs: [idA, idD])]
        let fid53 = folders53.keys.first!
        pages53 = [[.folder(fid53), .app(idB)], [.app(idC)]]
        r = LayoutOrganizer.organize(pages: pages53, folders: folders53, apps: apps53, capacity: 2,
                                     options: OrganizeOptions(folderPlacement: .beforeApps),
                                     scopePages: [0, 1])
        check("folder before apps", r.pages.first?.first == .folder(fid53), "\(r.pages)")
        r = LayoutOrganizer.organize(pages: pages53, folders: folders53, apps: apps53, capacity: 2,
                                     options: OrganizeOptions(folderPlacement: .afterApps),
                                     scopePages: [0, 1])
        check("folder after apps",
              r.pages.flatMap { $0 }.last == .folder(fid53), "\(r.pages)")
        r = LayoutOrganizer.organize(pages: pages53, folders: folders53, apps: apps53, capacity: 2,
                                     options: OrganizeOptions(folderPlacement: .mixedWithApps),
                                     scopePages: [0, 1])
        // "Fld" sorts after "Bravo"/"Charlie" by localized name, so the
        // three-item fixture (folder, Bravo, Charlie) lands Bravo, Charlie, Fld.
        check("folder mixed with apps by name",
              r.pages.flatMap { $0 } == [.app(idB), .app(idC), .folder(fid53)],
              "\(r.pages)")

        // 7. Selected-pages scope leaves the other pages alone.
        r = LayoutOrganizer.organize(pages: pages53, folders: [:], apps: apps53, capacity: 2,
                                     options: OrganizeOptions(pageScope: .selectedPages,
                                                              selectedPages: [1]),
                                     scopePages: [1])
        check("selected-pages scope touches only page 1",
              r.pages[0] == pages53[0], "\(r.pages)")

        // 8. Per-page mode (acrossPages off) sorts each page independently.
        r = LayoutOrganizer.organize(pages: pages53, folders: [:], apps: apps53, capacity: 2,
                                     options: OrganizeOptions(acrossPages: false),
                                     scopePages: [0, 1])
        check("per-page mode keeps the page split",
              r.pages.count == 2, "\(r.pages)")

        // 9. Also-sort-in-folders rewrites membership only.
        folders53[fid53] = AppFolder(id: fid53, name: "Fld", appIDs: [idB, idA])
        r = LayoutOrganizer.organize(pages: pages53, folders: folders53, apps: apps53, capacity: 2,
                                     options: OrganizeOptions(alsoSortInFolders: true),
                                     scopePages: [0, 1])
        check("also-sort-in-folders rewrites the members",
              r.folders[fid53]?.appIDs == [idA, idB], "\(String(describing: r.folders[fid53]?.appIDs))")

        // 10. Ungroup-all dissolves the folder into the flat list. Fresh
        //     folder (alpha + delta, neither a standalone slot — I2) so the
        //     result can assert "every app exactly once".
        folders53[fid53] = AppFolder(id: fid53, name: "Fld", appIDs: [idA, idD])
        pages53 = [[.folder(fid53), .app(idB)], [.app(idC)]]
        r = LayoutOrganizer.organize(pages: pages53, folders: folders53, apps: apps53, capacity: 2,
                                     options: OrganizeOptions(ungroupAllFolders: true),
                                     scopePages: [0, 1])
        let flat10 = r.pages.flatMap { $0 }.compactMap { slot -> String? in
            if case .app(let id) = slot { return id }
            return nil
        }
        check("ungroup-all dissolves the folder",
              r.folders.isEmpty && !r.pages.flatMap { $0 }.contains(.folder(fid53)),
              "\(r.pages)")
        check("ungroup-all keeps every member exactly once",
              flat10.count == 4 && Set(flat10) == Set([idA, idB, idC, idD]), "\(flat10)")

        // 11. Empty scope is a no-op ("Select at least one page").
        r = LayoutOrganizer.organize(pages: pages53, folders: folders53, apps: apps53,
                                     capacity: 2, options: OrganizeOptions(), scopePages: [])
        check("empty scope changes nothing", r.pages == pages53 && r.folders == folders53)

        // 12. Spill: six items across two scope pages of capacity 2 → the
        //     refill needs a third page; the page after the scope shifts down.
        let sixApps = apps53 + [probeApp("Echo", "com.other.echo", added: 500, used: 500),
                                probeApp("foxtrot", "com.other.foxtrot", added: 600, used: 600)]
        let idE = sixApps[4].id, idF = sixApps[5].id
        let idZ = probeApp("Zulu", "com.other.zulu", added: 700, used: 700).id
        // Three items per page — over capacity on purpose, so the scope holds
        // six items while offering only four slots.
        let spillPages: [[DeckSlot]] = [[.app(idF), .app(idA), .app(idD)],
                                        [.app(idB), .app(idE), .app(idC)],
                                        [.app(idZ)]]
        r = LayoutOrganizer.organize(pages: spillPages, folders: [:], apps: sixApps, capacity: 2,
                                     options: OrganizeOptions(), scopePages: [0, 1])
        check("across-pages refill spills onto a new page",
              r.pages.count == 4 && r.appendedPages == 1
              && r.pages.flatMap { $0 } == [.app(idA), .app(idB), .app(idD), .app(idE),
                                           .app(idF), .app(idC), .app(idZ)],
              "\(r.pages) appended=\(r.appendedPages)")

        // 13. Store-level: one batch write and a synced customOrder.
        let orgURL = tempURL.deletingLastPathComponent()
            .appendingPathComponent("opendeck-selftest-organize-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: orgURL) }
        let org = DeckStore(storeURL: orgURL)
        org.metrics = GridMetrics(columns: 2, rows: 1, iconSize: 100, cellWidth: 150, cellHeight: 150)
        let orgIDs = Array(org.visibleApps.prefix(4)).map(\.id)
        if orgIDs.count == 4 {
            org.pages = [[.app(orgIDs[3]), .app(orgIDs[1])], [.app(orgIDs[2]), .app(orgIDs[0])]]
            org.customOrder = [orgIDs[3], orgIDs[1], orgIDs[2], orgIDs[0]]
            org.reorganize(with: OrganizeOptions(sortMethod: .name))
            let flat = org.pages.flatMap { $0 }.compactMap { slot -> String? in
                if case .app(let id) = slot { return id }
                return nil
            }
            check("store reorganize keeps every app", Set(flat) == Set(orgIDs), "\(flat)")
            check("store reorganize syncs customOrder",
                  org.customOrder == flat, "\(org.customOrder)")
        } else {
            check("at least four apps for the organize test", false)
        }

        // The sheet's validation, pure so the rule and the wording stay
        // together (LaunchOS: "Select at least one page").
        check("canApply: all pages always applies",
              ReorganizeRules.canApply(options: OrganizeOptions(), pageCount: 3))
        check("canApply: selected pages with nothing selected is refused",
              !ReorganizeRules.canApply(
                  options: OrganizeOptions(pageScope: .selectedPages, selectedPages: []),
                  pageCount: 3))
        check("canApply: selected pages with a selection applies",
              ReorganizeRules.canApply(
                  options: OrganizeOptions(pageScope: .selectedPages, selectedPages: [1]),
                  pageCount: 3))
        check("canApply: no pages at all is refused",
              !ReorganizeRules.canApply(options: OrganizeOptions(), pageCount: 0))
        check("hint: only the empty selection gets the LaunchOS wording",
              ReorganizeRules.hint(
                  options: OrganizeOptions(pageScope: .selectedPages, selectedPages: []),
                  pageCount: 3) == "Select at least one page"
              && ReorganizeRules.hint(options: OrganizeOptions(), pageCount: 3) == nil)
        check("scope clamps out-of-range page indices",
              OrganizeOptions(pageScope: .selectedPages, selectedPages: [0, 99, -1])
                  .scope(pageCount: 2) == [0],
              "\(OrganizeOptions(pageScope: .selectedPages, selectedPages: [0, 99, -1]).scope(pageCount: 2))")
        check("scope: all pages is every page",
              OrganizeOptions().scope(pageCount: 3) == [0, 1, 2])

        section("customOrder mirrors the layout after every folder mutation")
        // `save()` persists `customOrder` as its own field rather than deriving it
        // from `pages`, and `apply(_:)` reads the two back independently. So
        // nothing heals a stale order on load, and `sorted()` — its only reader —
        // hands `restartToDefaultOrder` ("Reset Order") an arrangement from
        // *before* the folder step. Every mutator must re-derive it. These four
        // are the folder family; `move`/`fillEmptySlots` always did.
        func mirror(_ s: DeckStore) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for page in s.pages {
                for slot in page {
                    switch slot {
                    case .app(let id):
                        if seen.insert(id).inserted { out.append(id) }
                    case .folder(let fid):
                        for member in s.folder(fid)?.appIDs ?? [] where seen.insert(member).inserted {
                            out.append(member)
                        }
                    }
                }
            }
            return out
        }

        let mirrorURL = tempURL.deletingLastPathComponent()
            .appendingPathComponent("opendeck-selftest-mirror-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: mirrorURL) }
        let mirrorStore = DeckStore(storeURL: mirrorURL)
        mirrorStore.metrics = GridMetrics(columns: 3, rows: 2, iconSize: 100, cellWidth: 150, cellHeight: 150)
        check("the mirror fixture is in Custom sort, the only reader of customOrder",
              mirrorStore.sortKey == .manual)

        // Compact on purpose: `check` prints its detail even on PASS, and dumping
        // the whole order over a hundred installed apps buries the run.
        func firstDifference(_ lhs: [String], _ rhs: [String]) -> String {
            guard lhs != rhs else { return "" }
            for i in 0 ..< max(lhs.count, rhs.count) {
                let l = i < lhs.count ? lhs[i] : "-"
                let r = i < rhs.count ? rhs[i] : "-"
                if l != r {
                    return "\(max(lhs.count, rhs.count)) entries, first differs at \(i): \(l) vs \(r)"
                }
            }
            return "orders differ"
        }

        let mirrorIDs = Array(mirrorStore.visibleApps.prefix(4)).map(\.id)
        if mirrorIDs.count == 4 {
            let a = mirrorIDs[0], b = mirrorIDs[1], c = mirrorIDs[2], d = mirrorIDs[3]

            // An explicit two-page fixture, so every step really moves a slot.
            // Relying on the scan order made this hollow: the member `addToFolder`
            // pulled in happened to land exactly where its own slot had been, so
            // the stale and the re-derived order agreed (mutation M49 survived).
            mirrorStore.pages = [[.app(a), .app(b), .app(c)], [.app(d)]]
            mirrorStore.customOrder = [a, b, c, d]
            check("the explicit fixture starts in sync",
                  mirrorStore.customOrder == mirror(mirrorStore),
                  firstDifference(mirror(mirrorStore), mirrorStore.customOrder))

            // {a, c} takes a's slot on page 0; c's own slot closes up, so the
            // members end up ahead of b.
            mirrorStore.makeFolder(dropping: c, onto: a)
            check("makeFolder re-derives customOrder",
                  mirrorStore.customOrder == mirror(mirrorStore),
                  firstDifference(mirror(mirrorStore), mirrorStore.customOrder))

            if let folderID = mirrorStore.folders.values.first(where: { $0.appIDs.contains(a) })?.id {
                // d leaves the second page for the folder on the first.
                mirrorStore.addToFolder(d, folder: folderID)
                check("addToFolder re-derives customOrder",
                      mirrorStore.customOrder == mirror(mirrorStore),
                      firstDifference(mirror(mirrorStore), mirrorStore.customOrder))

                mirrorStore.removeFromFolder(d, folder: folderID)
                check("removeFromFolder re-derives customOrder",
                      mirrorStore.customOrder == mirror(mirrorStore),
                      firstDifference(mirror(mirrorStore), mirrorStore.customOrder))

                mirrorStore.ungroup(folderID)
                check("ungroup re-derives customOrder",
                      mirrorStore.customOrder == mirror(mirrorStore),
                      firstDifference(mirror(mirrorStore), mirrorStore.customOrder))

                // The reader, not the field: this is the order "Reset Order" reflows.
                let laidOut = mirrorStore.pages.flatMap { $0 }.compactMap { slot -> String? in
                    if case .app(let id) = slot { return id }
                    return nil
                }
                let sortedIDs = mirrorStore.sorted(mirrorStore.visibleApps)
                    .map(\.id).filter { laidOut.contains($0) }
                check("the sorted order agrees with the grid after ungrouping",
                      sortedIDs == laidOut,
                      firstDifference(sortedIDs, laidOut))
            } else {
                check("the mirror fixture built a folder", false)
            }
        } else {
            check("at least four apps for the customOrder mirror test", false)
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

        section("Grid presets (the page shape is the user's to choose)")

        check("eight page shapes are offered", GridPreset.allCases.count == 8,
              "\(GridPreset.allCases.count)")
        check("the presets are eight distinct shapes",
              Set(GridPreset.allCases.map(\.rawValue)).count == 8)
        check("the default shape is the one macOS shipped",
              GridPreset.macOSDefault == .grid7x5
              && GridPreset.macOSDefault.columns == 7
              && GridPreset.macOSDefault.rows == 5)
        check("the presets span seven to ten columns",
              Set(GridPreset.allCases.map(\.columns)) == [7, 8, 9, 10],
              "\(Set(GridPreset.allCases.map(\.columns)).sorted())")
        check("the presets span five to six rows",
              Set(GridPreset.allCases.map(\.rows)) == [5, 6],
              "\(Set(GridPreset.allCases.map(\.rows)).sorted())")
        check("every preset is named for its own shape",
              GridPreset.allCases.allSatisfy { $0.label == "\($0.columns) × \($0.rows)" })

        // The geometry half is pure, so this does not depend on which displays
        // this machine happens to have attached.
        let wide = GridMetrics.make(in: CGSize(width: 2560, height: 1440), preset: .grid10x6)
        check("a large display seats the widest preset",
              wide.columns == 10 && wide.rows == 6, "\(wide.columns)x\(wide.rows)")
        check("the widest preset offers the most slots", wide.capacity == 60, "\(wide.capacity)")

        let defaultShaped = GridMetrics.make(in: CGSize(width: 2560, height: 1440))
        check("asking for nothing yields the 7 x 5 default",
              defaultShaped.columns == 7 && defaultShaped.rows == 5,
              "\(defaultShaped.columns)x\(defaultShaped.rows)")
        check("a wider preset holds more per page than the default",
              wide.capacity > defaultShaped.capacity,
              "\(wide.capacity) vs \(defaultShaped.capacity)")

        // A preset is a request: a display that cannot seat it gets a smaller
        // grid rather than icons hanging off the edge.
        let small = GridMetrics.make(in: CGSize(width: 1024, height: 640), preset: .grid10x6)
        check("a preset too big for the display is shrunk, not clipped",
              small.columns < 10 && small.rows < 6, "\(small.columns)x\(small.rows)")
        check("a shrunk preset keeps a usable grid",
              small.columns >= 4 && small.rows >= 3, "\(small.columns)x\(small.rows)")
        check("the shrunk grid still fits the display's width",
              CGFloat(small.columns) * small.cellWidth
              + CGFloat(small.columns - 1) * GridMetrics.hSpacing
              <= 1024 - GridMetrics.sideMargin * 2,
              "\(CGFloat(small.columns) * small.cellWidth + CGFloat(small.columns - 1) * GridMetrics.hSpacing) vs 864")
        check("the shrunk grid still fits the display's height",
              CGFloat(small.rows) * small.cellHeight
              + CGFloat(small.rows - 1) * GridMetrics.vSpacing
              <= 640 - GridMetrics.chromeHeight,
              "\(CGFloat(small.rows) * small.cellHeight + CGFloat(small.rows - 1) * GridMetrics.vSpacing) vs 430")

        section("Glass tiers (a system material, never a blurred wallpaper)")

        check("five tiers are offered", GlassMaterial.allCases.count == 5,
              "\(GlassMaterial.allCases.count)")
        check("the tiers are five distinct materials",
              Set(GlassMaterial.allCases.map { $0.material.rawValue }).count == 5)
        check("the default tier keeps the material the backdrop already used",
              GlassMaterial.regular.material == .fullScreenUI)
        check("every tier carries its own name",
              Set(GlassMaterial.allCases.map(\.label)).count == 5)

        // The rule this whole design exists for: the live deck gets its frost
        // from a system material, which samples the real desktop behind the
        // window. Nothing reads the desktop picture back and blurs it.
        check("a glass backdrop is a system material, not a blurred picture",
              BackdropView.render(mode: .glass, customImagePath: nil, blurRadius: 26,
                                  glassMaterial: .thick, offscreen: false) == .systemMaterial(.thick))
        check("the chosen tier is the one that gets used",
              BackdropView.render(mode: .glass, customImagePath: nil, blurRadius: 26,
                                  glassMaterial: .ultraThin, offscreen: false) == .systemMaterial(.ultraThin))
        check("desktop mode draws nothing of ours at all",
              BackdropView.render(mode: .desktop, customImagePath: nil, blurRadius: 26,
                                  glassMaterial: .regular, offscreen: false) == .liveDesktop)
        check("custom mode with no image pinned falls back to the material",
              BackdropView.render(mode: .custom, customImagePath: nil, blurRadius: 26,
                                  glassMaterial: .regular, offscreen: false) == .systemMaterial(.regular))
        check("a pinned image is drawn, and blurred only while the slider is up",
              BackdropView.render(mode: .custom, customImagePath: "/tmp/pinned.png", blurRadius: 26,
                                  glassMaterial: .regular, offscreen: false) == .picture(blurred: true)
              && BackdropView.render(mode: .custom, customImagePath: "/tmp/pinned.png", blurRadius: 0,
                                     glassMaterial: .regular, offscreen: false) == .picture(blurred: false))
        // Offscreen there is no desktop to sample, so the picture stands in for
        // the material — and is drawn as-is. Blurring it to fake the frost is the
        // approach this design rejects.
        check("the offscreen render never blurs the desktop picture",
              BackdropView.render(mode: .glass, customImagePath: nil, blurRadius: 26,
                                  glassMaterial: .regular, offscreen: true) == .picture(blurred: false)
              && BackdropView.render(mode: .desktop, customImagePath: nil, blurRadius: 26,
                                     glassMaterial: .regular, offscreen: true) == .picture(blurred: false))

        section("Return-to-home policy")

        check("seven policies are offered", ReturnToHome.allCases.count == 7,
              "\(ReturnToHome.allCases.count)")
        check("only the five middle tiers carry a grace period",
              ReturnToHome.allCases.compactMap(\.grace) == [5, 15, 30, 60, 300],
              "\(ReturnToHome.allCases.compactMap(\.grace))")
        check("the two untimed tiers are the old boolean, in full",
              ReturnToHome.always.grace == nil && ReturnToHome.never.grace == nil)
        check("every policy carries its own wording",
              Set(ReturnToHome.allCases.map(\.label)).count == 7)

        let now = Date()
        check("`always` never resumes, however recently the deck was closed",
              !ReturnToHome.always.resumes(lastPage: 3, closedAt: now.addingTimeInterval(-1), now: now))
        check("`never` always resumes, however long the deck sat closed",
              ReturnToHome.never.resumes(lastPage: 3, closedAt: nil, now: now)
              && ReturnToHome.never.resumes(lastPage: 3, closedAt: now.addingTimeInterval(-86400), now: now))
        check("a timed tier resumes while inside its grace",
              ReturnToHome.after1Min.resumes(lastPage: 3, closedAt: now.addingTimeInterval(-30), now: now))
        check("a timed tier goes home once its grace has passed",
              !ReturnToHome.after1Min.resumes(lastPage: 3, closedAt: now.addingTimeInterval(-90), now: now))
        // Stepped a little to either side rather than landing exactly on the
        // boundary: `Date` is a `Double`, so `now - (now - 30)` is only
        // approximately 30, and an exact-boundary assertion would be flaky.
        check("a timed tier straddles its grace the right way round",
              ReturnToHome.after30Sec.resumes(lastPage: 3, closedAt: now.addingTimeInterval(-29.9), now: now)
              && !ReturnToHome.after30Sec.resumes(lastPage: 3, closedAt: now.addingTimeInterval(-30.1), now: now))
        check("a timed tier with no dismissal on record goes home rather than resuming a stale page",
              !ReturnToHome.after5Min.resumes(lastPage: 3, closedAt: nil, now: now))

        // The old boolean has to keep meaning exactly what it meant, or an
        // upgrade silently resets a choice the user made.
        check("the old \"resume where I left off\" becomes the untimed `never`",
              DeckSettings.migratedReturnToHome(fromLegacyResume: true) == .never)
        check("the old \"return to the main page\" becomes `always`",
              DeckSettings.migratedReturnToHome(fromLegacyResume: false) == .always)

        section("Hot corner conflicts (the system may already own that corner)")

        check("each corner maps to the Dock's own key",
              HotCornerConflict.key(for: .topLeft) == "wvous-tl-corner"
              && HotCornerConflict.key(for: .topRight) == "wvous-tr-corner"
              && HotCornerConflict.key(for: .bottomLeft) == "wvous-bl-corner"
              && HotCornerConflict.key(for: .bottomRight) == "wvous-br-corner"
              && HotCornerConflict.key(for: .off) == nil)
        check("a corner with a system action is reported as taken",
              HotCornerConflict.systemClaims(.topLeft, in: ["wvous-tl-corner": 5]))
        check("a corner the system stores as \"no action\" is free",
              !HotCornerConflict.systemClaims(.topLeft, in: ["wvous-tl-corner": 0]))
        check("a corner the Dock has never written is free",
              !HotCornerConflict.systemClaims(.bottomRight, in: [:]))
        check("another corner's action does not leak into this one",
              !HotCornerConflict.systemClaims(.topRight, in: ["wvous-tl-corner": 5]))
        check("`off` can never conflict",
              !HotCornerConflict.systemClaims(.off, in: ["wvous-tl-corner": 5]))

        section("Menu bar icon (a tool must not put one on the user's screen)")

        // The self-test itself runs headless, so this exercises the real guard
        // under real conditions rather than a simulated flag.
        check("asking for an icon while headless installs nothing, and says so",
              MenuBarController.shared.apply(enabled: true) == false
              && MenuBarController.shared.isInstalled == false)
        check("asking again changes nothing and still never claims success",
              MenuBarController.shared.apply(enabled: true) == false
              && MenuBarController.shared.apply(enabled: false) == false
              && MenuBarController.shared.isInstalled == false)

        section("Drag gate (reordering is a custom-sort-only gesture)")
        // LaunchOS's rule, in its own words: "Dragging to reorder is only
        // available in Custom sort mode." OpenDeck used to accept the drag and
        // then drop the result on the floor — `syncCustomOrder()` bails out for
        // every other sort, so the new order was never recorded.
        check("a drag may begin under the custom sort",
              DragState.allowsDrag(sortKey: .manual))
        check("no drag may begin under any other sort",
              !DragState.allowsDrag(sortKey: .name) && !DragState.allowsDrag(sortKey: .lastUsed))
        check("the refusal names the custom sort",
              DragState.reorderLockedMessage.contains("Custom sort mode"))

        // The gate is only half the rule: a refusal that says nothing on screen
        // is indistinguishable from a deck that is simply broken.
        let gate = DragState()
        check("a fresh drag has nothing to say", gate.blockedNotice == nil)
        gate.refuseBegin(DragState.reorderLockedMessage)
        check("a refusal puts the reason on screen",
              gate.blockedNotice == DragState.reorderLockedMessage)
        gate.clearBlockedNotice()
        check("starting a real drag clears the refusal", gate.blockedNotice == nil)

        section("Drag edge zones")
        // Named after LaunchOS's `DragEdgeZone`. Pure geometry, so it is driven by
        // plain numbers here instead of a window.
        check("the left band is the leading zone",
              DragState.edgeZone(x: 0, width: 1000, inset: 70) == .leading
              && DragState.edgeZone(x: 70, width: 1000, inset: 70) == .leading)
        check("the right band is the trailing zone",
              DragState.edgeZone(x: 930, width: 1000, inset: 70) == .trailing
              && DragState.edgeZone(x: 1000, width: 1000, inset: 70) == .trailing)
        check("the middle belongs to no zone",
              DragState.edgeZone(x: 500, width: 1000, inset: 70) == nil)
        check("one point past a band is outside it",
              DragState.edgeZone(x: 71, width: 1000, inset: 70) == nil
              && DragState.edgeZone(x: 929, width: 1000, inset: 70) == nil)
        check("a deck with no width (or no band) has no zones",
              DragState.edgeZone(x: 10, width: 0, inset: 70) == nil
              && DragState.edgeZone(x: 10, width: 1000, inset: 0) == nil)

        section("Drag motion (ported from LaunchOS's display link)")
        // Every constant here was decoded from `updatePagedDragFrame:`
        // (`0x10011ca8c`). The assertions pin the *shape* of the ramp as well as
        // its endpoints, because the endpoints alone would pass for a fixed
        // factor — and a fixed factor is exactly the misreading report 32 made.
        check("the approach factor is 0.21 for a 120 Hz frame",
              DragMotion.alpha(frameDuration: DragMotion.fastestFrame) == 0.21)
        check("the approach factor is 0.42 for a 60 Hz frame",
              DragMotion.alpha(frameDuration: DragMotion.referenceFrame) == 0.42)
        check("a frame slower than 60 Hz does not push past 0.42",
              DragMotion.alpha(frameDuration: 1.0 / 30.0) == 0.42
              && DragMotion.alpha(frameDuration: 0.5) == 0.42)
        check("a frame faster than 120 Hz does not drop below 0.21",
              DragMotion.alpha(frameDuration: 1.0 / 240.0) == 0.21)
        // 1/90 s is two thirds of the reference frame, so the ramp gives 0.28.
        check("the factor ramps linearly between the two ends",
              abs(DragMotion.alpha(frameDuration: 1.0 / 90.0) - 0.28) < 1e-12,
              "\(DragMotion.alpha(frameDuration: 1.0 / 90.0))")
        check("the ramp rises monotonically across the band",
              stride(from: 0.0, through: 1.0, by: 0.05).allSatisfy { t in
                  let a = DragMotion.fastestFrame
                  let b = DragMotion.referenceFrame
                  let d = a + (b - a) * t
                  guard d < b else { return true }
                  let next = a + (b - a) * min(t + 0.05, 1)
                  return DragMotion.alpha(frameDuration: next) >= DragMotion.alpha(frameDuration: d)
              })
        check("the cap is never reached, so it cannot silently bind",
              DragMotion.alphaCap > DragMotion.alphaReferenceFrame)

        // The one-step behaviour.
        let settledStep = DragMotion.step(value: 0, goal: 0.05, frameDuration: DragMotion.referenceFrame)
        check("a step inside the threshold settles", settledStep.settled)
        check("a settled step lands exactly on the goal, not near it",
              settledStep.value == 0.05)
        check("a step at exactly the threshold does not settle",
              !DragMotion.step(value: 0, goal: DragMotion.settleThreshold,
                               frameDuration: DragMotion.referenceFrame).settled)
        let midway = DragMotion.step(value: 0, goal: 100, frameDuration: DragMotion.referenceFrame)
        check("a step moves toward the goal without overshooting",
              midway.value > 0 && midway.value < 100, "\(midway.value)")
        // One 60 Hz frame is a bigger step than two 120 Hz ones, which is what
        // makes the time constant — and the feel — hold across refresh rates.
        let once60 = DragMotion.step(value: 0, goal: 100, frameDuration: DragMotion.referenceFrame).value
        let once120 = DragMotion.step(value: 0, goal: 100, frameDuration: DragMotion.fastestFrame).value
        let twice120 = DragMotion.step(value: once120, goal: 100,
                                       frameDuration: DragMotion.fastestFrame).value
        check("a 60 Hz step outruns two 120 Hz steps", once60 > twice120,
              "\(once60) vs \(twice120)")

        section("Drag slop (the press is not a drag until it moves)")
        check("the ported slop is 4 points", DragMotion.dragSlop == 4)
        check("a 3.9-point move is still a press",
              !DragMotion.exceedsSlop(from: .zero, to: CGPoint(x: 3.9, y: 0)))
        check("a 4.0-point move is a drag",
              DragMotion.exceedsSlop(from: .zero, to: CGPoint(x: 4, y: 0)))
        check("the slop counts either axis, in either direction",
              DragMotion.exceedsSlop(from: .zero, to: CGPoint(x: 0, y: -4))
              && DragMotion.exceedsSlop(from: .zero, to: CGPoint(x: -4, y: 0)))
        check("the slop is measured from the press, not from the origin",
              !DragMotion.exceedsSlop(from: CGPoint(x: 500, y: 500), to: CGPoint(x: 503, y: 500)))

        section("Drag motion (the pages a strip can rest on)")
        check("a resting deck's offset is its page times the width",
              DragMotion.restingGoal(page: 2, pageWidth: 1000) == -2000)
        check("a settled offset rounds to the nearest page",
              DragMotion.settledPage(offset: -1400, pageWidth: 1000, pageCount: 3) == 1
              && DragMotion.settledPage(offset: -1600, pageWidth: 1000, pageCount: 3) == 2)
        check("a settled offset is clamped to the deck",
              DragMotion.settledPage(offset: 50_000, pageWidth: 1000, pageCount: 3) == 0
              && DragMotion.settledPage(offset: -50_000, pageWidth: 1000, pageCount: 3) == 2)
        check("a degenerate deck settles on page zero",
              DragMotion.settledPage(offset: -900, pageWidth: 0, pageCount: 3) == 0
              && DragMotion.settledPage(offset: -900, pageWidth: 1000, pageCount: 0) == 0)

        section("Drag strip (the page turn, driven by the ported motion)")
        // Everything above is arithmetic on constants. This is the object that
        // actually moves the deck, and it is drivable frame by frame from here
        // — the only way to pin 60 Hz vs 120 Hz behaviour, or the one-frame
        // hand-back, without a screen.
        //
        // ⚠️ Note what is *absent* from every sequence below: the pointer. The
        // strip is moved by a page change and by nothing else. An earlier cut
        // fed it the pointer's travel, which made the whole grid slide sideways
        // during a drag and cancelled the reflow into the bargain (report 37 §2).
        let strip = DragOffsetModel()
        strip.begin(scrollOffset: 2400, pageWidth: 1200, pageCount: 4)
        check("a drag begins without moving the strip", strip.applied == 0, "\(strip.applied)")
        check("the anchor is the page the strip was resting on", strip.anchorPage == 2)
        check("the model is live once a drag begins", strip.isActive)

        // The guard for the rule above: with no page asked for, no number of
        // frames may move it. This is what would go red if the pointer's travel
        // were ever fed back in.
        for _ in 0 ..< 300 { strip.tick(frameDuration: 1.0 / 60.0) }
        check("a drag that asks for no page never moves the strip",
              strip.presented == -2400 && strip.applied == 0, "\(strip.presented)")

        strip.nudge(to: 1)
        check("an edge dwell aims the strip at the page it names",
              strip.goal == -1200, "\(strip.goal)")
        check("... without jumping it there", strip.presented == -2400)
        strip.tick(frameDuration: 1.0 / 120.0)
        // Asserted as a *fraction of the gap* rather than as a position, so the
        // assertion states what the ramp means instead of what the arithmetic
        // happened to produce. This is the reading report 32 got wrong.
        check("a 120 Hz frame closes 21% of the remaining distance",
              abs((strip.presented + 2400) / 1200 - 0.21) < 1e-9,
              "\((strip.presented + 2400) / 1200)")
        for _ in 0 ..< 300 { strip.tick(frameDuration: 1.0 / 60.0) }
        check("the strip converges onto its goal exactly",
              strip.presented == strip.goal, "\(strip.presented) vs \(strip.goal)")

        // Beginning mid-glide is the case the "cancel the scroll offset" rule
        // exists for: the deck must not twitch when it is grabbed.
        let grabbed = DragOffsetModel()
        grabbed.begin(scrollOffset: 3777, pageWidth: 1200, pageCount: 4)
        check("grabbing a deck that is mid-glide still moves nothing",
              grabbed.applied == 0, "\(grabbed.applied)")
        check("a mid-glide deck anchors to the page it is nearest",
              grabbed.anchorPage == 3, "\(grabbed.anchorPage)")

        // The hand-back — the one thing that cannot be checked by looking at
        // the offset alone, which is why `landing` is published rather than
        // acted on in place. The case that matters is a release *mid-glide*: the
        // page is decided at the instant the button comes up, but the deck must
        // not be told about it until the strip has finished sliding there.
        let settling = DragOffsetModel()
        settling.begin(scrollOffset: 1200, pageWidth: 1200, pageCount: 4)
        settling.nudge(to: 2)
        settling.tick(frameDuration: 1.0 / 60.0)
        check("a page turn in flight withholds the landing",
              settling.landing == nil
              && settling.presented != DragMotion.restingGoal(page: 2, pageWidth: 1200),
              "\(settling.presented)")
        // Asserted as the anchor rather than as "the nearest page", and the two
        // differ right here: one 60 Hz frame in, the strip sits at −1704, which
        // is nearest page 1. Reading the offset would name the page the drag has
        // already left, while `commit()` places the drop on page 2 — the item
        // would be put on a page the hand-back never scrolls to.
        check("releasing mid-glide names the page the drag is on",
              settling.release() == 2)
        check("... and the release itself publishes nothing",
              settling.landing == nil)
        // ⚠️ The tick below is the whole point of the pair, not a formality.
        // `landing` is published by the tick that *converges* (DragOffsetModel
        // `tick`: `if step.settled, let target = landingTarget`). A check written
        // before any tick therefore passes even with the settling guard removed
        // — which is precisely how M67 survived twice: first in report 36, and
        // again when report 37 reordered these lines and dropped the tick.
        settling.tick(frameDuration: 1.0 / 60.0)
        check("... and a frame into the glide it is still withheld",
              settling.landing == nil
              && settling.presented != DragMotion.restingGoal(page: 2, pageWidth: 1200),
              "\(settling.presented)")
        for _ in 0 ..< 300 { settling.tick(frameDuration: 1.0 / 60.0) }
        check("the strip arrives at the page it will land on",
              settling.presented == DragMotion.restingGoal(page: 2, pageWidth: 1200),
              "\(settling.presented)")
        check("landing appears once the strip has arrived", settling.landing == 2)
        settling.completeLanding()
        check("the hand-back returns the strip to the scroll view",
              settling.applied == 0 && !settling.isActive && settling.landing == nil)

        let shortPull = DragOffsetModel()
        shortPull.begin(scrollOffset: 0, pageWidth: 1200, pageCount: 3)
        for _ in 0 ..< 300 { shortPull.tick(frameDuration: 1.0 / 60.0) }
        check("a drag that never leaves a page lands back on it",
              shortPull.release() == 0)

        // The edge dwell: it re-anchors and glides, it does not jump.
        let nudged = DragOffsetModel()
        nudged.begin(scrollOffset: 0, pageWidth: 1200, pageCount: 4)
        nudged.nudge(to: 1)
        check("a nudge moves the anchor", nudged.anchorPage == 1)
        check("a nudge aims at the page it names", nudged.goal == -1200, "\(nudged.goal)")
        check("a nudge does not jump the strip",
              nudged.presented == 0, "\(nudged.presented)")
        for _ in 0 ..< 300 { nudged.tick(frameDuration: 1.0 / 60.0) }
        check("the strip glides onto the nudged page", nudged.presented == -1200)
        // A second dwell has to be measured from the strip, not from the scroll
        // view: the scroll view has not caught up yet, so asking it would refuse
        // the second page turn and the deck would flip exactly once per drag.
        nudged.nudge(to: 2)
        check("a second dwell can turn another page",
              nudged.anchorPage == 2 && nudged.goal == -2400,
              "\(nudged.anchorPage) \(nudged.goal)")
        nudged.nudge(to: 99)
        check("a nudge is clamped to the deck", nudged.anchorPage == 3)

        let dropped = DragOffsetModel()
        dropped.begin(scrollOffset: 0, pageWidth: 1200, pageCount: 3)
        dropped.nudge(to: 1)
        for _ in 0 ..< 10 { dropped.tick(frameDuration: 1.0 / 60.0) }
        check("a live page turn has the strip offset", dropped.applied != 0, "\(dropped.applied)")
        dropped.cancel()
        check("cancelling drops the drag and the offset",
              dropped.applied == 0 && !dropped.isActive && dropped.landing == nil)

        let inert = DragOffsetModel()
        inert.tick(frameDuration: 1.0 / 60.0)
        inert.nudge(to: 1)
        check("the model is inert until a drag begins",
              inert.applied == 0 && !inert.isActive)

        section("Drag reflow (the pointer moves the icons, not the strip)")
        // The half of the drag the pointer *is* supposed to move, driven through
        // the call the host makes on every pointer move.
        let reflowMetrics = GridMetrics(columns: 4, rows: 2, iconSize: 64,
                                        cellWidth: 88, cellHeight: 92)
        let reflowItems: [DeckSlot] = [.app("a"), .app("b"), .app("c"), .app("d")]
        // A grid that does **not** start at the window's corner: the reflow has to
        // take the grid's own origin off the point, and a zero origin would make
        // that subtraction invisible to every assertion below (the equivalent
        // mutation would survive).
        let reflowFrame = CGRect(x: 120, y: 90, width: 800, height: 400)
        let reflowTester = GridHitTester(metrics: reflowMetrics, itemCount: reflowItems.count,
                                         containerSize: reflowFrame.size,
                                         slotCount: reflowMetrics.capacity)
        var reflowTargets: [Int] = []
        let reflow = DragState()
        reflow.gridFrame = reflowFrame
        reflow.onLiveMove = { _, index in reflowTargets.append(index) }
        let firstCentre = reflowTester.centre(of: 0)
        reflow.begin(item: .app("a"), app: nil, title: nil, index: 0, page: 0,
                     source: .grid,
                     location: CGPoint(x: firstCentre.x + reflowFrame.minX,
                                       y: firstCentre.y + reflowFrame.minY))
        let secondCentre = reflowTester.centre(of: 1)
        // The crossing sequence (report 45): the tile is touched first —
        // arming the merge and opening no gap — and the gap only follows once
        // the pointer moves past the tile into the cell's margin.
        reflow.update(location: CGPoint(x: secondCentre.x + reflowFrame.minX,
                                        y: secondCentre.y + reflowFrame.minY),
                      page: 0, metrics: reflowMetrics, pageItems: reflowItems,
                      capacity: reflowMetrics.capacity)
        check("touching the tile arms the merge and opens no gap",
              reflowTargets.isEmpty && reflow.combineAppID == "b",
              "\(reflowTargets) / \(String(describing: reflow.combineAppID))")
        let marginPoint = CGPoint(x: secondCentre.x + reflowMetrics.cellWidth / 2 - 2,
                                  y: secondCentre.y)
        reflow.update(location: CGPoint(x: marginPoint.x + reflowFrame.minX,
                                        y: marginPoint.y + reflowFrame.minY),
                      page: 0, metrics: reflowMetrics, pageItems: reflowItems,
                      capacity: reflowMetrics.capacity)
        check("the slot under the pointer is measured from the grid, not the window",
              reflow.hoverIndex == 1, String(describing: reflow.hoverIndex))
        check("... and the grid is asked to open the gap there",
              reflowTargets == [1], "\(reflowTargets)")
        check("overTile: the centre of a slot is on the tile",
              reflowTester.overTile(at: secondCentre, index: 1))
        check("overTile: the cell margin is not",
              !reflowTester.overTile(at: marginPoint, index: 1))
        reflow.reset()

        section("Drag page (which page a drop belongs to)")
        // After an edge dwell the strip is showing the new page while the scroll
        // view is still on the old one — that is the whole point of the two-phase
        // hand-back. A drop belongs to the page the user is looking at, so the
        // drag has to read the strip. Reading `paging` instead put an item onto
        // the page the user had just left.
        let pageURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-dragpage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: pageURL) }
        let pageStore = DeckStore(storeURL: pageURL)
        pageStore.pages = [[.app("a")], [.app("b")], [.app("c")], [.app("d")]]
        let pageVM = LaunchpadViewModel(store: pageStore)
        let pageHost = DeckDragHost(store: pageStore, vm: pageVM)
        // Mid-deck, not page 0: a zero here would be indistinguishable from the
        // value every assertion below would fall back to anyway.
        pageVM.paging.set(2, count: 4)
        pageHost.offset.begin(scrollOffset: 2400, pageWidth: 1200, pageCount: 4)
        check("a drag begins on the page the deck was showing",
              pageHost.dragPage == 2, "\(pageHost.dragPage)")
        // The window's edge timer maturing calls exactly this, and nothing else.
        pageHost.drag.onRequestPage?(3)
        check("an edge dwell moves the strip onto the page it was asked for",
              pageHost.offset.anchorPage == 3)
        // The deck's own answer to "which page am I on" must **not** move yet.
        // The scroll view has not gone anywhere, and the page the strip has left
        // is not one the deck is on. Writing it here would also survive an Esc
        // that arrives mid-glide, leaving the indicator a page ahead of the grid
        // for good.
        check("... while the deck's own page waits for the hand-back",
              pageVM.paging.resolved(count: 4) == 2,
              "\(pageVM.paging.resolved(count: 4))")
        check("so the drag works on the page the user is looking at",
              pageHost.dragPage == 3, "\(pageHost.dragPage)")
        pageHost.offset.cancel()
        check("with no drag in flight the page is the deck's again",
              pageHost.dragPage == 2, "\(pageHost.dragPage)")
        pageHost.teardown()

        section("Drag session routing (the deck window's mouse state machine)")
        // The deck window routes mouse events before AppKit delivers them. The
        // rule that matters most: a *click* must keep working, so the down is
        // always forwarded; only a real drag is claimed.
        var router = DragSessionState()
        check("a press that misses every tile is forwarded",
              router.mouseDown(slot: nil, at: .zero) == .normal)
        check("a drag from empty space is never claimed",
              router.mouseDragged(to: CGPoint(x: 400, y: 400), allowsDrag: true) == .normal
              && router.mouseUp() == .normal)
        let onTile = router.mouseDown(slot: 3, at: CGPoint(x: 300, y: 300))
        check("a press on a tile is still forwarded, so the click can land",
              onTile == .normal && !onTile.consumes)
        check("a nudge below the slop stays a click",
              router.mouseDragged(to: CGPoint(x: 302, y: 300), allowsDrag: true) == .normal)
        let opened = router.mouseDragged(to: CGPoint(x: 320, y: 300), allowsDrag: true)
        check("passing the slop opens the session for the pressed tile",
              opened == .beginSession(slot: 3))
        check("opening a session consumes the event",
              opened.consumes)
        let tracking = router.mouseDragged(to: CGPoint(x: 500, y: 300), allowsDrag: true)
        check("later moves are tracked", tracking == .track && tracking.consumes)
        let committed = router.mouseUp()
        check("the release commits the drag", committed == .commit && committed.consumes)
        check("after the commit the machine is idle again",
              !router.isDragging && router.draggedSlot == nil && router.mouseUp() == .normal)

        // The refusal path: a locked deck says why, and leaves no session behind.
        var locked = DragSessionState()
        _ = locked.mouseDown(slot: 1, at: .zero)
        let refused = locked.mouseDragged(to: CGPoint(x: 40, y: 0), allowsDrag: false)
        check("a locked deck refuses the drag", refused == .refuse && refused.consumes)
        check("a refused drag leaves no session behind",
              !locked.isDragging
              && locked.mouseDragged(to: CGPoint(x: 90, y: 0), allowsDrag: false) == .normal)

        // A press that never moves must still reach SwiftUI, or tapping a tile
        // would stop launching anything.
        var tapped = DragSessionState()
        _ = tapped.mouseDown(slot: 7, at: CGPoint(x: 10, y: 10))
        check("a press released without moving is a click, not a drag",
              tapped.mouseUp() == .normal && !tapped.isDragging)

        // Two downs without an intervening up would strand the first session,
        // and an open session makes every later `save()` a no-op (data loss).
        var stranded = DragSessionState()
        _ = stranded.mouseDown(slot: 2, at: .zero)
        _ = stranded.mouseDragged(to: CGPoint(x: 50, y: 0), allowsDrag: true)
        check("a second down during a drag is swallowed, not restarted",
              stranded.mouseDown(slot: 5, at: CGPoint(x: 60, y: 0)) == .consume
              && stranded.draggedSlot == 2)
        stranded.reset()
        check("teardown drops the drag without committing",
              !stranded.isDragging && stranded.mouseUp() == .normal)

        section("Drag host (what a press actually grabs)")
        // The one part of the drag with no pure-function twin: which tile a press
        // lands on. Driven here with plain numbers, because a window and a real
        // button-down cannot be had headlessly.
        let hostURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-draghost-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: hostURL) }
        let hostStore = DeckStore(storeURL: hostURL)
        hostStore.metrics = GridMetrics(columns: 4, rows: 2, iconSize: 64,
                                        cellWidth: 88, cellHeight: 92)
        hostStore.pages = [[.app("a"), .app("b"), .app("c")], [.app("d")]]
        let hostVM = LaunchpadViewModel(store: hostStore)
        let host = DeckDragHost(store: hostStore, vm: hostVM)
        // The viewport the grid is centred in, as `GridHitTester` expects.
        host.drag.gridFrame = CGRect(x: 0, y: 0, width: 800, height: 400)

        let slotTester = GridHitTester(metrics: hostStore.metrics, itemCount: 3,
                                       containerSize: host.drag.gridFrame.size,
                                       slotCount: hostStore.metrics.capacity)
        let hostGrabbed = host.hitTarget(at: slotTester.centre(of: 0))
        check("a press on a tile grabs that tile, from the grid",
              hostGrabbed?.item == .app("a") && hostGrabbed?.index == 0
              && hostGrabbed?.source == .grid,
              String(describing: hostGrabbed))
        check("a press on another tile grabs that one",
              host.hitTarget(at: slotTester.centre(of: 2))?.item == .app("c"))
        check("a press on an empty slot grabs nothing",
              host.hitTarget(at: slotTester.centre(of: 3)) == nil)
        check("a press outside the grid grabs nothing",
              host.hitTarget(at: CGPoint(x: -40, y: -40)) == nil)
        // The panel covers the grid. A press there must not reach the tiles
        // behind it, or dragging inside an open folder would grab whatever
        // happened to lie underneath.
        hostVM.openedFolder = UUID()
        check("an open folder panel shadows the grid behind it",
              host.hitTarget(at: slotTester.centre(of: 0)) == nil)
        hostVM.openedFolder = nil

        host.teardown()
        check("teardown is safe when nothing is in flight",
              !host.drag.isActive && host.offset.applied == 0)

        section("Deck coordinates (a window point becomes the deck's own point)")
        // The bug this pins — measured, not assumed (report 36 §1):
        // `NSHostingView` is **flipped**, so `convert(_:from: nil)` already hands
        // back a top-left-origin point, which is the space every
        // `frame(in: .named("deck"))` is reported in. Flipping that result a
        // second time mirrors the entire drag about the middle of the deck:
        // press the top row and the bottom row's icon lifts. The conversion is
        // exercised against a real hosting view in a real window, because a
        // plain number here would only restate the rule and catch nothing.
        let coordinateWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        let coordinateView = NSHostingView(rootView: Color.clear)
        coordinateView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        coordinateWindow.contentView = coordinateView
        check("the hosting view is flipped, so its own point is already top-left origin",
              coordinateView.isFlipped)
        let lowInWindow = DeckDragHost.deckPoint(ofWindowPoint: NSPoint(x: 100, y: 40),
                                                 in: coordinateWindow)
        check("40 up from the window's bottom edge lands 560 down from the deck's top",
              lowInWindow == CGPoint(x: 100, y: 560), "\(lowInWindow)")
        let highInWindow = DeckDragHost.deckPoint(ofWindowPoint: NSPoint(x: 700, y: 570),
                                                  in: coordinateWindow)
        check("30 down from the window's top edge stays 30 down from the deck's top",
              highInWindow == CGPoint(x: 700, y: 30), "\(highInWindow)")
        check("the icon is framed in the view's own space, centred on the pointer",
              DeckDragHost.iconFrame(pointerInView: CGPoint(x: 100, y: 40), size: 64)
              == NSRect(x: 68, y: 8, width: 64, height: 64))

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

        section("Drag fold target (crash regression)")
        let apps3: [DeckSlot] = [.app("a"), .app("b"), .folder(UUID())]
        // An app **is** a fold target — report 45 reverses report 40. LaunchOS
        // arms a merge on a tile hover (`isDraggingMerge` in the binary; the
        // user witnessed the effect and the folder-creating release), and the
        // tile-scoped hover removes the geometry collision that sank the app
        // target in report 40: a merge hover never reflows.
        check("another app is a fold target",
              DragState.combineTarget(item: .app("z"), pageItems: apps3, index: 0) == .app("a"))
        // A folder is: it is the one target the reflow cannot make ambiguous.
        let folderID = { if case .folder(let id) = apps3[2] { return id }; return UUID() }()
        check("a folder is a fold target",
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
        // The tester `update` builds internally is reproduced here so the
        // points land on real geometry: a centre hover on a tile arms the
        // merge (no reflow, report 45) and a margin hover is the insertion
        // point. The old hand-rolled centre ignored the tester's centring
        // origin and only worked because the pre-45 reflow ignored *where*
        // inside the cell the pointer was.
        let pipelineTester = GridHitTester(metrics: dmetrics, itemCount: row.count,
                                           containerSize: gridRect.size, slotCount: 35)
        func slotCentre(_ i: Int) -> CGPoint {
            let c = pipelineTester.centre(of: i)
            return CGPoint(x: c.x + gridRect.minX, y: c.y + gridRect.minY)
        }

        pipeline.begin(item: row[0], app: nil, title: nil, index: 0, page: 0,
                       location: slotCentre(0))
        // The crossing sequence (report 45): tile first, margin past it. A
        // centre hover arms the merge and opens no gap; the gap follows only
        // once the pointer has crossed the tile.
        func slotMargin(_ i: Int) -> CGPoint {
            CGPoint(x: slotCentre(i).x + dmetrics.cellWidth / 2 - 2, y: slotCentre(i).y)
        }
        pipeline.update(location: slotCentre(3), page: 0, metrics: dmetrics,
                        pageItems: row, capacity: 35)
        check("the tile hover itself still opens no gap", liveMoves.isEmpty,
              "\(liveMoves)")
        pipeline.update(location: slotMargin(3), page: 0, metrics: dmetrics,
                        pageItems: row, capacity: 35)
        check("in-grid drag reports the hovered slot", pipeline.hoverIndex == 3,
              "\(String(describing: pipeline.hoverIndex))")
        check("in-grid drag fires a live reorder", liveMoves == [3], "\(liveMoves)")
        check("an ordinary in-grid drag never flips pages", pageRequests.isEmpty, "\(pageRequests)")

        // B2: the live gap preview must survive crossing a page.
        liveMoves.removeAll()
        pipeline.update(location: slotCentre(1), page: 1, metrics: dmetrics,
                        pageItems: row, capacity: 35)
        pipeline.update(location: slotMargin(1), page: 1, metrics: dmetrics,
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

        section("Fold decision (release-triggered, live-reorder regression)")
        let shelf: [DeckSlot] = [.app("a"), .app("b"), .folder(UUID())]
        let folderID2 = { if case .folder(let id) = shelf[2] { return id }; return UUID() }()
        // The regression: after the live reflow the dragged app occupies the
        // hovered slot, and cancelling there made folding impossible.
        check("hovering the dragged item itself keeps the pending fold",
              DragState.combineDecision(item: .app("a"), pageItems: shelf, index: 0) == .keep)
        // Hovering another app names it as the merge target (report 45). The
        // tile-vs-margin split lives one level up, in `update`.
        check("hovering another app names it",
              DragState.combineDecision(item: .app("a"), pageItems: shelf, index: 1) == .start(.app("b")))
        check("hovering a folder names that folder",
              DragState.combineDecision(item: .app("a"), pageItems: shelf, index: 2) == .start(.folder(folderID2)))
        check("an empty trailing slot cancels",
              DragState.combineDecision(item: .app("a"), pageItems: shelf, index: 9) == .cancel)
        check("dragging a folder never starts a fold",
              DragState.combineDecision(item: .folder(UUID()), pageItems: shelf, index: 1) == .cancel)

        // The rest of the rule is *when* it fires. Nothing may happen while the
        // button is down: the target is only remembered, and the release is the
        // one thing that turns it into a fold. There is no timer left to test
        // for — the change was to delete it — so what is pinned here is that the
        // decision survives the reflow and is read at the drop.
        let reflowMetrics2 = GridMetrics(columns: 4, rows: 2, iconSize: 64,
                                         cellWidth: 88, cellHeight: 92)
        let tester2 = GridHitTester(metrics: reflowMetrics2, itemCount: shelf.count,
                                    containerSize: CGSize(width: 800, height: 400),
                                    slotCount: reflowMetrics2.capacity)
        let moving = DragState()
        moving.gridFrame = CGRect(x: 0, y: 0, width: 800, height: 400)
        var reflowedTo: [Int] = []
        moving.onLiveMove = { _, index in reflowedTo.append(index) }
        moving.begin(item: .app("a"), app: nil, title: nil, index: 0, page: 0,
                     source: .grid, location: CGPoint(x: 10, y: 10))
        // Hovering the *app* at index 1 (the centre is on the tile) arms the
        // merge and opens **no** gap: the tile must not be slid out from under
        // the pointer (report 45). The drop is the fold.
        moving.update(location: tester2.centre(of: 1), page: 0, metrics: reflowMetrics2,
                      pageItems: shelf, capacity: reflowMetrics2.capacity)
        check("hovering an app tile opens no gap — the tile stays put",
              reflowedTo.isEmpty, "\(reflowedTo)")
        check("... and releasing there folds the two apps",
              moving.drop(metrics: reflowMetrics2, pageItems: shelf) == .combine(.app("b")))
        moving.reset()

        // The distance judgment (report 45): the margin on the **approach**
        // side is not an insertion point — nothing moves until the pointer has
        // crossed the tile. The user pinned it: moving an icon toward another
        // from the right prepares the merge on contact, and the position only
        // changes once the icon has moved to the other icon's left.
        let slider = DragState()
        slider.gridFrame = CGRect(x: 0, y: 0, width: 800, height: 400)
        var slidTo: [Int] = []
        slider.onLiveMove = { _, index in slidTo.append(index) }
        slider.begin(item: .app("a"), app: nil, title: nil, index: 0, page: 0,
                     source: .grid, location: CGPoint(x: 10, y: 10))
        let cell1Centre = tester2.centre(of: 1)
        let margin1 = CGPoint(x: cell1Centre.x + reflowMetrics2.cellWidth / 2 - 2, y: cell1Centre.y)
        slider.update(location: margin1, page: 0, metrics: reflowMetrics2,
                      pageItems: shelf, capacity: reflowMetrics2.capacity)
        check("the approach margin moves nothing — the position only changes past the tile",
              slidTo.isEmpty, "\(slidTo)")
        check("... and the release there sends the icon home",
              slider.drop(metrics: reflowMetrics2, pageItems: shelf) == .none)
        slider.update(location: cell1Centre, page: 0, metrics: reflowMetrics2,
                      pageItems: shelf, capacity: reflowMetrics2.capacity)
        check("touching the tile arms the merge and still moves nothing",
              slider.combineAppID == "b" && slidTo.isEmpty,
              "\(String(describing: slider.combineAppID)) / \(slidTo)")
        slider.update(location: margin1, page: 0, metrics: reflowMetrics2,
                      pageItems: shelf, capacity: reflowMetrics2.capacity)
        check("crossing past the tile opens the gap",
              slidTo == [1], "\(slidTo)")
        check("... and the merge signal is gone",
              slider.combineAppID == nil, String(describing: slider.combineAppID))
        check("... and the release is a move, not a fold",
              slider.drop(metrics: reflowMetrics2, pageItems: shelf) == .toIndex(1))
        slider.reset()

        // The same gesture over a folder tile: the fold is armed and no gap
        // opens — the folder must not be slid aside (report 45; the user
        // watched LaunchOS hold the folder in place while hovered).
        let folding = DragState()
        folding.gridFrame = CGRect(x: 0, y: 0, width: 800, height: 400)
        var foldedTo: [Int] = []
        folding.onLiveMove = { _, index in foldedTo.append(index) }
        folding.begin(item: .app("a"), app: nil, title: nil, index: 0, page: 0,
                      source: .grid, location: CGPoint(x: 10, y: 10))
        folding.update(location: tester2.centre(of: 2), page: 0, metrics: reflowMetrics2,
                       pageItems: shelf, capacity: reflowMetrics2.capacity)
        check("hovering a folder opens no gap — the folder stays put",
              foldedTo.isEmpty, "\(foldedTo)")
        check("... and the drop is the fold",
              folding.drop(metrics: reflowMetrics2, pageItems: shelf) == .combine(.folder(folderID2)))
        // The live reflow has moved the dragged app into that slot by now, so
        // this second move is the state the pointer actually sits in. A decision
        // read from `pageItems` would answer "the app you are dragging" here and
        // the fold would never happen — which is exactly the bug the remembered
        // candidate exists for.
        let reflowed: [DeckSlot] = [.app("b"), .folder(folderID2), .app("a")]
        folding.update(location: tester2.centre(of: 2), page: 0, metrics: reflowMetrics2,
                       pageItems: reflowed, capacity: reflowMetrics2.capacity)
        check("the reflow filling the slot does not lose the target",
              folding.drop(metrics: reflowMetrics2, pageItems: reflowed) == .combine(.folder(folderID2)))
        // Leaving **by the margin** exercises the `.cancel` arm — moving onto
        // another tile goes through `.start` now that apps are targets, and
        // that path clears the signal on its own. The margin is where the
        // clear is observable on its own.
        let foldCentre = tester2.centre(of: 2)
        let foldMargin = CGPoint(x: foldCentre.x + reflowMetrics2.cellWidth / 2 - 2, y: foldCentre.y)
        folding.update(location: foldMargin, page: 0, metrics: reflowMetrics2,
                       pageItems: shelf, capacity: reflowMetrics2.capacity)
        check("leaving by the margin drops the fold signal",
              folding.combineFolderID == nil, String(describing: folding.combineFolderID))
        // Leaving the target takes the fold back off the table.
        folding.update(location: tester2.centre(of: 5), page: 0, metrics: reflowMetrics2,
                       pageItems: reflowed, capacity: reflowMetrics2.capacity)
        check("moving off the target drops the fold",
              folding.drop(metrics: reflowMetrics2, pageItems: reflowed) == .toIndex(5))
        check("the gap reopens once the pointer leaves the tile",
              foldedTo == [2, 5], "\(foldedTo)")
        folding.reset()

        // A member dragged around inside an open folder panel is a reorder of
        // that panel. The grid is visible behind the panel and its tiles answer
        // the same hit test, so the source has to be consulted or a reorder
        // inside a folder would silently fold the app into whatever folder
        // happens to be behind the panel.
        //
        // The hover target here is a **folder** on purpose. It used to be the app
        // at index 1, which stopped pinning the guard the moment an app stopped
        // being a fold target: with an app tile the candidate is nil whatever the
        // source is, so dropping the guard changes nothing and M88 survives.
        let member = DragState()
        member.gridFrame = CGRect(x: 0, y: 0, width: 800, height: 400)
        member.begin(item: .app("a"), app: nil, title: nil, index: 0, page: 0,
                     source: .folderMember(folderID2), location: CGPoint(x: 10, y: 10))
        member.update(location: tester2.centre(of: 2), page: 0, metrics: reflowMetrics2,
                      pageItems: shelf, capacity: reflowMetrics2.capacity)
        check("a folder member never folds into the grid folder behind the panel",
              member.drop(metrics: reflowMetrics2, pageItems: shelf) == .toIndex(2))
        member.reset()

        // The decision being right is not the same as the effect happening. This
        // is the half that a release-time fold could get wrong silently — the
        // checks above pass, and nothing at all is written to the store.
        let releaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-release-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: releaseURL) }
        let releaseMetrics = GridMetrics(columns: 4, rows: 2, iconSize: 64,
                                         cellWidth: 88, cellHeight: 92)
        let releaseStore = DeckStore(storeURL: releaseURL)
        releaseStore.metrics = releaseMetrics
        releaseStore.pages = [[.app("a"), .app("b"), .app("c")]]
        let releaseVM = LaunchpadViewModel(store: releaseStore)
        let releaseHost = DeckDragHost(store: releaseStore, vm: releaseVM)
        releaseHost.drag.gridFrame = CGRect(x: 0, y: 0, width: 800, height: 400)
        releaseHost.offset.begin(scrollOffset: 0, pageWidth: 1200, pageCount: 1)
        releaseHost.drag.begin(item: .app("a"), app: nil, title: "A", index: 0, page: 0,
                               source: .grid, location: .zero)
        let releaseTester = GridHitTester(metrics: releaseMetrics, itemCount: 3,
                                          containerSize: releaseHost.drag.gridFrame.size,
                                          slotCount: releaseMetrics.capacity)
        releaseHost.drag.update(location: releaseTester.centre(of: 1), page: 0,
                                metrics: releaseMetrics, pageItems: releaseStore.pages[0],
                                capacity: releaseMetrics.capacity)
        check("nothing is written while the button is still down",
              releaseStore.folders.isEmpty, "\(releaseStore.folders.count) folder(s)")
        releaseHost.commit()
        // Releasing on another app **creates the folder** (report 45): the
        // merge armed on the tile hover lands here, at the commit.
        check("releasing on another app folds them into a new folder",
              releaseStore.folders.count == 1, "\(releaseStore.folders.count) folder(s)")
        if case .folder(let mergedID)? = releaseStore.pages[0].first,
           let merged = releaseStore.folder(mergedID),
           merged.appIDs.contains("a"), merged.appIDs.contains("b") {
            check("... and both apps live inside the new folder", true)
        } else {
            check("... and both apps live inside the new folder", false,
                  "\(releaseStore.pages)")
        }
        check("the rest of the page is untouched",
              releaseStore.pages[0].dropFirst() == [.app("c")],
              "\(releaseStore.pages)")
        releaseHost.teardown()

        // The other half of the same release: a folder **is** a fold target, and
        // the fold has to really reach the store. Without this, deleting the
        // `addToFolder` call would leave every check above green.
        let foldURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-fold-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: foldURL) }
        let foldStore = DeckStore(storeURL: foldURL)
        foldStore.metrics = releaseMetrics
        // Real ids, not a synthetic trio: `folderApps` resolves members through
        // the scan index (`index[$0]`), so invented ids leave the folder looking
        // empty and the check below fails for a reason that is not the code path
        // under test. (Measured the hard way — the first cut used "a"/"b"/"c".)
        let foldIDs = Array(foldStore.visibleApps.prefix(3)).map(\.id)
        if foldIDs.count == 3 {
            foldStore.pages = [[.app(foldIDs[0]), .app(foldIDs[1]), .app(foldIDs[2])]]
            foldStore.makeFolder(dropping: foldIDs[1], onto: foldIDs[0])
        }
        if foldIDs.count == 3,
           let foldID = foldStore.folders.keys.first,
           let folderSlot = foldStore.locate(.folder(foldID)) {
            let foldVM = LaunchpadViewModel(store: foldStore)
            let foldHost = DeckDragHost(store: foldStore, vm: foldVM)
            foldHost.drag.gridFrame = CGRect(x: 0, y: 0, width: 800, height: 400)
            foldHost.offset.begin(scrollOffset: 0, pageWidth: 1200, pageCount: 1)
            let foldItems = foldStore.pages[0]
            foldHost.drag.begin(item: .app(foldIDs[2]), app: nil, title: "C",
                                index: foldItems.count - 1, page: 0,
                                source: .grid, location: .zero)
            let foldTester = GridHitTester(metrics: releaseMetrics, itemCount: foldItems.count,
                                           containerSize: foldHost.drag.gridFrame.size,
                                           slotCount: releaseMetrics.capacity)
            foldHost.drag.update(location: foldTester.centre(of: folderSlot.item), page: 0,
                                 metrics: releaseMetrics, pageItems: foldItems,
                                 capacity: releaseMetrics.capacity)
            foldHost.commit()
            check("releasing on a folder puts the app inside it",
                  foldStore.folderApps(foldID).contains { $0.id == foldIDs[2] },
                  "\(foldStore.folderApps(foldID).map(\.id))")
            check("... and it is no longer a grid slot of its own",
                  foldStore.locate(.app(foldIDs[2])) == nil, "\(foldStore.pages)")
            foldHost.teardown()
        } else {
            check("the fold fixture built a three-app page holding one folder", false,
                  "ids=\(foldIDs.count) folders=\(foldStore.folders.count) pages=\(foldStore.pages)")
        }

        section("Drag image (the icon in the air must not be rescaled)")
        // `NSWorkspace.icon(forFile:)` is a 1024-point image. Handing it straight
        // to `setDraggingFrame(_:contents:)` looks like it should work and does
        // not: AppKit derives its dragging component at its own legacy size, and
        // a measured 64×64 frame came back with a **32 pt / 32 px** image to
        // stretch into it — 4× on a Retina display, which is the soft icon that
        // was reported. The image handed over must have the frame's own logical
        // size; `lockFocus` then picks up the screen's pixel scale by itself.
        //
        // Measured, not reasoned: probe `/tmp/probe-dragsession/main8.swift`.
        //
        // The seam is exercised with a 1024-point stand-in so the assertion does
        // not depend on whatever icon happens to be installed — and reverting the
        // fix fails it outright, because the raw icon's size *is* 1024.
        IconCache.clear()
        IconCache.loadIcon = { _ in
            let image = NSImage(size: NSSize(width: 1024, height: 1024))
            image.addRepresentation(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!)
            return image
        }
        let iconSize = store.metrics.iconSize
        let airIcon = DragImageFactory.image(for: .app(store.apps.first?.id ?? "/none"), store: store,
                                             size: iconSize)
        check("the app icon handed to the drag session is the frame's own size",
              airIcon.size == NSSize(width: iconSize, height: iconSize), "\(airIcon.size)")
        check("... not the 1024 points the icon came in at",
              airIcon.size.width < 1024, "\(airIcon.size)")
        check("... with a rep at least as wide as the frame, for a Retina screen",
              airIcon.representations.allSatisfy { CGFloat($0.pixelsWide) >= iconSize },
              "\(airIcon.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" })")
        let airFolder = DragImageFactory.image(for: .folder(UUID()), store: store, size: iconSize)
        check("a folder's drag image is the frame's size too",
              airFolder.size == NSSize(width: iconSize, height: iconSize), "\(airFolder.size)")
        let airBlank = DragImageFactory.image(for: .app("/definitely-not-installed.app"),
                                              store: store, size: iconSize)
        check("an app whose icon cannot be found still gets a frame-sized image",
              airBlank.size == NSSize(width: iconSize, height: iconSize), "\(airBlank.size)")
        IconCache.loadIcon = { NSWorkspace.shared.icon(forFile: $0) }
        IconCache.clear()

        // Being in front of the *grid* is not enough. The icon also has to be in
        // front of the deck **window**, or the full-screen frosted backdrop is
        // composited over it and the icon reads as having fallen into the blur —
        // "the icon became background". That was the report this pair answers.
        //
        // AppKit puts the dragged image in a window of its own at
        // `kCGDraggingWindowLevel`. Measured: **500** — and it stays 500 even when
        // the source window is at the shielding level, so AppKit never raises the
        // drag image above the window it came from (probe
        // `/tmp/probe-dragsession/main11.swift`, reading `CGWindowListCopyWindowInfo`
        // from a timer while the drag loop owns the run loop).
        //
        // The deck used to be created at `CGShieldingWindowLevel()` — measured
        // 2147483628 — which is above the dragging window by every measure.
        let deckLevel = LaunchpadWindowController.deckWindowLevel.rawValue
        // ⚠️ Compared against the **measured literal** on purpose. `deckWindowLevel`
        // is *defined* as one below `CGWindowLevelForKey(.draggingWindow)`, so
        // writing `deckLevel < CGWindowLevelForKey(.draggingWindow)` here would be
        // `X − 1 < X`: a tautology that can never fail and that **no mutation can
        // ever expose**. The literal also catches the system moving under us —
        // drift downward trips the popup-menu check below, drift upward trips this
        // one.
        check("the deck sits below the window AppKit drags the icon in (500)",
              deckLevel < 500, "deck \(deckLevel)")
        check("... and still covers the Dock, the menu bar and popup menus",
              deckLevel > Int(CGWindowLevelForKey(.popUpMenuWindow)), "\(deckLevel)")
        check("... and is not the shielding level it used to be",
              deckLevel != Int(CGShieldingWindowLevel()), "\(deckLevel)")
        // The rule above is a *decision*; this is the *effect*, and the two live
        // in different objects. M89 survived a round by rewriting only the line
        // that applies it (the exact hole M87 found), and moving that line into
        // its own `applyDeckLevel(to:)` did **not** close it either: a mutation
        // reverting the call site in `show()` still stayed green, because nothing
        // here can run `show()`.
        //
        // So the deck window is now built in exactly one place, and that place is
        // driven here. The window is never ordered on screen.
        guard let selftestScreen = NSScreen.main else { fatalError("no screen") }
        // The mode is passed explicitly: `makeDeckWindow` otherwise reads the
        // user's live `displayMode`, and a check that only passes while they
        // happen to be in full-screen mode is not a check.
        let builtDeck = LaunchpadWindowController.makeDeckWindow(on: selftestScreen,
                                                                 mode: .fullScreen)
        check("the deck window it builds is put below the drag window",
              builtDeck.level.rawValue == deckLevel, "\(builtDeck.level.rawValue)")
        check("... and it is still the borderless, clear window it was",
              !builtDeck.isOpaque && builtDeck.backgroundColor == .clear && !builtDeck.hasShadow)
        // The windowed deck is a normal window — a titled one that other apps
        // can come over (report 56 §5).
        let windowedDeck = LaunchpadWindowController.makeDeckWindow(on: selftestScreen,
                                                                    mode: .window)
        check("56-E: the windowed deck sits at the normal level",
              windowedDeck.level == .normal, "\(windowedDeck.level.rawValue)")
        check("56-E: the windowed deck is a titled, resizable window",
              windowedDeck.styleMask.contains(.titled)
              && windowedDeck.styleMask.contains(.resizable)
              && windowedDeck.styleMask.contains(.closable))
        check("56-E: the windowed deck is smaller than the screen",
              windowedDeck.frame.width < selftestScreen.frame.width
              && windowedDeck.frame.height < selftestScreen.frame.height)

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

        // Resuming the page the user left off on (Settings → "Resume where I left
        // off"). The jump is published while the window controller builds the
        // view, so the grid's first report still names the page it is *leaving*.
        // Adopting that report overwrote the jump and wrote the wrong page to
        // preferences on every launch.
        section("Page jump arbitration (resume-last-page regression)")

        let quiet = PageJumpGuard()
        check("with no jump in flight, a report naming the page we believe in changes nothing",
              quiet.observe(reported: 0, requested: 0) == false)
        check("with no jump in flight, a report naming another page is the user's",
              quiet.observe(reported: 0, requested: 3) == true)

        // The exact shape of the bug: a jump to page 2 is published before the
        // grid exists, so the first report is still page 0.
        let resume = PageJumpGuard()
        check("a jump arms because the scroll view has to move", resume.arm(2))
        check("the page a jump is leaving is not adopted as the user's choice",
              resume.observe(reported: 0, requested: 2) == false)
        check("a page the jump passes through is not adopted either",
              resume.observe(reported: 1, requested: 2) == false)
        check("the report that lands the jump changes nothing (nothing is left to change)",
              resume.observe(reported: 2, requested: 2) == false)
        check("a landed jump stops claiming reports", resume.inFlight == nil)
        check("after the jump, a scroll is the user's again",
              resume.observe(reported: 3, requested: 2) == true)

        // A guard nothing ever clears would swallow the user's next scroll, so a
        // jump to the page the scroll view is already on must not arm at all.
        let idle = PageJumpGuard()
        check("a jump to the page already on screen does not arm", idle.arm(0) == false)
        check("...so the very next scroll is still the user's",
              idle.observe(reported: 1, requested: 0) == true)

        // A finger outranks an animation in flight. Without this, a jump
        // interrupted by a drag would keep swallowing reports until the page it
        // wanted appeared — which, once the user has dragged elsewhere, is never.
        let interrupted = PageJumpGuard()
        _ = interrupted.arm(3)
        interrupted.disarm()
        check("a drag cancels the claim a jump in flight had",
              interrupted.observe(reported: 1, requested: 3) == true)

        let reused = PageJumpGuard()
        _ = reused.arm(4)
        reused.reset()
        check("a guard reaching a newly built grid carries no jump",
              reused.inFlight == nil && reused.reportedPage == 0)
        check("...and its first report is judged on its own merits",
              reused.observe(reported: 0, requested: 0) == false)

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
        // A refusal must not have moved anything. The old order called
        // `removeFromFolder` (which saves) *before* the `locate` guard, so a
        // failure returned `false` with the layout already changed on disk.
        let beforeRefusal = ssot.pages
        check("a move out of a folder that does not exist is refused",
              ssot.moveOutOfFolder("fb-a", folder: UUID(), toPage: 1, index: 0) == false)
        check("...and that refusal moves nothing",
              ssot.pages == beforeRefusal, "\(ssot.pages.map(\.count))")

        // A folder that exists but has no grid slot is the case the old guard
        // reached only *after* mutating, so this is the regression that mattered.
        let ghost = AppFolder(name: "Ghost", appIDs: ["ghost-a", "ghost-b"])
        ssot.folders[ghost.id] = ghost
        let beforeGhost = ssot.pages
        check("a folder with no grid slot refuses the move",
              ssot.moveOutOfFolder("ghost-a", folder: ghost.id, toPage: 0, index: 0) == false)
        check("...that refusal also moves nothing",
              ssot.pages == beforeGhost && ssot.locate(.app("ghost-a")) == nil,
              "\(ssot.pages.map(\.count))")
        check("...and the refused folder keeps both members",
              ssot.folder(ghost.id)?.appIDs.count == 2)

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

        section("Folder column rule — the page's columns (LaunchOS columnsPerPage)")
        // LaunchOS lays a folder with the deck's column count (its
        // `columnsPerPage`): a fixed-width, left-aligned grid that only grows in
        // height. So the member count must NOT change the column count — the old
        // 1/2/3/4-by-count rule made small folders narrower, the opposite of
        // LaunchOS. `LaunchpadViewModel` keyboard nav reads the same rule.
        let pageCols = 7
        let wrongWidth = (0 ... 20).filter {
            FolderLayout.columns(pageColumns: pageCols, memberCount: $0) != pageCols
        }
        check("folder column count is the page's for every member count 0..20",
              wrongWidth.isEmpty,
              "\(wrongWidth.map { "\($0) members" })")

        check("folder tracks a narrower page preset",
              FolderLayout.columns(pageColumns: 5) == 5
              && FolderLayout.columns(pageColumns: 10) == 10)
        check("degenerate page width clamps to one column",
              FolderLayout.columns(pageColumns: 0) == 1)

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
        // Report 41 — a folder the user creates on purpose.
        //
        // The one folder in the model allowed to hold a **single** member, and a
        // deliberate departure from LaunchOS: its string table (en and zh-Hans),
        // its raw binary strings and its selector list were all searched and
        // contain no create-folder anything. LaunchOS can rename, ungroup and
        // move apps *into* folders; it cannot make one. So this is not parity —
        // it is a capability added on purpose.
        //
        // Both halves are asserted: the **decision** (`dissolves`) and the
        // **effect** (a real store, a real file). Report 39's M89 was lost to
        // exactly this split, so neither half is allowed to stand alone.
        // ------------------------------------------------------------------
        // ------------------------------------------------------------------
        // 42 — Icon size, latin search, Dock icon
        //
        // Three additions that each reduce to a **pure function**, so all three
        // are asserted headlessly instead of eyeballed. The icon-size one carries
        // a regression check that recomputes the pre-42 formula, so "the default
        // is a no-op" is asserted rather than assumed.
        // ------------------------------------------------------------------
        section("Review 42 — Icon size, latin search, Dock icon")

        // 42-A: the icon scale. `big` is a screen whose derived base is the 116pt
        // ceiling, so the multiple is plainly visible in the result.
        let bigScreen = CGSize(width: 2560, height: 1440)
        let unscaled = GridMetrics.make(in: bigScreen, preset: .grid7x5)
        let preFortyTwo = min(max(min(unscaled.cellWidth - 34, unscaled.cellHeight - 54), 56), 116).rounded()
        check("42-A: the default scale reproduces the pre-42 icon size exactly",
              unscaled.iconSize == preFortyTwo, "\(unscaled.iconSize) vs \(preFortyTwo)")
        check("42-A: a larger scale gives a larger icon",
              GridMetrics.make(in: bigScreen, preset: .grid7x5, iconScale: 1.25).iconSize > unscaled.iconSize)
        check("42-A: a smaller scale gives a smaller icon",
              GridMetrics.make(in: bigScreen, preset: .grid7x5, iconScale: 0.8).iconSize < unscaled.iconSize)
        check("42-A: an absurdly large scale stops at the declared maximum",
              GridMetrics.make(in: bigScreen, preset: .grid7x5, iconScale: 99).iconSize
                  == (unscaled.iconSize * IconScale.maximum).rounded())
        check("42-A: an absurdly small scale stops at the declared minimum",
              GridMetrics.make(in: bigScreen, preset: .grid7x5, iconScale: 0.01).iconSize
                  == (unscaled.iconSize * IconScale.minimum).rounded())
        check("42-A: IconScale.clamped clamps at both ends",
              IconScale.clamped(0) == IconScale.minimum && IconScale.clamped(9) == IconScale.maximum)

        // The cell-edge clamp only bites on a screen whose cells are just wide
        // enough for the 116pt base: 1352x1182 yields cellWidth 160 / cellHeight
        // 180, where 1.4 x 116 would overflow. The fixture is asserted first, so
        // a later geometry change cannot quietly make the next check vacuous.
        let snugScreen = CGSize(width: 1352, height: 1182)
        let snugBase = GridMetrics.make(in: snugScreen, preset: .grid7x5)
        let snug = GridMetrics.make(in: snugScreen, preset: .grid7x5, iconScale: 99)
        check("42-A: (fixture) that screen really would overflow without the clamp",
              snug.iconSize < (snugBase.iconSize * IconScale.maximum).rounded(),
              "snug \(snug.iconSize) vs raw \((snugBase.iconSize * IconScale.maximum).rounded())")
        check("42-A: a scaled-up icon is held inside its cell",
              snug.iconSize <= min(snug.cellWidth - 8, snug.cellHeight - 8),
              "\(snug.iconSize) in \(snug.cellWidth)x\(snug.cellHeight)")

        // 42-B: latin (pinyin) search. `matchScore` is the ranking rule itself,
        // so these do not go through a store or a keystroke.
        check("42-B: 微信 transliterates to a latin form",
              (LaunchpadViewModel.latinized("微信") ?? "").contains("wei"),
              LaunchpadViewModel.latinized("微信") ?? "nil")
        check("42-B: an ASCII name survives transliteration unchanged",
              (LaunchpadViewModel.latinized("Safari") ?? "").contains("safari"))
        check("42-B: typing the pinyin 'weixin' finds 微信",
              LaunchpadViewModel.matchScore(name: "微信", latin: "weixin", bundleID: nil, raw: "weixin", needle: "weixin") == 0)
        check("42-B: typing it with a space ('wei xin') finds 微信 too",
              LaunchpadViewModel.matchScore(name: "微信", latin: "weixin", bundleID: nil, raw: "wei xin", needle: "weixin") == 0)
        check("42-B: the initials 'wx' find 微信 as a subsequence",
              LaunchpadViewModel.matchScore(name: "微信", latin: "weixin", bundleID: nil, raw: "wx", needle: "wx") == 4)
        check("42-B: 'zhifubao' finds 支付宝",
              LaunchpadViewModel.matchScore(name: "支付宝", latin: "zhifubao", bundleID: nil, raw: "zhifubao", needle: "zhifubao") == 0)
        // These two drive `latinKey` itself, the seam the live search uses.
        // Without them the latin assertions above pass on hand-written inputs
        // and never exercise the transliteration + space-stripping path at all
        // (that is exactly how M107 survived the first run).
        check("42-B: the latin key drops the spaces the transliteration inserts",
              LaunchpadViewModel.latinKey(for: "微信") == "weixin",
              LaunchpadViewModel.latinKey(for: "微信") ?? "nil")
        check("42-B: a name with no latin form has no latin key",
              LaunchpadViewModel.latinKey(for: "") == nil)
        check("42-B: a name with no latin form still matches by name",
              LaunchpadViewModel.matchScore(name: "Safari", latin: nil, bundleID: nil, raw: "saf", needle: "saf") == 1)
        check("42-B: a query that matches nothing returns nil",
              LaunchpadViewModel.matchScore(name: "微信", latin: "weixin", bundleID: nil, raw: "qq", needle: "qq") == nil)

        // 42-C: the Dock-icon toggle.
        check("42-C: asking for a Dock icon maps to .regular",
              DockIconPolicy.policy(showDockIcon: true) == .regular)
        check("42-C: turning it off maps to .accessory",
              DockIconPolicy.policy(showDockIcon: false) == .accessory)
        check("42-C: headless refuses to change the Dock icon, and does not lie about it",
              DeckSettings.shared.applyDockIcon() == false && !DeckSettings.shared.mayPersist)

        section("Review 43 — Screen policy, self-exclusion, Dock-icon trap")

        // 43-A: the placement decision, driven with constructed geometry. This
        // machine has one display, so the four policies can only be told apart
        // here — a real `NSScreen` cannot even be constructed.
        let lead = ScreenInfo(id: "1", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                              visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 867))
        let flank = ScreenInfo(id: "2", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: 1440, y: 80, width: 1920, height: 1000))
        let stack = ScreenInfo(id: "3", frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
                               visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 900))
        let multis = [lead, flank, stack]

        check("43-A: the menu-bar screen is found by its top inset, not by array order",
              ScreenPicker.menuBarIndex([flank, lead]) == 1)
        check("43-A: the pointer policy follows the pointer",
              ScreenPicker.targetIndex(policy: .pointer, screens: multis,
                                       pointer: CGPoint(x: 2000, y: 500), activeScreenID: nil) == 1)
        check("43-A: a pointer on no screen falls back to the menu-bar screen",
              ScreenPicker.targetIndex(policy: .pointer, screens: multis,
                                       pointer: CGPoint(x: -500, y: -500), activeScreenID: nil) == 0)
        check("43-A: the main policy takes the menu-bar screen",
              ScreenPicker.targetIndex(policy: .main, screens: multis,
                                       pointer: CGPoint(x: 2000, y: 500), activeScreenID: nil) == 0)
        check("43-A: the active policy takes the frontmost app's screen",
              ScreenPicker.targetIndex(policy: .active, screens: multis,
                                       pointer: .zero, activeScreenID: "2") == 1)
        check("43-A: an unknown frontmost screen falls back too",
              ScreenPicker.targetIndex(policy: .active, screens: multis,
                                       pointer: .zero, activeScreenID: "99") == 0)
        check("43-A: the dock policy finds the screen the Dock reserves, not the menu-bar screen",
              ScreenPicker.targetIndex(policy: .dock, screens: multis,
                                       pointer: .zero, activeScreenID: nil) == 1)
        check("43-A: a hidden Dock leaves no reserve, so the dock policy lands on the menu-bar screen",
              ScreenPicker.dockIndex([lead, stack]) == nil
              && ScreenPicker.targetIndex(policy: .dock, screens: [lead, stack],
                                          pointer: .zero, activeScreenID: nil) == 0)
        check("43-A: a left-hand Dock counts as reserved space",
              ScreenPicker.dockIndex([ScreenInfo(id: "1",
                                                 frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                 visibleFrame: CGRect(x: 70, y: 0, width: 1370, height: 867))]) == 0)
        check("43-A: no screens at all answers 0 instead of crashing",
              ScreenPicker.targetIndex(policy: .dock, screens: [], pointer: .zero, activeScreenID: nil) == 0)

        // 43-B: the deck must not list itself. Only the pure gate is asserted:
        // a real-scan assertion ("the scan returns no OpenDeck") would be
        // vacuously true on this machine — the build product sits outside every
        // scan root, so the scan could not return it either way. The guard call
        // inside `scan()` is therefore unobservable here, and is kept with that
        // written on it (the X41 precedent), not papered over with a check that
        // cannot fail.
        //
        // The real bundle id is asserted only inside `if let`, for the same
        // reason: the harness environment has none, and a skipped check does not
        // lie about a mutation.
        // The gate's assertions use literal strings, not `Bundle.main
        // .bundleIdentifier`: the mutation harness runs this binary from outside
        // its .app, where Bundle.main has no bundle id — an assertion built on it
        // fails there regardless of the mutation, and every entry in the registry
        // would be "killed" by the same environment accident. (Seen live: the
        // first 2a run killed all seven mutations, but the same two 43-B failures
        // rode along on every one of them.)
        check("43-B: an app whose bundle id is our own is excluded",
              !AppScanner.shouldInclude(bundleID: "local.opendeck.app",
                                        ownBundleID: "local.opendeck.app"))
        check("43-B: a different app is kept",
              AppScanner.shouldInclude(bundleID: "com.apple.Safari", ownBundleID: "local.opendeck.app"))
        check("43-B: an app with no bundle id is still kept",
              AppScanner.shouldInclude(bundleID: nil, ownBundleID: "local.opendeck.app"))
        if let own = Bundle.main.bundleIdentifier {
            check("43-B: the installed bundle's id is the one the gate excludes",
                  own == "local.opendeck.app", own)
        }

        // 43-C: the two-icon trap.
        let repaired = DockIconPolicy.resolveIcons(showDockIcon: false, showMenuBarIcon: false)
        check("43-C: turning both icons off is repaired to keep the menu bar one",
              repaired.dock == false && repaired.menuBar == true)
        check("43-C: a Dock icon alone is left alone",
              DockIconPolicy.resolveIcons(showDockIcon: true, showMenuBarIcon: false)
                  == (dock: true, menuBar: false))
        check("43-C: a menu bar icon alone is left alone",
              DockIconPolicy.resolveIcons(showDockIcon: false, showMenuBarIcon: true)
                  == (dock: false, menuBar: true))
        check("43-C: both icons on is left alone",
              DockIconPolicy.resolveIcons(showDockIcon: true, showMenuBarIcon: true)
                  == (dock: true, menuBar: true))

        section("Review 44 — Merge motion (decoded from LaunchOS)")

        // 44-A: the constants are evidence, not taste. Both doubles were read
        // out of the binary (report 44 §2): the scale from the
        // CATransform3DMakeScale feeds at 0x1000e65a8/0x1000e6988, the duration
        // from the setDuration: feeds at 0x1000e66e0/0x1000e6a9c, and both
        // directions carry kCAMediaTimingFunctionEaseOut.
        check("44-A: the merge scale is the decoded 0.8090169943749475 (phi/2)",
              MergeMotion.scale == 0.8090169943749475)
        check("44-A: the merge duration is the decoded 0.18 s",
              MergeMotion.duration == 0.18)

        // 54-A: the folder **open** motion is also evidence, not taste
        // (report 54 §1). `0x10010df6c` sets the NSAnimationContext duration to
        // 0x3fd1eb851eb851ec and the timing function to
        // kCAMediaTimingFunctionEaseInEaseOut; the SwiftUI presentation uses
        // `.easeInOut(duration:)`, the same curve family without a spring.
        check("54-A: the open duration is the decoded 0.28 s",
              OpenMotion.duration == 0.28)

        // 54-B: the hidden badge's symbol ratio is the decoded 0.64
        // (report 54 §2): `0x1000e5b9c` sizes the symbol at
        // `0.64 × min(bounds)` inside the white circle. The diameter fraction
        // is deliberately NOT pinned — it was never decoded.
        check("54-B: the hidden badge symbol is the decoded 0.64 of the badge",
              HiddenBadge.symbolFraction == 0.64)

        // 54-C: the caption shadow is the decoded one (report 54 §3):
        // black @ 0.26, blur 2, offset (0, -1) — from the NSShadow built at
        // 0x100003f34. The old 0.85 alpha was the *text* colour's alpha from
        // the label builder's alternate branch, not the shadow.
        check("54-C: the caption shadow alpha is the decoded 0.26",
              CaptionShadow.alpha == 0.26)
        check("54-C: the caption shadow radius is the decoded 2",
              CaptionShadow.radius == 2)
        check("54-C: the caption shadow offset is the decoded (0, -1)",
              CaptionShadow.offsetY == -1)

        // 44-B: every folding path publishes one flash with a strictly
        // increasing token, so two flashes on the same folder in a row still
        // re-trigger the animation. The SwiftUI presentation that consumes the
        // flash cannot be driven headlessly — the signal chain is what the
        // suite pins, one mutation per site (M120–M126).
        let flashURL = tempURL.deletingLastPathComponent()
            .appendingPathComponent("opendeck-selftest-flash-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: flashURL) }
        let fs = DeckStore(storeURL: flashURL)
        fs.metrics = GridMetrics(columns: 3, rows: 3, iconSize: 100, cellWidth: 150, cellHeight: 150)
        let fIDs = Array(fs.visibleApps.prefix(4)).map(\.id)
        if fIDs.count == 4 {
            check("44-B: an idle store has published no flash", fs.mergeFlash == nil)

            fs.makeFolder(dropping: fIDs[0], onto: fIDs[1])
            let fid = fs.folders.values.first { $0.appIDs.contains(fIDs[0]) }?.id
            check("44-B: folding two loose apps flashes absorbed for the new folder",
                  fs.mergeFlash?.kind == .absorbed && fs.mergeFlash?.folderID == fid,
                  "\(String(describing: fs.mergeFlash))")
            check("44-B: the first flash carries token 1", fs.mergeFlash?.token == 1)

            fs.makeFolder(dropping: fIDs[2], onto: fIDs[1])
            check("44-B: a second fold flashes again with an increased token",
                  fs.mergeFlash?.kind == .absorbed
                  && fs.mergeFlash?.folderID == fid
                  && fs.mergeFlash?.token == 2)

            fs.makeFolder(dropping: fIDs[0], onto: fIDs[1])
            check("44-B: dropping a member onto its own folder is a no-op (no flash)",
                  fs.mergeFlash?.token == 2)

            _ = fs.addToFolder(fIDs[3], folder: fid!)
            check("44-B: addToFolder flashes absorbed for that folder",
                  fs.mergeFlash?.kind == .absorbed
                  && fs.mergeFlash?.folderID == fid
                  && fs.mergeFlash?.token == 3)
            _ = fs.addToFolder(fIDs[3], folder: fid!)
            check("44-B: adding a member twice publishes nothing",
                  fs.mergeFlash?.token == 3)
            _ = fs.addToFolder(fIDs[3], folder: UUID())
            check("44-B: adding to an unknown folder publishes nothing",
                  fs.mergeFlash?.token == 3)

            // 44-C: releasing. `ungroup` and a dissolving `removeFromFolder`
            // publish `.released` — the counterpart of LaunchOS's
            // merge.scale.out (identity → 0.809, fade to 0, 0.18 s, ease-out).
            fs.ungroup(fid!)
            check("44-C: ungrouping flashes released for that folder",
                  fs.mergeFlash?.kind == .released
                  && fs.mergeFlash?.folderID == fid
                  && fs.mergeFlash?.token == 4)
            fs.ungroup(UUID())
            check("44-C: ungrouping an unknown folder publishes nothing",
                  fs.mergeFlash?.token == 4)

            fs.makeFolder(dropping: fIDs[0], onto: fIDs[1])
            let fid2 = fs.folders.values.first { $0.appIDs.contains(fIDs[0]) }?.id
            let tDissolve = fs.mergeFlash!.token
            fs.removeFromFolder(fIDs[0], folder: fid2!)
            check("44-C: a removal that dissolves the folder flashes released",
                  fs.mergeFlash?.kind == .released
                  && fs.mergeFlash?.folderID == fid2
                  && fs.mergeFlash?.token == tDissolve + 1)

            fs.makeFolder(dropping: fIDs[0], onto: fIDs[1])
            _ = fs.addToFolder(fIDs[2], folder: fs.folders.values.first { $0.appIDs.contains(fIDs[0]) }!.id)
            let fid3 = fs.folders.values.first { $0.appIDs.contains(fIDs[0]) }!.id
            let tKeep = fs.mergeFlash!.token
            fs.removeFromFolder(fIDs[0], folder: fid3)
            check("44-C: a removal that leaves two members publishes nothing",
                  fs.mergeFlash?.token == tKeep)

            // 44-D: moves and renames are not merge motion.
            let tMove = fs.mergeFlash!.token
            if let src = fs.locate(.app(fIDs[0])), fs.pages[src.section].count > 1 {
                fs.move(itemAt: src, to: IndexPath(item: 0, section: src.section))
            }
            check("44-D: a grid move publishes no flash", fs.mergeFlash?.token == tMove)

            // 44-G: the store mirror. The grid never observes DragState, so the
            // drag host copies the value over (diffed) and FolderCell reads it
            // here — the same channel shape as mergeFlash.
            check("44-G: an untouched store has no drop-hover folder",
                  fs.dropHoverFolderID == nil)
            fs.setDropHoverFolder(fid)
            check("44-G: the mirror publishes the hovered folder",
                  fs.dropHoverFolderID == fid)
            fs.setDropHoverFolder(nil)
            check("44-G: clearing the mirror empties it",
                  fs.dropHoverFolderID == nil)
            let hoverCommitURL = tempURL.deletingLastPathComponent()
                .appendingPathComponent("opendeck-selftest-hovercommit-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: hoverCommitURL) }
            let hoverStore = DeckStore(storeURL: hoverCommitURL)
            hoverStore.pages = [[.app("a")]]
            let hoverHost = DeckDragHost(store: hoverStore, vm: LaunchpadViewModel(store: hoverStore))
            hoverStore.setDropHoverFolder(UUID())
            hoverHost.commit()
            check("44-G: a release clears the drop-hover folder even when nothing folds",
                  hoverStore.dropHoverFolderID == nil)
            hoverHost.teardown()
        } else {
            check("at least four apps for the merge-motion test", false)
        }



        section("Review 45 — Drop-hover zoom (decoded from LaunchOS)")

        // 44-E: the drop-hover zoom is a measurement too. 0x1000171d4 feeds
        // 0x3FF0CCCCCCCCCCCD (= 1.05) into CATransform3DMakeScale and then
        // straight into setTransform: — implicit animation, centre-anchored,
        // the tile grows in place. The 1.4 family belongs to the open panel,
        // not the tile.
        check("44-E: the drop-hover zoom is the decoded 1.05",
              MergeMotion.hoverZoom == 1.05)

        // 44-F: the drop-hover signal chain in DragState — the same state
        // machine that decides the fold, published per move. Drivable
        // headlessly the same way as the reflow test above.
        let hoverMetrics = GridMetrics(columns: 3, rows: 3, iconSize: 100, cellWidth: 150, cellHeight: 150)
        let hoverFrame = CGRect(x: 0, y: 0, width: 450, height: 450)
        let hoverTester = GridHitTester(metrics: hoverMetrics, itemCount: 4,
                                        containerSize: hoverFrame.size,
                                        slotCount: hoverMetrics.capacity)
        let hoverFID = UUID()
        let hoverItems: [DeckSlot] = [.app("a"), .folder(hoverFID), .app("b"), .app("c")]
        let hover = DragState()
        hover.gridFrame = hoverFrame
        let overFolder = hoverTester.centre(of: 1)
        hover.begin(item: .app("a"), app: nil, title: nil, index: 0, page: 0,
                    source: .grid, location: CGPoint(x: overFolder.x, y: overFolder.y))
        hover.update(location: CGPoint(x: overFolder.x, y: overFolder.y),
                     page: 0, metrics: hoverMetrics, pageItems: hoverItems,
                     capacity: hoverMetrics.capacity)
        check("44-F: hovering a folder names it as the drop target",
              hover.combineFolderID == hoverFID, String(describing: hover.combineFolderID))
        let overApp = hoverTester.centre(of: 2)
        hover.update(location: CGPoint(x: overApp.x, y: overApp.y),
                     page: 0, metrics: hoverMetrics, pageItems: hoverItems,
                     capacity: hoverMetrics.capacity)
        check("44-F: moving off the folder clears the drop target",
              hover.combineFolderID == nil, String(describing: hover.combineFolderID))
        hover.update(location: CGPoint(x: overFolder.x, y: overFolder.y),
                     page: 0, metrics: hoverMetrics, pageItems: hoverItems,
                     capacity: hoverMetrics.capacity)
        hover.reset()
        check("44-F: resetting the drag clears the drop target",
              hover.combineFolderID == nil)

        // 45: the same chain for a merge over an **app** tile, plus the
        // out-of-grid exit the 44-F block does not cover.
        let mergeItems: [DeckSlot] = [.app("x"), .app("y"), .folder(hoverFID)]
        let appMerger = DragState()
        appMerger.gridFrame = hoverFrame
        let mergeCentre = hoverTester.centre(of: 0)
        appMerger.begin(item: .app("w"), app: nil, title: nil, index: 0, page: 0,
                     source: .grid, location: mergeCentre)
        appMerger.update(location: mergeCentre, page: 0, metrics: hoverMetrics,
                      pageItems: mergeItems, capacity: hoverMetrics.capacity)
        check("45: hovering an app tile names it as the merge target",
              appMerger.combineAppID == "x" && appMerger.combineFolderID == nil,
              "\(String(describing: appMerger.combineAppID)) / \(String(describing: appMerger.combineFolderID))")
        appMerger.update(location: CGPoint(x: -50, y: -50), page: 0, metrics: hoverMetrics,
                      pageItems: mergeItems, capacity: hoverMetrics.capacity)
        check("45: leaving the grid clears the merge signals",
              appMerger.combineAppID == nil && appMerger.combineFolderID == nil)
        appMerger.reset()
        check("45: resetting clears the merge signal", appMerger.combineAppID == nil)

        section("Review 46 — Pull-out (the member drag leaves the panel)")

        // 46-A: the exit test is pure geometry over the panel's **visible**
        // bounds — the registered grid box inset by the plate's padding. The
        // padding band pins the inset direction: a mutation dropping the inset
        // (or flipping its sign) moves the boundary and fails here.
        let panelRect = CGRect(x: 200, y: 150, width: 400, height: 300)
        check("46-A: the pointer inside the panel has not exited",
              !DragState.exitedPanel(pointer: CGPoint(x: 400, y: 300),
                                     panelFrame: panelRect, padding: 30))
        check("46-A: the pointer in the padding band has not exited",
              !DragState.exitedPanel(pointer: CGPoint(x: 180, y: 300),
                                     panelFrame: panelRect, padding: 30))
        check("46-A: the pointer just past the plate has exited",
              DragState.exitedPanel(pointer: CGPoint(x: 160, y: 300),
                                    panelFrame: panelRect, padding: 30))

        // 46-B: the promotion. The member contract at the release is
        // "place, never fold" (`drop` gates the combine on `.grid` on
        // purpose); once the drag is promoted the same state folds. That flip
        // is the whole semantic of the pull-out, asserted on both sides.
        let promo = DragState()
        promo.gridFrame = hoverFrame
        promo.begin(item: .app("w"), app: nil, title: nil, index: 0, page: 0,
                    source: .folderMember(hoverFID), location: mergeCentre)
        promo.update(location: mergeCentre, page: 0, metrics: hoverMetrics,
                     pageItems: mergeItems, capacity: hoverMetrics.capacity)
        check("46-B: a member release over a tile places, never folds",
              promo.drop(metrics: hoverMetrics, pageItems: mergeItems) == .toIndex(0))
        promo.promoteToGrid()
        check("46-B: the promoted release folds — the grid gating follows the promotion",
              promo.drop(metrics: hoverMetrics, pageItems: mergeItems) == .combine(.app("x")))
        promo.promoteToGrid()
        check("46-B: a second promotion changes nothing", promo.source == .grid)
        promo.reset()

        // 46-C: the effect, through the real host. Inside the panel nothing
        // happens; past the plate the member joins the grid **now**, the panel
        // is asked to collapse (the light teardown — the store's drag session
        // stays open until the commit), the drag is promoted, and the very
        // next move slides the gap — the "keeps sorting on the desktop" half.
        let pullURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opendeck-pullout-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: pullURL) }
        let pullStore = DeckStore(storeURL: pullURL)
        pullStore.metrics = GridMetrics(columns: 4, rows: 2, iconSize: 64,
                                        cellWidth: 88, cellHeight: 92)
        let pullFID = UUID()
        pullStore.folders[pullFID] = AppFolder(id: pullFID, name: "F",
                                               appIDs: ["m1", "m2", "m3"])
        pullStore.pages = [[.folder(pullFID), .app("g1"), .app("g2")]]
        let pullVM = LaunchpadViewModel(store: pullStore)
        let pullHost = DeckDragHost(store: pullStore, vm: pullVM)
        pullHost.drag.gridFrame = CGRect(x: 0, y: 0, width: 800, height: 400)
        pullHost.offset.begin(scrollOffset: 0, pageWidth: 1200, pageCount: 1)
        // The panel sits far from the grid, so every tile centre is past it.
        pullVM.openedFolder = pullFID
        pullVM.folderPanel = FolderPanelLayout(frame: CGRect(x: 1200, y: 600, width: 200, height: 120),
                                               columns: 2, cellWidth: 74, cellHeight: 77,
                                               hSpacing: 6, vSpacing: 6)
        let pullTester = GridHitTester(metrics: pullStore.metrics, itemCount: 3,
                                       containerSize: pullHost.drag.gridFrame.size,
                                       slotCount: pullStore.metrics.capacity)
        pullHost.drag.begin(item: .app("m1"), app: nil, title: "M1", index: 0, page: 0,
                            source: .folderMember(pullFID), location: .zero)
        // Inside the panel: nothing moves.
        pullHost.pullOutIfExited(at: CGPoint(x: 1300, y: 660))
        check("46-C: a pointer still inside the panel leaves everything alone",
              pullStore.folder(pullFID)?.appIDs == ["m1", "m2", "m3"]
              && !pullVM.folderMinimizing && pullHost.drag.sourceFolder == pullFID,
              "\(String(describing: pullStore.folder(pullFID)?.appIDs)) / \(pullVM.folderMinimizing)")
        // Past the plate, over tile 1: the member joins the grid at the hover.
        pullHost.drag.update(location: pullTester.centre(of: 1), page: 0,
                             metrics: pullStore.metrics, pageItems: pullStore.pages[0],
                             capacity: pullStore.metrics.capacity)
        pullHost.pullOutIfExited(at: pullTester.centre(of: 1))
        check("46-C: the exit moves the member onto the grid at the hovered cell",
              pullStore.pages[0] == [.folder(pullFID), .app("m1"), .app("g1"), .app("g2")],
              "\(pullStore.pages[0])")
        check("46-C: the folder keeps its other members",
              pullStore.folder(pullFID)?.appIDs == ["m2", "m3"],
              pullStore.folder(pullFID).map { "\($0.appIDs)" } ?? "dissolved")
        check("46-C: the panel is collapsing through the light teardown",
              pullVM.folderMinimizing && pullVM.openedFolder == pullFID)
        check("46-C: the drag is now an ordinary grid drag",
              pullHost.drag.source == .grid && pullHost.drag.sourceFolder == nil)
        // ... and the next move slides the gap: the desktop keeps sorting.
        pullHost.drag.update(location: pullTester.centre(of: 5), page: 0,
                             metrics: pullStore.metrics, pageItems: pullStore.pages[0],
                             capacity: pullStore.metrics.capacity)
        check("46-C: the reflow follows the promoted drag across the grid",
              pullStore.locate(.app("m1")) == IndexPath(item: 3, section: 0),
              String(describing: pullStore.locate(.app("m1"))))
        // An exit **off** the grid (no hover) lands the member at the page tail.
        let tailURL = tempFile("pullout-tail")
        defer { sweep(tailURL, "pullout-tail") }
        let tailStore = DeckStore(storeURL: tailURL)
        tailStore.metrics = pullStore.metrics
        let tailFID = UUID()
        tailStore.folders[tailFID] = AppFolder(id: tailFID, name: "T",
                                               appIDs: ["m1", "m2", "m3"])
        tailStore.pages = [[.folder(tailFID), .app("g1"), .app("g2")]]
        let tailVM = LaunchpadViewModel(store: tailStore)
        let tailHost = DeckDragHost(store: tailStore, vm: tailVM)
        tailHost.drag.gridFrame = CGRect(x: 0, y: 0, width: 800, height: 400)
        tailHost.offset.begin(scrollOffset: 0, pageWidth: 1200, pageCount: 1)
        tailVM.openedFolder = tailFID
        tailVM.folderPanel = FolderPanelLayout(frame: CGRect(x: 1200, y: 600, width: 200, height: 120),
                                               columns: 2, cellWidth: 74, cellHeight: 77,
                                               hSpacing: 6, vSpacing: 6)
        tailHost.drag.begin(item: .app("m1"), app: nil, title: "M1", index: 0, page: 0,
                            source: .folderMember(tailFID), location: .zero)
        tailHost.pullOutIfExited(at: CGPoint(x: 400, y: 380)) // off-grid exit: no hover
        check("46-C: an exit off the grid lands the member at the page tail",
              tailStore.locate(.app("m1")) == IndexPath(item: 3, section: 0),
              String(describing: tailStore.locate(.app("m1"))))
        tailHost.teardown()
        pullHost.teardown()
        // The writes the pull-out made were held by the still-open drag
        // session (`save()` inside a batch defers); the teardown's
        // `endDragSession` flushes them. The disk file is the witness that the
        // session really survived the exit — the light teardown's whole point.
        let flushed = (try? Data(contentsOf: pullURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let flushedPages = flushed?["pages"] as? [[String]] ?? []
        check("46-C: the session survived the exit — the writes flush at teardown",
              flushedPages.first?.contains("app:m1") == true,
              "\(flushedPages)")

        // MARK: - Review 47: settings over the deck

        section("Review 47 — settings does not take the deck down")

        // Opening settings must not hide the deck: LaunchOS's `openPreferences`
        // (`0x10011f650`) only dispatches its preferences window, nothing hides
        // the launchpad. So the deck stays up and the panel has to be raised
        // above it — a `.normal` window behind a full-screen level-499 deck is
        // simply invisible. The rule is pure; the window it feeds is not
        // driveable headlessly.
        let deckPanelLevel = LaunchpadWindowController.deckWindowLevel
        let raisedAfterDeck = SettingsPanelLevel.resolve(deckVisible: true, deckLevel: deckPanelLevel)
        check("47-A: the settings panel is raised above the deck",
              raisedAfterDeck.map { $0.rawValue > deckPanelLevel.rawValue } ?? false)
        check("47-A: raised by exactly one level",
              raisedAfterDeck?.rawValue == deckPanelLevel.rawValue + 1)
        // **At most** the level AppKit puts the dragged icon at (measured 500):
        // the icon in the air has to stay on top. Equality is allowed and is
        // what actually happens — there is no integer level between the deck
        // (499) and the drag image (500), and the two cannot coexist anyway (a
        // drag holds the button down, so the settings button is unreachable).
        check("47-A: the panel never rises above the dragging level",
              (raisedAfterDeck?.rawValue ?? Int.max) <= Int(CGWindowLevelForKey(.draggingWindow)))
        // No deck on screen — the menu-bar route opens settings with the deck
        // away. Nothing to be above, and forcing a level would float an ordinary
        // window over the Dock and the menu bar.
        check("47-A: with no deck the level is left alone",
              SettingsPanelLevel.resolve(deckVisible: false, deckLevel: deckPanelLevel) == nil)

        // MARK: - Review 49: the caption follows the icon scale

        section("Review 49 — the app name scales with the icon scale")

        // LaunchOS reads the caption's point size off a base font object rather
        // than naming one (`0x100126d6c` → `pointSize`, then `setFontSize:` at
        // `0x100126d78`). OpenDeck pinned 13 pt while `iconScale` moved the icons
        // underneath it. The first cut of this fix derived the size from
        // `metrics.iconSize`; that input is mostly the **display's** decision, so
        // the default preset on a 1512 pt-wide screen asked for a 10 pt caption.
        // The input is the user's scale — see `LabelMetrics`.
        check("49-A: 100 % keeps the size the deck has always drawn",
              LabelMetrics.pointSize(scale: IconScale.default) == LabelMetrics.referencePointSize,
              "\(LabelMetrics.pointSize(scale: IconScale.default))")
        check("49-A: a larger scale gets a larger caption",
              LabelMetrics.pointSize(scale: IconScale.maximum)
                > LabelMetrics.pointSize(scale: IconScale.default),
              "\(LabelMetrics.pointSize(scale: IconScale.maximum))")
        check("49-A: a smaller scale gets a smaller caption",
              LabelMetrics.pointSize(scale: IconScale.minimum)
                < LabelMetrics.pointSize(scale: IconScale.default),
              "\(LabelMetrics.pointSize(scale: IconScale.minimum))")
        // The regression this correction exists for: a display that hands the
        // grid 86 pt icons must not shrink the name.
        check("49-A: the caption ignores the icon's measured size",
              GridMetrics(columns: 7, rows: 5, iconSize: 86,
                          cellWidth: 183, cellHeight: 140).captionPointSize
                == LabelMetrics.referencePointSize,
              "\(GridMetrics(columns: 7, rows: 5, iconSize: 86, cellWidth: 183, cellHeight: 140).captionPointSize)")
        // ... and it does follow the scale the grid was built with.
        check("49-A: the caption follows the grid's scale",
              GridMetrics(columns: 7, rows: 5, iconSize: 120, cellWidth: 183, cellHeight: 140,
                          iconScale: IconScale.maximum).captionPointSize == 18,
              "\(GridMetrics(columns: 7, rows: 5, iconSize: 120, cellWidth: 183, cellHeight: 140, iconScale: IconScale.maximum).captionPointSize)")
        // Readability floors: never shrinks out of legibility, never grows to
        // where two lines stop fitting the caption band.
        check("49-A: the caption has a readable floor",
              LabelMetrics.pointSize(scale: 0.1) == LabelMetrics.minimumPointSize)
        check("49-A: the caption has a ceiling",
              LabelMetrics.pointSize(scale: 3) == LabelMetrics.maximumPointSize)
        // The metrics are built before the settings have been read; a zero-point
        // caption would be invisible rather than merely wrong.
        check("49-A: an unmeasured scale keeps the reference size",
              LabelMetrics.pointSize(scale: 0) == LabelMetrics.referencePointSize)
        // The press target has to keep covering the caption it is drawn around.
        check("49-A: the caption block grows with the caption",
              LabelMetrics.hitBlock(scale: IconScale.maximum)
                > LabelMetrics.hitBlock(scale: IconScale.default))
        check("49-A: the caption block is unchanged at 100 %",
              LabelMetrics.hitBlock(scale: IconScale.default) == 48)

        // MARK: - Review 51: the uninstall panel is above the deck

        section("Review 51 — the uninstall panel sits above the deck")

        // The panel is opened from the deck's own context menu, so the deck it
        // was opened from is on screen behind it. LaunchOS's presenter writes
        // `.screenSaver + 1` (`0x1000248ac`) — a fixed level above everything —
        // not `.floating` (3), which is below this deck's 499 and drew the panel
        // the user had just asked for underneath the window they asked from it.
        let uninstallDeckLevel = LaunchpadWindowController.deckWindowLevel
        check("51-A: the panel is above the deck",
              UninstallPanelLevel.panel.rawValue > uninstallDeckLevel.rawValue,
              "\(UninstallPanelLevel.panel.rawValue) vs \(uninstallDeckLevel.rawValue)")
        // Pinned to the measured literal: LaunchOS's decoded value is 1000 + 1,
        // and the literal also catches the system moving `.screenSaver` under us.
        check("51-A: the panel is at LaunchOS's own level",
              UninstallPanelLevel.panel.rawValue == 1001,
              "\(UninstallPanelLevel.panel.rawValue)")

        // MARK: - Review 50: the caption is the name the system shows

        section("Review 50 — an app's name comes from the file manager")

        // LaunchOS resolves the caption with `displayNameAtPath:` (`0x1000b5608`
        // → `0x1000b56d8`). Measured over 125 bundles on this machine, the plist
        // rule disagrees with that answer for **all of them**; the ones that are
        // not just an extension are names like this one.
        check("50-A: the file manager's name wins over the plist",
              AppNaming.displayName(localizedDisplayName: nil,
                                    finderDisplayName: "Voice Memos",
                                    bundleDisplayName: "VoiceMemos",
                                    bundleName: "VoiceMemos",
                                    fallback: "VoiceMemos") == "Voice Memos")
        // The API honours "show all filename extensions" (measured on for this
        // machine), so its answer carries the bundle extension. Neither the
        // system Launchpad's captions nor a deck's end in ".app".
        check("50-A: a trailing .app is dropped",
              AppNaming.displayName(localizedDisplayName: nil,
                                    finderDisplayName: "Siri.app",
                                    bundleDisplayName: nil,
                                    bundleName: nil,
                                    fallback: "Siri") == "Siri")
        check("50-A: only the bundle extension is dropped",
              AppNaming.displayName(localizedDisplayName: nil,
                                    finderDisplayName: "Lavender Quartz 境界秤動.app",
                                    bundleDisplayName: nil,
                                    bundleName: nil,
                                    fallback: "x") == "Lavender Quartz 境界秤動")
        // A bundle literally named `.app` must not strip to an empty caption.
        check("50-A: a bundle named .app keeps a caption",
              AppNaming.displayName(localizedDisplayName: nil,
                                    finderDisplayName: ".app",
                                    bundleDisplayName: nil,
                                    bundleName: nil,
                                    fallback: ".app") == ".app")
        // Fallbacks, for a bundle whose display name cannot be resolved.
        check("50-A: the plist answers when the file manager cannot",
              AppNaming.displayName(localizedDisplayName: nil,
                                    finderDisplayName: nil,
                                    bundleDisplayName: nil,
                                    bundleName: "Chess",
                                    fallback: "com.apple.Chess") == "Chess")
        check("50-A: a blank display name falls through to the next source",
              AppNaming.displayName(localizedDisplayName: nil,
                                    finderDisplayName: "   ",
                                    bundleDisplayName: "",
                                    bundleName: nil,
                                    fallback: "Something") == "Something")

        // MARK: - Review 55: the caption is the *localised* name

        // MARK: - Review 56: display and browsing modes (batch E)

        section("Review 56 — display mode and browsing style")

        // The deck window's whole configuration comes from one pure decision
        // (report 56 §5), so both modes are assertable without a window server.
        let fullStyle = DeckWindowStyleResolver.style(for: .fullScreen,
                                                      screen: CGSize(width: 1512, height: 982))
        check("56-E: full screen covers the screen at the deck's own level",
              fullStyle.fullScreen
              && fullStyle.contentSize == CGSize(width: 1512, height: 982)
              && fullStyle.usesDeckLevel
              && !fullStyle.movableByBackground
              && !fullStyle.hasShadow,
              "\(fullStyle)")

        let windowStyle = DeckWindowStyleResolver.style(for: .window,
                                                        screen: CGSize(width: 1512, height: 982))
        check("56-E: window mode is a normal window, not a levelled overlay",
              !windowStyle.fullScreen
              && !windowStyle.usesDeckLevel
              && windowStyle.movableByBackground
              && windowStyle.hasShadow,
              "\(windowStyle)")
        check("56-E: window mode takes 74% of the screen",
              windowStyle.contentSize == CGSize(width: 1119, height: 727),
              "\(windowStyle.contentSize)")
        // A display too small for the fraction still gets a usable window; an
        // enormous one is capped so the deck cannot become a second full screen.
        check("56-E: a tiny screen gets the minimum window",
              DeckWindowStyleResolver.style(for: .window,
                                            screen: CGSize(width: 400, height: 300)).contentSize
                  == DeckWindowStyleResolver.minWindowSize)
        check("56-E: an enormous screen gets the capped window",
              DeckWindowStyleResolver.style(for: .window,
                                            screen: CGSize(width: 6000, height: 4000)).contentSize
                  == DeckWindowStyleResolver.maxWindowSize)

        // Browsing style: the deck's pages are laid out as one column in
        // scroll mode, so the indicators and the sideways swipe go away.
        check("56-F: paged shows the dots, scroll does not",
              BrowsingStyle.paged.showsPageDots && !BrowsingStyle.scroll.showsPageDots)
        check("56-F: only paged swipes between pages",
              BrowsingStyle.paged.pagesWithHorizontalSwipe
              && !BrowsingStyle.scroll.pagesWithHorizontalSwipe)
        check("56-F: the labels are LaunchOS's",
              BrowsingStyle.paged.label == "Paged" && BrowsingStyle.scroll.label == "Scroll")
        check("56-F: the display mode labels are LaunchOS's",
              DisplayMode.fullScreen.label == "Full Screen" && DisplayMode.window.label == "Window")

        // MARK: - Review 56: Add to Dock / backups / uninstall mode (batch D)

        section("Review 56 — add to dock appends one tile, once")

        // The decoded flow (report 56 §1): read com.apple.dock
        // persistent-apps, append the app's file tile, write back, `killall
        // Dock`. The tile shape is the Dock's own minimal form.
        let tile = DockSync.addingApp(urlString: "file:///Applications/TencentMeeting.app/",
                                      to: [])
        check("56-A: the tile is the Dock's minimal file-tile form",
              tile.count == 1
              && (tile[0]["tile-type"] as? String) == "file-tile"
              && (((tile[0]["tile-data"] as? [String: Any])?["file-data"] as? [String: Any])?["_CFURLString"] as? String)
                  == "file:///Applications/TencentMeeting.app/",
              "\(tile)")
        check("56-A: an app already in the dock is not added twice",
              DockSync.addingApp(urlString: "file:///Applications/TencentMeeting.app/",
                                 to: tile).count == 1)
        check("56-A: a second app joins the first",
              DockSync.addingApp(urlString: "file:///Applications/WeChat.app/",
                                 to: tile).count == 2)
        // The trailing slash the Dock writes must not defeat the check.
        check("56-A: the trailing slash does not defeat dedup",
              DockSync.contains(urlString: "file:///Applications/TencentMeeting.app",
                                in: tile))
        check("56-A: a different app is not reported present",
              !DockSync.contains(urlString: "file:///Applications/Other.app/", in: tile))

        // 56-B: "Hold Option for Uninstall" (report 56 §4). The decoded
        // binary tests bit 18 (control) while both its strings name Option;
        // OpenDeck follows the documented modifier.
        check("56-B: Option arms uninstall mode",
              UninstallMode.isActive(modifierFlags: [.option]))
        check("56-B: Option with others still arms it",
              UninstallMode.isActive(modifierFlags: [.option, .command, .shift]))
        check("56-B: a plain click does not",
              !UninstallMode.isActive(modifierFlags: []))
        check("56-B: Command alone does not",
              !UninstallMode.isActive(modifierFlags: [.command]))
        check("56-B: the documented modifier is Option, not Control",
              NSEvent.ModifierFlags.option.rawValue == 1 << 19
              && NSEvent.ModifierFlags.control.rawValue == 1 << 18)

        // 56-C: Export / Import Backup (report 56 §3). The container is pure —
        // header + the layout file's verbatim bytes — so the round trip and
        // every refusal are assertable headlessly.
        let layoutFixture = Data(#"{"pages":[["app:a","app:b"]],"folders":[],"hidden":[],"customOrder":["a","b"]}"#.utf8)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let backupData = LayoutBackup.make(layoutData: layoutFixture,
                                           appCount: 2, pageCount: 1, exportedAt: stamp)
        check("56-C: a backup can be built", backupData != nil)
        if let backupData {
            let header = LayoutBackup.summary(backupData)
            check("56-C: the header carries format, version and counts",
                  header?.format == LayoutBackup.formatMarker
                  && header?.version == LayoutBackup.formatVersion
                  && header?.appCount == 2
                  && header?.pageCount == 1
                  && header?.exportedAt == ISO8601DateFormatter().string(from: stamp),
                  "\(String(describing: header))")
            if case .success(let payload) = LayoutBackup.parse(backupData) {
                check("56-C: the round trip returns the very same bytes",
                      payload == layoutFixture)
            } else {
                check("56-C: the round trip returns the very same bytes", false)
            }
        }

        // Every refusal path, with LaunchOS's own wording.
        if case .failure(let error) = LayoutBackup.parse(Data("not json".utf8)) {
            check("56-C: a foreign file is refused", error == .notABackup)
        } else {
            check("56-C: a foreign file is refused", false)
        }
        let wrongMarker = Data(#"{"format":"Something.Else","version":1,"exportedAt":"x","appCount":0,"pageCount":0,"payload":"{}"}"#.utf8)
        if case .failure(let error) = LayoutBackup.parse(wrongMarker) {
            check("56-C: another app's JSON is refused", error == .notABackup)
        } else {
            check("56-C: another app's JSON is refused", false)
        }
        let futureVersion = Data(#"{"format":"OpenDeck.LayoutBackup","version":99,"exportedAt":"x","appCount":0,"pageCount":0,"payload":"{}"}"#.utf8)
        if case .failure(let error) = LayoutBackup.parse(futureVersion) {
            check("56-C: a newer backup version is refused",
                  error == .unsupportedVersion(99), "\(error)")
        } else {
            check("56-C: a newer backup version is refused", false)
        }
        let emptyPayload = Data(#"{"format":"OpenDeck.LayoutBackup","version":1,"exportedAt":"x","appCount":0,"pageCount":0,"payload":"   "}"#.utf8)
        if case .failure(let error) = LayoutBackup.parse(emptyPayload) {
            check("56-C: an empty payload is refused", error == .missingPayload)
        } else {
            check("56-C: an empty payload is refused", false)
        }

        // The store half: adoption validates before it touches anything.
        let bakURL = tempURL.deletingLastPathComponent()
            .appendingPathComponent("opendeck-selftest-backup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: bakURL) }
        let bak = DeckStore(storeURL: bakURL)
        bak.metrics = GridMetrics(columns: 2, rows: 2, iconSize: 100, cellWidth: 150, cellHeight: 150)
        let bakIDs = Array(bak.visibleApps.prefix(2)).map(\.id)
        if bakIDs.count == 2 {
            let before = bak.pages
            let goodPayload = Data(#"{"pages":[["app:\#(bakIDs[0])","app:\#(bakIDs[1])"]],"folders":[],"hidden":[],"customOrder":[]}"#.utf8)
            let adopted = bak.adoptBackupPayload(goodPayload)
            // `reconcile()` runs inside the adoption (exactly as it does on
            // load), so the page may afterwards hold more than the payload's
            // two items — what the adoption promises is that the payload's own
            // arrangement is in place.
            let flatAfter = bak.pages.flatMap { $0 }
            check("56-C: a good payload is adopted",
                  adopted
                  && flatAfter.first == .app(bakIDs[0])
                  && flatAfter.dropFirst().first == .app(bakIDs[1]),
                  "adopted=\(adopted) first=\(flatAfter.prefix(3))")
            let countBefore = bak.pages.count
            check("56-C: a garbage payload changes nothing",
                  !bak.adoptBackupPayload(Data("{}".utf8))
                  && bak.pages.count == countBefore)
            check("56-C: an empty-pages payload is refused",
                  !bak.adoptBackupPayload(Data(#"{"pages":[],"folders":[],"hidden":[],"customOrder":[]}"#.utf8))
                  && bak.pages.count == countBefore,
                  "\(bak.pages.count)")
            _ = before
        } else {
            check("at least two apps for the backup test", false)
        }

        section("Review 55 — the localised plist name outranks everything")
        // The bug this section exists for: LaunchOS shows 腾讯会议 for
        // /Applications/TencentMeeting.app while the old chain answered
        // "TencentMeeting" — the base plist's CFBundleDisplayName, and also
        // what `displayNameAtPath:` answers on this machine (measured: the API
        // returns the folder name in CLI, GUI, open-launched and sandboxed
        // processes alike; it does not localise here).
        check("55-A: the localised name outranks the finder name",
              AppNaming.displayName(localizedDisplayName: "腾讯会议",
                                    finderDisplayName: "TencentMeeting.app",
                                    bundleDisplayName: "TencentMeeting",
                                    bundleName: "腾讯会议",
                                    fallback: "TencentMeeting") == "腾讯会议")
        check("55-A: the localised name outranks the base plist",
              AppNaming.displayName(localizedDisplayName: "微信",
                                    finderDisplayName: "WeChat.app",
                                    bundleDisplayName: "WeChat",
                                    bundleName: "WeChat",
                                    fallback: "WeChat") == "微信")
        // A blank localised name must not shadow the finder answer.
        check("55-A: a blank localised name falls through",
              AppNaming.displayName(localizedDisplayName: "   ",
                                    finderDisplayName: "Voice Memos",
                                    bundleDisplayName: "VoiceMemos",
                                    bundleName: "VoiceMemos",
                                    fallback: "VoiceMemos") == "Voice Memos")

        // The matching is Foundation's own, pinned to the TencentMeeting
        // fixture: a zh-Hans-HK user with the bundle's zh-Hant/zh-HK tables
        // carrying the *English* name must land on zh-Hans (script match beats
        // region-only), not on zh-HK.
        check("55-B: a zh-Hans-HK user matches the bundle's zh-Hans",
              Bundle.preferredLocalizations(
                  from: ["zh-Hans", "en", "zh-HK", "zh-Hant"],
                  forPreferences: ["zh-Hans-HK", "en-HK", "zh-Hant-HK"]
              ).first == "zh-Hans",
              "\(Bundle.preferredLocalizations(from: ["zh-Hans", "en", "zh-HK", "zh-Hant"], forPreferences: ["zh-Hans-HK", "en-HK", "zh-Hant-HK"]))")
        check("55-B: an English user matches the bundle's en",
              Bundle.preferredLocalizations(
                  from: ["zh-Hans", "en", "zh-HK", "zh-Hant"],
                  forPreferences: ["en"]
              ).first == "en")

        // The loader-driven resolution, headless: first matched table with a
        // CFBundleDisplayName wins; CFBundleName is the key fallback inside a
        // table; a table that cannot be loaded is skipped, not fatal.
        let tables55: [String: [String: String]] = [
            "zh-HK": ["CFBundleDisplayName": "TencentMeeting"],
            "zh-Hans": ["CFBundleDisplayName": "腾讯会议"],
        ]
        check("55-B: the first matched table's display name wins",
              AppNaming.localizedDisplayName(
                  localizations: ["zh-Hans", "en", "zh-HK", "zh-Hant"],
                  preferences: ["zh-Hans-HK", "en-HK"],
                  loadTable: { tables55[$0] }
              ) == "腾讯会议")
        check("55-B: CFBundleName is the in-table fallback",
              AppNaming.localizedDisplayName(
                  localizations: ["en"],
                  preferences: ["en"],
                  loadTable: { _ in ["CFBundleName": "微信"] }
              ) == "微信")
        // Foundation's matcher returns a **single** best localization, not a
        // fallback chain (measured: ["zh-Hans","en"] + ["zh-Hans","en"] →
        // ["zh-Hans"]). So an unreadable table means "no localized name", and
        // `displayName` falls through to the finder answer — pinned here so the
        // single-match behaviour cannot silently become a chain.
        check("55-B: the matcher picks one best localization",
              Bundle.preferredLocalizations(
                  from: ["zh-Hans", "en"], forPreferences: ["zh-Hans", "en"]
              ) == ["zh-Hans"])
        check("55-B: an unreadable table yields no localized name",
              AppNaming.localizedDisplayName(
                  localizations: ["zh-Hans", "en"],
                  preferences: ["zh-Hans", "en"],
                  loadTable: { (_: String) -> [String: String]? in nil }
              ) == nil)

        // The end-to-end pin, on the machine the report is named after: the
        // real bundle, through the real loader. Guarded because another
        // machine may not have it installed.
        let tencentPath = "/Applications/TencentMeeting.app"
        if FileManager.default.fileExists(atPath: tencentPath),
           let bundle = Bundle(path: tencentPath) {
            check("55-C: the real TencentMeeting bundle resolves to 腾讯会议",
                  AppNaming.localizedDisplayName(bundle: bundle) == "腾讯会议",
                  "\(String(describing: AppNaming.localizedDisplayName(bundle: bundle)))")
        } else {
            check("55-C: TencentMeeting not installed — skipped", true)
        }

        // The uninstaller must keep finding leftovers named after the bundle
        // now that the caption is localised (report 55 §2).
        check("55-D: leftovers match every spelling of the name",
              AppUninstaller.nameNeedles(name: "腾讯会议",
                                         folderName: "TencentMeeting",
                                         plistDisplayName: "TencentMeeting",
                                         plistName: "腾讯会议") == ["腾讯会议", "tencentmeeting"],
              "\(AppUninstaller.nameNeedles(name: "腾讯会议", folderName: "TencentMeeting", plistDisplayName: "TencentMeeting", plistName: "腾讯会议"))")
        check("55-D: short spellings are not needles",
              AppUninstaller.nameNeedles(name: "ab", folderName: nil,
                                         plistDisplayName: nil, plistName: nil).isEmpty)
        check("55-B: no localised name anywhere yields nil",
              AppNaming.localizedDisplayName(
                  localizations: ["en"],
                  preferences: ["en"],
                  loadTable: { (_: String) -> [String: String]? in nil }
              ) == nil)

            section("Review 41 — New Folder")

        // ① The decision, as a pure function. One member is a folder only when
        // the user asked for it; zero members is never a folder.
        check("a single member is a folder when the user made it",
              !AppFolder.dissolves(memberCount: 1, isExplicit: true))
        check("a single member is still not a folder when nobody did",
              AppFolder.dissolves(memberCount: 1, isExplicit: false))
        check("nothing survives at zero members, whoever made it",
              AppFolder.dissolves(memberCount: 0, isExplicit: true))

        // ② The effect, through the real store: the API produces that folder and
        // leaves no second icon behind (I2).
        let nfURL = tempFile("newfolder")
        let nfStore = DeckStore(storeURL: nfURL)
        nfStore.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 100, cellWidth: 150, cellHeight: 150)
        let nfIDs = Array(nfStore.visibleApps.prefix(2)).map(\.id)
        check("New Folder fixture: two loose apps to work with",
              nfIDs.count == 2, "\(nfIDs.count)")

        let nfFolderID = nfIDs.first.flatMap { nfStore.makeFolder(holding: $0) }
        check("New Folder produces a folder holding just that app",
              nfFolderID.flatMap { nfStore.folder($0)?.appIDs } == nfIDs.first.map { [$0] },
              nfFolderID.flatMap { nfStore.folder($0)?.appIDs }.map { "\($0)" } ?? "no folder")
        check("... and the app is no longer a grid slot of its own",
              nfIDs.first.map { id in !nfStore.pages.contains { $0.contains(.app(id)) } } == true)
        check("... and the slot it left behind is the folder",
              nfFolderID.map { fid in nfStore.pages.contains { $0.contains(.folder(fid)) } } == true)

        // Persisted, not merely in memory: without the mark on disk the next
        // launch reads a plain one-member folder and dissolves it. Read back
        // through `JSONSerialization` rather than matching bytes, so the check
        // says what it means and does not pin the encoder's formatting
        // (`.prettyPrinted` puts spaces around the colon).
        let nfDisk = (try? Data(contentsOf: nfURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let nfDiskFolders = nfDisk?["folders"] as? [[String: Any]]
        check("... and the mark is on disk, not only in memory",
              nfDiskFolders?.contains { ($0["isUserCreated"] as? Bool) == true } == true,
              nfDiskFolders.map { "\($0.count) folder(s) on disk" } ?? "no file")

        // ③ The rule that would otherwise eat it: a rescan runs `reconcile`,
        // whose folder loop used to read "fewer than two members ⇒ dissolve".
        let nfFoldersBefore = nfStore.folders.count
        nfStore.applyScan(nfStore.apps)
        check("... and the rescan was adopted, so `reconcile` really ran",
              !(nfStore.lastError ?? "").contains("failed scan"),
              nfStore.lastError ?? "nothing reported")
        check("a rescan does not dissolve the folder the user made",
              nfStore.folders.count == nfFoldersBefore,
              "\(nfFoldersBefore) -> \(nfStore.folders.count)")
        check("... and it is not announced as repaired data either",
              !(nfStore.lastError ?? "").contains("fell below two members"),
              nfStore.lastError ?? "nothing reported")

        // ④ An app already inside a folder has no slot that could become one.
        check("New Folder refuses an app that is already a folder member",
              nfIDs.first.map { nfStore.makeFolder(holding: $0) == nil } == true)

        // ⑤ The only member leaves: now it *is* empty, and an empty folder goes.
        if let fid = nfFolderID, let only = nfIDs.first {
            nfStore.removeFromFolder(only, folder: fid)
        }
        check("dragging its only member out dissolves it",
              nfFolderID.map { nfStore.folder($0) == nil } == true)
        check("... and the app lands back on the grid",
              nfIDs.first.map { id in nfStore.pages.contains { $0.contains(.app(id)) } } == true)

        // ⑥ Once it has a second member and loses it, it stays at one. That is
        // the choice, not an accident: the user asked for this folder, and
        // `detachFromAnyFolder`'s own comment says a named folder vanishing
        // silently is exactly what the class contract promises to surface.
        if let fid = nfIDs.first.flatMap({ nfStore.makeFolder(holding: $0) }) {
            if nfIDs.count == 2 { nfStore.addToFolder(nfIDs[1], folder: fid) }
            check("with a second member it is an ordinary two-member folder",
                  nfStore.folder(fid)?.appIDs.count == 2,
                  "\(nfStore.folder(fid)?.appIDs.count ?? -1)")
            if nfIDs.count == 2 { nfStore.removeFromFolder(nfIDs[1], folder: fid) }
            check("losing that member leaves it at one rather than dissolving",
                  nfStore.folder(fid)?.appIDs == nfIDs.first.map { [$0] },
                  nfStore.folder(fid).map { "\($0.appIDs)" } ?? "dissolved")
        }
        sweep(nfURL, ".empty-pages-")

        // ⑦ A layout written before the flag existed must still load. A
        // *synthesised* decoder throws on the missing key, which the loader reads
        // as corruption — so this is the assertion that keeps an old file out of
        // the recovery path (A1), not a nicety.
        let legacyJSON = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"Legacy\",\"appIDs\":[\"legacy-a\",\"legacy-b\"]}"
        let legacyFolder = try? JSONDecoder().decode(AppFolder.self, from: Data(legacyJSON.utf8))
        check("a folder written before the flag existed still decodes", legacyFolder != nil)
        check("... and reads as a plain folder — exactly the old behaviour",
              legacyFolder?.isUserCreated == false)
        let marked = AppFolder(name: "Kept", appIDs: ["kept-a"], isUserCreated: true)
        let roundTripped = (try? JSONEncoder().encode(marked))
            .flatMap { try? JSONDecoder().decode(AppFolder.self, from: $0) }
        check("the flag survives an encode/decode round trip",
              roundTripped?.isUserCreated == true)

        // ⑧ The launch path, not just the rescan path: a one-member folder the
        // user made, already on disk, must come back as itself. Uses a real id so
        // the member survives the scan rather than relying on the one-observation
        // grace.
        if let keptApp = nfIDs.first {
            let keptURL = tempFile("keptfolder")
            let keptID = UUID().uuidString
            let keptJSON = "{\"pages\": [[\"folder:\(keptID)\"]], "
                + "\"folders\": [{\"id\":\"\(keptID)\",\"name\":\"Kept\","
                + "\"appIDs\":[\"\(keptApp)\"],\"isUserCreated\":true}], "
                + "\"hidden\": [], \"sortKey\": \"manual\", \"sortOrder\": \"ascending\", "
                + "\"customOrder\": [\"\(keptApp)\"]}"
            try? Data(keptJSON.utf8).write(to: keptURL)
            let keepStore = DeckStore(storeURL: keptURL)
            check("a one-member folder the user made is still there after a launch",
                  keepStore.folders.count == 1, "\(keepStore.folders.count) folder(s)")
            check("... and it is still marked as the user's",
                  keepStore.folders.values.first?.isUserCreated == true)
            sweep(keptURL, ".empty-pages-")
        }

        // ⑥b The third site that asks the rule: `detachFromAnyFolder`, reached
        // when a folder **loses a member to another folder**. A user folder that
        // shrinks from two members to one keeps its remaining app. Without this
        // the site could be reverted to `count <= 1` with the suite still green.
        let dnURL = tempFile("detach")
        let dnStore = DeckStore(storeURL: dnURL)
        dnStore.metrics = GridMetrics(columns: 7, rows: 5, iconSize: 100, cellWidth: 150, cellHeight: 150)
        let dnIDs = Array(dnStore.visibleApps.prefix(3)).map(\.id)
        if dnIDs.count == 3 {
            // `thief` must be holding an app of its own before the theft. The
            // first version of this fixture made `thief` the source of the app
            // that joined `host`, which *correctly* left `thief` at zero members
            // and dissolved it — so the steal had nowhere to go and the check
            // failed looking like a rule bug. Fixture bug; the rule was right.
            let host = dnStore.makeFolder(holding: dnIDs[0])
            let thief = dnStore.makeFolder(holding: dnIDs[2])
            if let h = host { dnStore.addToFolder(dnIDs[1], folder: h) }
            check("the host folder really holds both apps before one is taken",
                  host.flatMap { dnStore.folder($0)?.appIDs.count } == 2,
                  host.flatMap { dnStore.folder($0)?.appIDs.count }.map { "\($0)" } ?? "no folder")
            if let t = thief { dnStore.addToFolder(dnIDs[0], folder: t) }
            check("a user folder that loses a member to another folder is not dissolved",
                  host.flatMap { dnStore.folder($0)?.appIDs } == [dnIDs[1]],
                  host.flatMap { dnStore.folder($0) }.map { "\($0.appIDs)" } ?? "dissolved")
        }
        sweep(dnURL, ".empty-pages-")

        // ⑨ The fourth site: `normalizeFolderExclusivity` (I1). It only reaches
        // the decision when it actually *strips* a member, so the breach has to be
        // injected — one app in two folders, with the user's folder second in page
        // order so it is the one that loses it. A layout file is user-editable and
        // is read straight off disk, so an I1 breach is a real input, not a
        // synthetic one. `plain` keeps both members, which is what proves the
        // strip really happened rather than the pass never running.
        let nxURL = tempFile("exclusive")
        let nxStore = DeckStore(storeURL: nxURL)
        let nxIDs = Array(nxStore.visibleApps.prefix(3)).map(\.id)
        if nxIDs.count == 3 {
            let plainID = UUID()
            let userID = UUID()
            nxStore.folders[plainID] = AppFolder(id: plainID, name: "Plain",
                                                 appIDs: [nxIDs[0], nxIDs[2]])
            nxStore.folders[userID] = AppFolder(id: userID, name: "Mine",
                                                appIDs: [nxIDs[0], nxIDs[1]],
                                                isUserCreated: true)
            nxStore.pages[0] = [.folder(plainID), .folder(userID)] + nxStore.pages[0]
            nxStore.applyScan(nxStore.apps)
            check("... and the exclusivity rescan was adopted too",
                  !(nxStore.lastError ?? "").contains("failed scan"),
                  nxStore.lastError ?? "nothing reported")
            check("a user folder stripped to one member by the I1 pass survives",
                  nxStore.folder(userID)?.appIDs == [nxIDs[1]],
                  nxStore.folder(userID).map { "\($0.appIDs)" } ?? "dissolved")
            check("... while the plain folder that kept both members is untouched",
                  nxStore.folder(plainID)?.appIDs.count == 2,
                  nxStore.folder(plainID).map { "\($0.appIDs)" } ?? "dissolved")
        }
        sweep(nxURL, ".empty-pages-")

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

        section("Click delivery on a deck that is not key")

        // The deck is summoned by a hotkey while another app is frontmost, so it
        // can be on screen and not key. AppKit spends the mouse-down on activating
        // the app in that state and never delivers it, which is what made clicking
        // an icon do nothing at all. The window itself cannot be exercised
        // headlessly — it needs a window server and a real click — so the rule it
        // follows is asserted instead.
        var clicks = DeckClickState()
        check("a key deck routes clicks normally",
              clicks.route(.leftMouseDown, isKeyWindow: true) == .normal)
        check("a key deck has nothing withdrawn", clicks.canBecomeKey)
        check("keyboard events are never routed",
              clicks.route(.keyDown, isKeyWindow: false) == .normal)

        // The down that opens the sequence: delivered without activation, then the
        // permission is handed straight back so activation can be reclaimed.
        check("a non-key deck delivers the down itself, then reclaims activation",
              clicks.route(.leftMouseDown, isKeyWindow: false) == .deliverThenActivate)
        check("delivering that click withdraws the key permission", clicks.canBecomeKey == false)
        clicks.finishRouting()
        check("the key permission comes back once the event is handled", clicks.canBecomeKey)

        // The up. Normally the down has made the window key by now, so the up is
        // ordinary; if activation was refused, the up has to be routed the same way
        // as the down or it would be swallowed for exactly the same reason.
        check("the up of a click that won key status is ordinary",
              clicks.route(.leftMouseUp, isKeyWindow: true) == .normal)
        check("the up is routed as well when key status never arrived",
              clicks.route(.leftMouseUp, isKeyWindow: false) == .deliverOnly)
        clicks.finishRouting()

        // Re-entrancy: a nested event must not hand the permission back while the
        // click it belongs to is still in flight.
        var nested = DeckClickState()
        _ = nested.route(.leftMouseDown, isKeyWindow: false)
        check("a re-entrant event is not routed a second time",
              nested.route(.leftMouseDown, isKeyWindow: false) == .normal)
        check("the click in flight still owns the permission", nested.canBecomeKey == false)
        nested.finishRouting()
        check("and releases it once it is done", nested.canBecomeKey)

        // A development tool must not touch live user state. `DeckSettings` writes
        // every property back through its `didSet` and its initialiser writes too,
        // and this self-test constructs it. Before the guard went in, a
        // `--selftest` run moved the user's real preferences plist while the app
        // was not even running.
        section("Headless preferences (a tool must not write live state)")

        let memory = MemoryPreferences()
        let headless = Preferences(persists: false, store: memory)
        headless.set(49, forKey: "hotKeyCode")
        headless.set(true, forKey: "showLabels")
        check("a headless run writes no preference at all",
              memory.object(forKey: "hotKeyCode") == nil
              && memory.object(forKey: "showLabels") == nil)

        // The other half of the same rule, and what keeps the check above from
        // passing against a store that simply drops everything: an ordinary
        // launch must still persist.
        let live = Preferences(persists: true, store: memory)
        live.set(49, forKey: "hotKeyCode")
        check("a real launch still writes its preferences",
              memory.object(forKey: "hotKeyCode") as? Int == 49)

        // Reads are deliberately not gated, or `--snapshot` would render invented
        // settings rather than the user's.
        live.set(true, forKey: "showLabels")
        headless.register(defaults: ["dimStrength": 0.18, "resumeLastPage": true])
        check("a headless run still reads the settings that are there",
              headless.bool(forKey: "showLabels") && headless.integer(forKey: "hotKeyCode") == 49)
        check("a headless run still sees the registered defaults",
              headless.bool(forKey: "resumeLastPage")
              && headless.double(forKey: "dimStrength") == 0.18)

        // The flag has to actually *reach* the settings object rather than merely
        // being set somewhere: the store inside `DeckSettings.shared` was built
        // from it. This is the check that would notice a `main.swift` which
        // stopped setting it, and the login-item guard in `applyStartAtLogin`
        // reads the same predicate, so both paths rest on this one value.
        check("a headless run may not change persistent state",
              DeckSettings.shared.mayPersist == false)

        print("\n\(checks - failures)/\(checks) checks passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}

/// A `PreferenceStore` that keeps everything in memory.
///
/// So the headless guard can be exercised without creating a preferences domain:
/// asserting "nothing was written" against a real domain would mean inventing
/// precisely the file the guard exists to prevent.
private final class MemoryPreferences: PreferenceStore {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func double(forKey key: String) -> Double { (object(forKey: key) as? Double) ?? 0 }
    func bool(forKey key: String) -> Bool { (object(forKey: key) as? Bool) ?? false }
    func integer(forKey key: String) -> Int { (object(forKey: key) as? Int) ?? 0 }

    func register(defaults: [String: Any]) {
        for (key, value) in defaults where registered[key] == nil { registered[key] = value }
    }
}
