#!/usr/bin/env python3
"""Mutation-test the review-24 fixes.

For each mutation: copy Sources, break exactly one repair, rebuild, run
--selftest, and report which checks FAIL. A mutation that leaves the suite
green means the corresponding check is hollow.
"""
import os
import re
import shutil
import subprocess
import sys

# Derived from this file's own location (Tools/..), so the script works from any
# checkout path rather than one developer's machine.
PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = "/tmp/ldfix/mut"

MUTATIONS = [
    (
        "M1-empty-pages-rotates-backup",
        "DeckStore.swift",
        "suppressNextBackupRotation = true",
        "suppressNextBackupRotation = false",
        "revert fix 1: let the empty-`pages` rebuild rotate its bogus file over `.bak`",
    ),
    (
        "M2-heal-write-result-ignored",
        "DeckStore.swift",
        "guard (try? seams.writeData(backupData, storeURL)) != nil else {",
        "guard true else { // MUTATION: ignore the recovery write's result",
        "revert fix 2: swallow the failed recovery write (the #29/#30 shape)",
    ),
    (
        "M3-preserve-failure-ignored",
        "DeckStore.swift",
        "if !preserved {",
        "if false { // MUTATION: treat a failed preservation as success",
        "revert #30 in the empty-`pages` branch: rebuild over the only copy anyway",
    ),
    (
        "M4-reconcile-always-saves",
        "DeckStore.swift",
        "if persistedState != stateBefore { save() }",
        "save() // MUTATION: unconditional write",
        "revert fix 6: let the automatic rescan persist a display-driven repack",
    ),
    (
        "M5-every-match-preselected",
        "UninstallView.swift",
        "candidate.matchKind == .identifier",
        "true // MUTATION: pre-select every match",
        "revert fix 3: pre-select name-only (cross-vendor) matches too",
    ),
    (
        "M6-save-writes-when-unchanged",
        "DeckStore.swift",
        """            if let onDisk = try? Data(contentsOf: storeURL), onDisk == data {
                return
            }
""",
        "",
        "revert review-26 fix B: let a no-op save write and rotate the backup anyway",
    ),
    (
        "M7-rotation-after-write",
        "DeckStore.swift",
        """            } else {
                rotateBackup()
            }
            try data.write(to: storeURL, options: .atomic)""",
        """            } else {
            }
            try data.write(to: storeURL, options: .atomic)
            rotateBackup() // MUTATION: rotate the new bytes as the "previous" generation""",
        "break the rotate-before-write order: `.bak` stops being the previous generation",
    ),
    (
        "M8-believe-every-scan",
        "DeckStore.swift",
        """    private func shouldAdoptScan(_ scannedIDs: Set<String>) -> Bool {
        let referenced = referencedAppIDs()""",
        """    private func shouldAdoptScan(_ scannedIDs: Set<String>) -> Bool {
        if true { return true } // MUTATION: believe every scan
        let referenced = referencedAppIDs()""",
        "revert review-26 fix A: adopt a partially failed scan as the truth",
    ),
    (
        "M9-launch-path-unscreened",
        "DeckStore.swift",
        """        let scannedIDs = Set(apps.map { $0.id })
        if !shouldAdoptScan(scannedIDs) { return }""",
        """        let scannedIDs = Set(apps.map { $0.id })
        // MUTATION: leave the launch path unscreened""",
        "revert only the reconcile-side guard: the launch (load) path loses its screen",
    ),
    (
        "M10-one-observation-is-an-uninstall",
        "DeckStore.swift",
        "        unconfirmedAbsent = previous.subtracting(scannedIDs)",
        "        unconfirmedAbsent = [] // MUTATION: believe a single missing observation",
        "revert the per-app rule: one missing scan observation dissolves folders and drops marks",
    ),
    (
        "M11-writable-store-may-read-the-pre-rename-file",
        "StateHandover.swift",
        "        guard readOnly, !exists(current), exists(legacy) else { return current }",
        "        guard !exists(current), exists(legacy) else { return current }",
        "revert the readOnly term: a writable store can be routed into the pre-rename folder",
    ),
    (
        "M12-handover-overwrites-the-live-layout",
        "StateHandover.swift",
        "            guard !fm.fileExists(atPath: destination.path),\n"
        "                  fm.fileExists(atPath: source.path) else { continue }",
        "            guard fm.fileExists(atPath: source.path) else { continue }",
        "revert the no-overwrite guard: the older pre-rename copy replaces live state",
    ),
    (
        "M13-report-a-copy-that-never-landed",
        "StateHandover.swift",
        "            if fm.fileExists(atPath: destination.path) { adopted.append(name) }",
        "            adopted.append(name)  // MUTATION: claim success without checking",
        "revert the verification: a failed copy is announced as carried over",
    ),
    (
        "M14-handover-clobbers-an-existing-preference",
        "StateHandover.swift",
        "        for key in keys where current[key] == nil {",
        "        for key in keys {",
        "revert the current-domain term: a preference the user has already set is overwritten",
    ),
    (
        "M15-headless-run-writes-preferences",
        "DeckSettings.swift",
        "        guard persists else { return }\n"
        "        store.set(value, forKey: key)",
        "        store.set(value, forKey: key)  // MUTATION: a tool writes like a real launch",
        "remove the headless guard: --selftest stamps the built-in defaults into the real domain",
    ),
    (
        "M16-jump-in-flight-is-not-arbitrated",
        "PagingState.swift",
        "        guard let target = inFlight else { return page != requested }\n"
        "        guard page == target else { return false }\n"
        "        inFlight = nil\n"
        "        return false",
        "        return page != requested  // MUTATION: ignore a jump in flight",
        "revert the guard: a jump adopts the page it is leaving, and persists it",
    ),
    (
        "M17-arm-with-nowhere-to-go",
        "PagingState.swift",
        "        guard page != reportedPage else {\n"
        "            inFlight = nil\n"
        "            return false\n"
        "        }",
        "        // MUTATION: arm even when the scroll view has nowhere to go",
        "revert the no-movement term: a guard nothing ever clears swallows the next scroll",
    ),
    (
        "M18-a-landed-jump-keeps-claiming",
        "PagingState.swift",
        "        guard page == target else { return false }\n"
        "        inFlight = nil\n"
        "        return false",
        "        guard page == target else { return false }\n"
        "        return false  // MUTATION: a landed jump keeps claiming reports",
        "revert the release: the guard never lets go of a jump that has arrived",
    ),
    (
        "M19-drag-cannot-cancel-a-jump",
        "PagingState.swift",
        "    func disarm() { inFlight = nil }",
        "    func disarm() { }  // MUTATION: a jump never gives up its claim",
        "revert the drag override: a finger no longer outranks an animation in flight",
    ),
    (
        "M20-a-reused-guard-keeps-its-jump",
        "PagingState.swift",
        "    func reset() {\n"
        "        reportedPage = 0\n"
        "        inFlight = nil\n"
        "    }",
        "    func reset() {\n"
        "        // MUTATION: a guard reused by a new grid keeps the old jump\n"
        "    }",
        "revert the reset: a rebuilt grid inherits the previous window's pending jump",
    ),
    (
        "M21-tools-are-not-marked-headless",
        "main.swift",
        '    AppEnvironment.isHeadless = CommandLine.arguments.contains {\n'
        '        ["--selftest", "--bench", "--snapshot"].contains($0)\n'
        '    }',
        '    AppEnvironment.isHeadless = false  // MUTATION: nothing is headless',
        "revert the wiring: the guard exists but no run ever turns it on",
    ),
    (
        "M22-the-key-permission-is-never-given-back",
        "DeckClickState.swift",
        "    mutating func finishRouting() {\n"
        "        isRouting = false\n"
        "    }",
        "    mutating func finishRouting() {\n"
        "        // MUTATION: the permission is never given back\n"
        "    }",
        "revert the release: a deck that delivered one click can never be key again",
    ),
    (
        "M23-clicks-are-routed-even-when-key",
        "DeckClickState.swift",
        "        guard !isRouting, !isKeyWindow else { return .normal }",
        "        guard !isRouting else { return .normal }  // MUTATION: route while key too",
        "revert the key term: every click withdraws the permission, key window or not",
    ),
    # --- review 29: the LaunchOS-parity backlog (grid presets, glass tiers,
    # return-to-home policy, hot-corner conflicts, menu bar icon) ---
    (
        "M24-grid-preset-columns-collapse",
        "GridMetrics.swift",
        "        case .grid10x5, .grid10x6: return 10",
        "        case .grid10x5, .grid10x6: return 9  // MUTATION: two shapes collapse into one",
        "revert the widest preset: the picker offers ten columns but seats nine",
    ),
    (
        "M25-grid-default-is-not-what-macos-shipped",
        "GridMetrics.swift",
        "    static let macOSDefault: GridPreset = .grid7x5",
        "    static let macOSDefault: GridPreset = .grid10x6  // MUTATION: change every default",
        "revert the default: an install that never chose a shape gets a different one",
    ),
    (
        "M26-a-preset-is-never-shrunk-to-fit",
        "GridMetrics.swift",
        "        while columns > 4, usableWidth / CGFloat(columns) < 96 { columns -= 1 }",
        "        while columns > 4, usableWidth / CGFloat(columns) < -1 { columns -= 1 }  // MUTATION",
        "revert the fit rule: a preset too wide for the display hangs off the edges",
    ),
    (
        "M27-glass-tiers-collapse-onto-a-common-material",
        "Backdrop.swift",
        "        case .regular: return .fullScreenUI",
        "        case .regular: return .hudWindow  // MUTATION: change what the default tier is",
        "revert the default tier: the backdrop stops matching what it used to render",
    ),
    (
        "M28-a-glass-backdrop-blurs-the-wallpaper",
        "Backdrop.swift",
        "        case .glass:\n"
        "            return .systemMaterial(glassMaterial)",
        "        case .glass:\n"
        "            return .picture(blurred: true)  // MUTATION: read the desktop and blur it",
        "revert the design: the live deck goes back to extracting and blurring the wallpaper",
    ),
    (
        "M29-the-offscreen-render-blurs-the-desktop",
        "Backdrop.swift",
        "        if offscreen { return .picture(blurred: false) }",
        "        if offscreen { return .picture(blurred: true) }  // MUTATION",
        "revert the offscreen rule: the snapshot fakes the frost by blurring the wallpaper",
    ),
    (
        "M30-a-timed-policy-resumes-with-no-record",
        "ReturnToHome.swift",
        "            guard let closedAt else { return false }",
        "            guard let closedAt else { return true }  // MUTATION: no record counts as recent",
        "revert the missing-record rule: the deck reopens on a page it cannot date",
    ),
    (
        "M31-a-timed-policy-ignores-its-grace",
        "ReturnToHome.swift",
        "            return now.timeIntervalSince(closedAt) <= (grace ?? 0)",
        "            return true  // MUTATION: a timed tier resumes however long ago",
        "revert the grace: every timed tier behaves like `never`",
    ),
    (
        "M32-the-old-boolean-migrates-backwards",
        "DeckSettings.swift",
        "        legacy ? .never : .always",
        "        legacy ? .always : .never  // MUTATION: invert the migration",
        "revert the migration: an upgrade flips the user's saved-state choice",
    ),
    (
        "M33-a-free-corner-reads-as-taken",
        "HotCornersMonitor.swift",
        "        if let value = cornerDefaults[key] as? Int { return value != 0 }",
        "        if let value = cornerDefaults[key] as? Int { return true }  // MUTATION",
        "revert the action test: a corner with no system action is reported as a conflict",
    ),
    (
        "M34-two-corners-read-the-same-key",
        "HotCornersMonitor.swift",
        '        case .topRight: return "wvous-tr-corner"',
        '        case .topRight: return "wvous-tl-corner"  // MUTATION: collide the corner keys',
        "revert the key map: one corner's system action is reported for another",
    ),
    (
        "M35-headless-claims-it-installed-an-icon",
        "MenuBarController.swift",
        "        guard !AppEnvironment.isHeadless else {\n"
        "            // A development tool must not put an icon in the user's menu bar.\n"
        "            return false\n"
        "        }",
        "        guard !AppEnvironment.isHeadless else {\n"
        "            return true  // MUTATION: report success without doing anything\n"
        "        }",
        "revert the honesty: a headless run says it put an icon on the user's screen",
    ),
    (
        "M36-the-drag-gate-never-closes",
        "DragState.swift",
        "    static func allowsDrag(sortKey: SortKey) -> Bool { sortKey == .manual }",
        "    static func allowsDrag(sortKey: SortKey) -> Bool { true }  // MUTATION",
        "revert the gate: a reorder drag is allowed under every sort again",
    ),
    (
        "M37-the-drag-gate-never-opens",
        "DragState.swift",
        "    static func allowsDrag(sortKey: SortKey) -> Bool { sortKey == .manual }",
        "    static func allowsDrag(sortKey: SortKey) -> Bool { false }  // MUTATION",
        "over-tighten the gate: no drag is allowed even under the custom sort",
    ),
    (
        "M38-the-edge-band-excludes-its-own-boundary",
        "DragState.swift",
        "        if x <= inset { return .leading }",
        "        if x < inset { return .leading }  // MUTATION",
        "shift the band: the point exactly on the boundary stops counting as an edge",
    ),
    (
        "M39-the-two-edge-zones-are-swapped",
        "DragState.swift",
        "        if x <= inset { return .leading }",
        "        if x <= inset { return .trailing }  // MUTATION",
        "swap the zones: the left edge asks for the next page, the right edge for the previous",
    ),
    (
        "M40-a-degenerate-deck-still-has-zones",
        "DragState.swift",
        "        guard width > 0, inset > 0 else { return nil }",
        "        guard width >= 0, inset >= 0 else { return nil }  // MUTATION",
        "drop the guard: a deck of no width, or a band of no width, reports an edge zone",
    ),
    (
        "M41-ungroup-keeps-the-old-placement",
        "DeckStore.swift",
        "        pages[origin.section].remove(at: origin.item)\n"
        "        for member in folder.appIDs {\n"
        "            pages[origin.section].append(.app(member))\n"
        "        }\n"
        "        enforceCapacity()",
        "        replaceInGrid(.folder(folderID),\n"
        "                      with: folder.appIDs.first.map { DeckSlot.app($0) } ?? .app(\"\"))\n"
        "        for extra in folder.appIDs.dropFirst() { appendToGrid(.app(extra)) }\n"
        "        pages = pages.map { $0.filter { $0 != .app(\"\") } }  // MUTATION",
        "revert the placement: one member takes the folder's cell and the rest go to the deck's end",
    ),
    (
        "M42-ungroup-never-spills",
        "DeckStore.swift",
        "        for member in folder.appIDs {\n"
        "            pages[origin.section].append(.app(member))\n"
        "        }\n"
        "        enforceCapacity()",
        "        for member in folder.appIDs {\n"
        "            pages[origin.section].append(.app(member))\n"
        "        }  // MUTATION: an over-full page is left for the next launch to split",
        "drop the spill: a page the members overflow keeps them all instead of continuing onto the next",
    ),
    (
        "M43-ungroup-appends-to-the-deck-end",
        "DeckStore.swift",
        "        pages[origin.section].remove(at: origin.item)\n"
        "        for member in folder.appIDs {\n"
        "            pages[origin.section].append(.app(member))\n"
        "        }",
        "        pages[origin.section].remove(at: origin.item)\n"
        "        for member in folder.appIDs {\n"
        "            appendToGrid(.app(member))  // MUTATION: the end of the deck, not the page\n"
        "        }",
        "send the members to the end of the whole deck instead of the end of the folder's page",
    ),
    (
        "M44-move-out-mutates-before-validating",
        "DeckStore.swift",
        "        guard locate(.folder(folderID)) != nil else { return false }\n"
        "\n"
        "        removeFromFolder(appID, folder: folderID)",
        "        removeFromFolder(appID, folder: folderID)  // MUTATION: mutate before validating",
        "revert the contract: a refused move has already changed and saved the layout",
    ),
    (
        "M45-a-refusal-says-nothing",
        "DragState.swift",
        "        blockedNotice = message\n",
        "        blockedNotice = nil  // MUTATION: refuse silently\n",
        "revert the feedback: a refused drag never explains itself on screen",
    ),
    (
        "M46-the-refusal-loses-its-reason",
        "DragState.swift",
        '        "Dragging to reorder is only available in Custom sort mode."',
        '        "Dragging to reorder is disabled."  // MUTATION: the reason is gone',
        "revert the wording: the refusal no longer says which mode would allow it",
    ),
    # The folder family must re-derive `customOrder`. `save()` writes it as its
    # own field, so skipping this leaves a file whose `pages` and `customOrder`
    # disagree — invisible until Custom mode's "Reset Order" reverts to the
    # arrangement from before the folder step.
    (
        "M47-ungroup-leaves-the-order-stale",
        "DeckStore.swift",
        "        enforceCapacity()\n"
        "        normalizePages()\n"
        "        syncCustomOrder()\n"
        "        save()",
        "        enforceCapacity()\n"
        "        normalizePages()\n"
        "        save()  // MUTATION: the pre-ungroup order is written back",
        "drop the resync in ungroup: customOrder keeps the members at the folder's slot",
    ),
    (
        "M48-make-folder-leaves-the-order-stale",
        "DeckStore.swift",
        "        replaceInGrid(.app(target), with: .folder(folder.id))\n"
        "        removeGridSlot(source)\n"
        "        syncCustomOrder()\n"
        "        save()",
        "        replaceInGrid(.app(target), with: .folder(folder.id))\n"
        "        removeGridSlot(source)\n"
        "        save()  // MUTATION: the pre-folder order is written back",
        "drop the resync in makeFolder: customOrder still lists the member at its old slot",
    ),
    (
        "M49-add-to-folder-leaves-the-order-stale",
        "DeckStore.swift",
        "        removeGridSlot(appID)\n"
        "        normalizePages()\n"
        "        syncCustomOrder()\n"
        "        save()\n"
        "        flashMerge(.absorbed, folder: folderID)\n"
        "        return true",
        "        removeGridSlot(appID)\n"
        "        normalizePages()\n"
        "        save()  // MUTATION: the pre-add order is written back\n"
        "        flashMerge(.absorbed, folder: folderID)\n"
        "        return true",
        "drop the resync in addToFolder: customOrder keeps the app on the grid",
    ),
    (
        "M50-remove-from-folder-leaves-the-order-stale",
        "DeckStore.swift",
        "            appendToGrid(.app(appID))\n"
        "        }\n"
        "        normalizePages()\n"
        "        syncCustomOrder()\n"
        "        save()\n"
        "    }",
        "            appendToGrid(.app(appID))\n"
        "        }\n"
        "        normalizePages()\n"
        "        save()  // MUTATION: the pre-removal order is written back\n"
        "    }",
        "drop the resync in removeFromFolder: customOrder keeps the app inside the folder",
    ),
    (
        "M51-the-60hz-end-of-the-ramp-is-flattened",
        "DragMotion.swift",
        "    static let alphaReferenceFrame: Double = 0.42",
        "    static let alphaReferenceFrame: Double = 0.21  // MUTATION: no ramp",
        "flatten the 60 Hz end of the ramp onto the 120 Hz end",
    ),
    (
        "M52-the-120hz-end-of-the-ramp-is-flattened",
        "DragMotion.swift",
        "    static let alphaFastestFrame: Double = 0.21",
        "    static let alphaFastestFrame: Double = 0.42  // MUTATION: no ramp",
        "flatten the 120 Hz end of the ramp onto the 60 Hz end",
    ),
    (
        "M53-the-ramp-is-removed",
        "DragMotion.swift",
        "        return min(alphaReferenceFrame * (frameDuration / referenceFrame), alphaCap)",
        "        return alphaReferenceFrame  // MUTATION: a fixed factor, the misreading report 32 made",
        "replace the linear ramp with a fixed factor",
    ),
    (
        "M54-the-slop-is-the-wider-swiftui-default",
        "DragMotion.swift",
        "    static let dragSlop: Double = 4",
        "    static let dragSlop: Double = 8  // MUTATION: back to SwiftUI's minimumDistance",
        "widen the drag slop to the 8 points the SwiftUI gesture used",
    ),
    (
        "M75-the-open-folder-panel-does-not-shadow-the-grid",
        "DeckDragHost.swift",
        "        if vm.openedFolder != nil { return folderTarget(at: point) }",
        "        // MUTATION: the panel no longer shadows the grid behind it",
        "let a press inside an open folder grab the tile underneath it",
    ),
    (
        "M76-an-empty-slot-is-a-grabbable-tile",
        "DeckDragHost.swift",
        "        guard let index = tester.index(at: local), index < items.count else { return nil }\n"
        "        return DragOrigin(item: items[index], index: index, source: .grid)",
        "        guard let index = tester.index(at: local), index < store.metrics.capacity else { return nil }\n"
        "        let occupant: DeckSlot = index < items.count ? items[index] : .app(\"\")  // MUTATION\n"
        "        return DragOrigin(item: occupant, index: index, source: .grid)",
        "let a press on an empty grid slot count as a grabbable tile",
    ),
    (
        "M77-the-deck-point-is-flipped-a-second-time",
        "DeckDragHost.swift",
        "        let local = view.convert(point, from: nil)\n"
        "        return CGPoint(x: local.x, y: local.y)",
        "        let local = view.convert(point, from: nil)\n"
        "        return CGPoint(x: local.x, y: view.bounds.height - local.y)  // MUTATION: flipped again",
        "mirror every press and every move about the middle of the deck — press the\n"
        "  top row, lift the bottom row's icon. This is the bug report 36 is about: the\n"
        "  hosting view is already flipped, so the second flip is the mirror.",
    ),
    (
        "M78-the-icon-is-not-centred-on-the-pointer",
        "DeckDragHost.swift",
        "        NSRect(x: pointerInView.x - size / 2, y: pointerInView.y - size / 2,",
        "        NSRect(x: pointerInView.x, y: pointerInView.y,  // MUTATION: corner on the pointer",
        "leave the icon a half-icon away from the pointer for the whole drag",
    ),
    (
        "M59-settling-snaps-down-instead-of-nearest",
        "DragMotion.swift",
        "        let raw = Int((-offset / pageWidth).rounded())",
        "        let raw = Int((-offset / pageWidth).rounded(.down))  // MUTATION",
        "snap a settled drag down instead of to the nearest page",
    ),
    (
        "M60-a-second-down-restarts-the-drag",
        "DragSession.swift",
        "        guard !isDragging else { return .consume }",
        "        // MUTATION: the guard is gone, so a second down strands the session",
        "let a second mouse-down restart the machine while a drag is open",
    ),
    (
        "M61-the-slop-is-skipped-entirely",
        "DragSession.swift",
        "            guard DragMotion.exceedsSlop(from: origin, to: point) else { return .normal }",
        "            // MUTATION: no slop, so a one-pixel nudge starts a drag",
        "drop the slop check, so every press that twitches becomes a drag",
    ),
    (
        "M62-a-click-becomes-a-commit",
        "DragSession.swift",
        "            phase = .idle\n"
        "            return .normal\n"
        "        case .dragging:\n"
        "            phase = .idle\n"
        "            return .commit",
        "            phase = .idle\n"
        "            return .commit  // MUTATION: a click is treated as a drag release\n"
        "        case .dragging:\n"
        "            phase = .idle\n"
        "            return .commit",
        "report a click (a press that never moved) as a drag commit",
    ),
    (
        "M63-every-route-consumes",
        "DragSession.swift",
        "        case .normal: return false\n"
        "        case .consume, .beginSession, .track, .commit, .refuse: return true",
        "        case .normal: return true  // MUTATION: clicks are swallowed too\n"
        "        case .consume, .beginSession, .track, .commit, .refuse: return true",
        "make the forwarding route consume, so clicks never reach SwiftUI",
    ),
    (
        "M64-a-locked-deck-starts-a-drag-anyway",
        "DragSession.swift",
        "            guard allowsDrag else {\n"
        "                phase = .idle\n"
        "                return .refuse\n"
        "            }",
        "            // MUTATION: the gate is gone, so a locked deck opens a session",
        "start a drag even when the deck refuses reordering",
    ),
    (
        "M65-the-strip-stops-cancelling-the-scroll-offset",
        "DragOffsetModel.swift",
        "        applied = presented + scrollOffset",
        "        applied = presented  // MUTATION: the scroll offset is not cancelled",
        "let the strip jump by wherever the scroll view happens to be",
    ),
    (
        "M66-the-strip-never-repaints",
        "DragOffsetModel.swift",
        "        presented = step.value\n        publish()",
        "        presented = step.value  // MUTATION: the strip never repaints",
        "move the motion but never tell SwiftUI about it",
    ),
    (
        "M67-the-landing-is-published-before-arriving",
        "DragOffsetModel.swift",
        "        if step.settled, let target = landingTarget {",
        "        if let target = landingTarget {  // MUTATION: lands before arriving",
        "hand the deck its page while the strip is still gliding",
    ),
    (
        "M68-the-hand-back-leaves-the-offset-behind",
        "DragOffsetModel.swift",
        "        landingSignal.page = nil\n        applied = 0",
        "        landingSignal.page = nil  // MUTATION: the offset is left on the strip",
        "hand the scroll view a position and keep the old offset too",
    ),
    (
        "M69-a-nudge-moves-the-anchor-but-not-the-strip",
        "DragOffsetModel.swift",
        "        goal = DragMotion.restingGoal(page: clamped, pageWidth: pageWidth)",
        "        // MUTATION: the anchor moves, the strip is never aimed at the new page",
        "re-anchor the deck without aiming the motion at the new page",
    ),
    (
        "M70-a-nudge-is-not-clamped",
        "DragOffsetModel.swift",
        "        let clamped = min(max(page, 0), pageCount - 1)",
        "        let clamped = page  // MUTATION: no clamp",
        "let an edge dwell aim the deck past its last page",
    ),
    (
        "M71-the-anchor-ignores-where-the-deck-is",
        "DragOffsetModel.swift",
        "        self.anchorPage = DragMotion.settledPage(offset: presented,\n"
        "                                                 pageWidth: self.pageWidth,\n"
        "                                                 pageCount: self.pageCount)",
        "        self.anchorPage = 0  // MUTATION: the anchor ignores the deck",
        "anchor every drag to page zero regardless of where it was grabbed",
    ),
    (
        "M79-the-drop-ignores-the-page-the-user-is-looking-at",
        "DeckDragHost.swift",
        "    var dragPage: Int { offset.isActive ? offset.anchorPage : resolvedPage() }",
        "    var dragPage: Int { resolvedPage() }  // MUTATION: the strip is ignored",
        "land an item on the page the scroll view is still on — a page behind the one\n"
        "  the user was shown after an edge dwell",
    ),
    (
        "M80-the-reflow-forgets-the-grids-origin",
        "DragState.swift",
        "            x: location.x - gridFrame.minX,",
        "            x: location.x,  // MUTATION: measured from the window, not the grid",
        "report the slot under the pointer as though the grid began at the window's edge",
    ),
    (
        "M81-the-strip-creeps-without-a-page-change",
        "DragOffsetModel.swift",
        "        self.goal = -scrollOffset\n",
        "        self.goal = -scrollOffset + 1  // MUTATION: the strip drifts on its own\n",
        "let the strip drift although no page change was ever asked for — the shape of\n"
        "  the bug where the pointer's travel leaked back into the strip",
    ),
    (
        "M82-the-landing-reads-the-live-offset-not-the-anchor",
        "DragOffsetModel.swift",
        "        goal = DragMotion.restingGoal(page: anchorPage, pageWidth: pageWidth)\n"
        "        landingTarget = anchorPage\n"
        "        return anchorPage",
        "        // MUTATION: the landing page comes from wherever the strip is mid-glide\n"
        "        let target = DragMotion.settledPage(offset: presented, pageWidth: pageWidth,\n"
        "                                            pageCount: pageCount)\n"
        "        goal = DragMotion.restingGoal(page: target, pageWidth: pageWidth)\n"
        "        landingTarget = target\n"
        "        return target",
        "let the hand-back name a page the drop was not placed on, whenever the button\n"
        "  comes up while an edge-dwell page turn is still sliding",
    ),
    (
        "M83-the-deck-turns-the-page-before-the-scroll-view-does",
        "DeckDragHost.swift",
        "        drag.onRequestPage = { [weak self] page in\n"
        "            guard let self else { return }\n"
        "            self.offset.nudge(to: page)\n"
        "        }",
        "        drag.onRequestPage = { [weak self] page in\n"
        "            guard let self else { return }\n"
        "            self.offset.nudge(to: page)\n"
        "            // MUTATION: the deck's own page moves while the scroll view has not\n"
        "            _ = self.vm.paging.set(self.offset.anchorPage, count: self.store.pages.count)\n"
        "        }",
        "move the deck's own page as soon as the dwell matures, so the indicator leads\n"
        "  the grid — and stays ahead of it for good if the drag is cancelled",
    ),
    (
        "M84-the-drag-icon-is-handed-over-at-its-own-size",
        "DeckDragHost.swift",
        "        case .app(let id):\n"
        "            guard let icon = store.app(id: id)?.icon else { return blank(size: size) }\n"
        "            return plate(size: size) { icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size)) }",
        "        case .app(let id):\n"
        "            // MUTATION: AppKit then derives a 32 pt component for a 64 pt frame\n"
        "            return store.app(id: id)?.icon ?? blank(size: size)",
        "hand the session the icon at its own 1024 points, so AppKit builds the\n"
        "  dragging component at a size the frame then stretches — the soft icon",
    ),
    (
        "M85-the-reflow-forgets-what-the-pointer-is-over",
        "DragState.swift",
        "        case .keep:\n"
        "            // The live reflow already put the dragged item here, so this is the\n"
        "            // app it displaced. Keep the candidate that named it.\n"
        "            break",
        "        case .keep:\n"
        "            // MUTATION: the target is dropped as soon as the reflow fills the slot\n"
        "            combineCandidate = nil",
        "forget the combine target the moment the reflow moves the dragged app into\n"
        "  the hovered slot, so a drop on it merges with nothing",
    ),
    (
        "M86-the-drop-reads-the-reflowed-slot",
        "DragState.swift",
        "        if source == .grid, let target = combineCandidate, case .app = item {\n"
        "            return .combine(target)\n"
        "        }",
        "        // MUTATION: the target is read from the slot the reflow already filled\n"
        "        if source == .grid, case .app = item, let index = hoverIndex,\n"
        "           let target = DragState.combineTarget(item: item, pageItems: pageItems, index: index) {\n"
        "            return .combine(target)\n"
        "        }",
        "ask the reflowed grid what is under the pointer — which answers \"the app you\n"
        "  are dragging\", so no drop ever merges",
    ),
    (
        "M87-the-release-never-folds",
        "DeckDragHost.swift",
        "            guard case .app(let appID) = slot else { break }\n"
        "            switch target {\n"
        "            case .app(let targetID):\n"
        "                // The report-45 rule: releasing on an app tile folds the two\n"
        "                // into a new folder.\n"
        "                store.makeFolder(dropping: appID, onto: targetID)\n"
        "            case .folder(let folderID):\n"
        "                store.addToFolder(appID, folder: folderID)\n"
        "            }",
        "            // MUTATION: the release folds nothing\n"
        "            _ = target",
        "decide that the release should fold and then not do it, so the app dropped\n"
        "  on a folder never becomes a member of it",
    ),
    (
        "M88-any-source-may-merge",
        "DragState.swift",
        "        if source == .grid, let target = combineCandidate, case .app = item {\n"
        "            return .combine(target)\n"
        "        }",
        "        if let target = combineCandidate, case .app = item {  // MUTATION: any source\n"
        "            return .combine(target)\n"
        "        }",
        "let a member dragged around inside an open folder panel merge with whatever\n"
        "  grid tile happens to be behind the panel",
    ),
    (
        "M89-the-deck-is-above-the-icon-being-dragged",
        "LaunchpadWindowController.swift",
        "        window.level = style.usesDeckLevel ? deckWindowLevel : .normal",
        "        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))"
        "  // MUTATION: back on top of the drag window",
        "put the deck back at the shielding level, above the window AppKit drags the\n"
        "  icon in, so the frosted backdrop is composited over the icon — the icon\n"
        "  reads as having fallen into the blur",
    ),
    (
        "M90-the-deck-is-a-hair-above-the-drag-window",
        "LaunchpadWindowController.swift",
        "NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)) - 1)",
        "NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)) + 1)"
        "  // MUTATION: one above the drag window",
        "put the deck one level *above* the dragging window — the same defect as M89,\n"
        "  by the thinnest possible margin, which is what a sign slip looks like",
    ),
    (
        "M91-an-app-stops-being-a-fold-target",
        "DragState.swift",
        "        case .app(let appID): return .app(appID)\n"
        "        case .folder(let folderID): return .folder(folderID)",
        "        case .app: return nil\n"
        "        case .folder(let folderID): return .folder(folderID)",
        "take the app back off the fold targets — the report-40 rule that made a\n"
        "  release over an app a plain move (reversed in report 45)",
    ),
    (
        "M92-the-users-folder-loses-its-exemption",
        "AppInfo.swift",
        "        return memberCount < 2 && !isExplicit",
        "        return memberCount < 2  // MUTATION: nobody is exempt",
        "ignore `isExplicit` in the dissolve rule — the one-member folder the user just\n"
        "  asked for is then dissolved by the next mutation, or by `reconcile` (report 41)",
    ),
    (
        "M93-one-member-is-always-a-folder",
        "AppInfo.swift",
        "        return memberCount < 2 && !isExplicit",
        "        return false  // MUTATION: one member is always a folder",
        "make one member a folder for everyone — the old rule stops being enforced at\n"
        "  all, which is the failure the exemption was added narrowly *inside*",
    ),
    (
        "M94-the-new-folder-is-nobodys",
        "DeckStore.swift",
        '        let folder = AppFolder(name: "Folder", appIDs: [appID], isUserCreated: true)',
        '        let folder = AppFolder(name: "Folder", appIDs: [appID], isUserCreated: false)'
        "  // MUTATION: not the user's",
        "create the folder without the mark — the API's *effect* stops matching the\n"
        "  rule, so the folder is dissolved on the next reconcile or scan",
    ),
    (
        "M95-the-new-folder-leaves-a-second-icon",
        "DeckStore.swift",
        "        replaceInGrid(.app(appID), with: .folder(folder.id))",
        "        // MUTATION: leave the app in the grid as well (I2 breach)",
        "create the folder but leave the app where it was — the app is a grid slot and\n"
        "  a folder member at once, which is the duplicate-icon defect (I2)",
    ),
    (
        "M96-the-new-folder-skips-its-precondition",
        "DeckStore.swift",
        "        guard apps.contains(where: { $0.id == appID }), isGridSlot(appID) else { return nil }",
        "        guard apps.contains(where: { $0.id == appID }) else { return nil }"
        "  // MUTATION: no slot check",
        "drop the grid-slot precondition — 'New Folder' would also accept an app that is\n"
        "  already inside a folder, which has no slot to become one",
    ),
    (
        "M97-the-decoder-demands-the-new-key",
        "AppInfo.swift",
        "        isUserCreated = try c.decodeIfPresent(Bool.self, forKey: .isUserCreated) ?? false",
        "        isUserCreated = try c.decode(Bool.self, forKey: .isUserCreated)"
        "  // MUTATION: demand the key",
        "demand the new key when decoding — every layout file written before the flag\n"
        "  existed reads as corrupt and is sent down the recovery path (A1)",
    ),
    (
        "M98-reconcile-counts-members-again",
        "DeckStore.swift",
        "            updated.appIDs = kept\n"
        "            if AppFolder.dissolves(memberCount: updated.appIDs.count,\n"
        "                                   isExplicit: updated.isUserCreated) {",
        "            updated.appIDs = kept\n"
        "            if updated.appIDs.count <= 1 {  // MUTATION: count members",
        "revert only the `reconcile` site to counting members — a scan dissolves the\n"
        "  folder the user created by hand",
    ),
    (
        "M99-removing-a-member-counts-again",
        "DeckStore.swift",
        "        removeGridSlot(appID)\n"
        "        if AppFolder.dissolves(memberCount: folder.appIDs.count, isExplicit: folder.isUserCreated) {",
        "        removeGridSlot(appID)\n"
        "        if folder.appIDs.count <= 1 {  // MUTATION: count members",
        "revert only `removeFromFolder` to counting members — a user folder that has\n"
        "  grown to two and loses one is dissolved",
    ),
    (
        "M100-detaching-a-member-counts-again",
        "DeckStore.swift",
        "            folder.appIDs.removeAll { $0 == appID }\n"
        "            if AppFolder.dissolves(memberCount: folder.appIDs.count,\n"
        "                                   isExplicit: folder.isUserCreated) {",
        "            folder.appIDs.removeAll { $0 == appID }\n"
        "            if folder.appIDs.count <= 1 {  // MUTATION: count members",
        "revert only `detachFromAnyFolder` to counting members — a user folder that\n"
        "  loses a member to another folder is dissolved",
    ),
    (
        "M101-the-exclusivity-pass-counts-again",
        "DeckStore.swift",
        "            if AppFolder.dissolves(memberCount: folder.appIDs.count,\n"
        "                                   isExplicit: folder.isUserCreated) {\n"
        "                // No longer a folder — see `AppFolder.dissolves`. A folder the\n"
        "                // user created by hand survives at one member.",
        "            if folder.appIDs.count <= 1 {  // MUTATION: count members\n"
        "                // No longer a folder — see `AppFolder.dissolves`. A folder the\n"
        "                // user created by hand survives at one member.",
        "revert only the I1 exclusivity pass to counting members — a user folder\n"
        "  stripped of a member by the repair is dissolved",
    ),
    (
        "M102-the-icon-scale-quietly-grows",
        "GridMetrics.swift",
        "    static let `default`: CGFloat = 1.0",
        "    static let `default`: CGFloat = 1.1",
        "make the default icon scale 1.1 — every existing install grows its icons\n"
        "  without asking, and the pre-42 regression check catches it",
    ),
    (
        "M103-the-icon-scale-is-not-clamped",
        "GridMetrics.swift",
        "        let scaled = (baseIcon * scale).rounded()",
        "        let scaled = (baseIcon * iconScale).rounded()",
        "stop clamping the scale — an extreme slider position reaches the geometry\n"
        "  instead of stopping at the declared range",
    ),
    (
        "M104-a-scaled-icon-may-leave-its-cell",
        "GridMetrics.swift",
        "        let iconSize = min(max(scaled, 40), ceiling)",
        "        let iconSize = max(scaled, 40)",
        "drop the cell-edge clamp — a scaled-up icon overlaps its neighbours",
    ),
    (
        "M105-latin-loses-its-exact-match",
        "LaunchpadViewModel.swift",
        "        if name == raw || latin == needle { return 0 }",
        "        if name == raw { return 0 }",
        "drop the exact latin match — typing the full pinyin ranks 微信 below\n"
        "  something else instead of first",
    ),
    (
        "M106-latin-loses-its-subsequence-match",
        "LaunchpadViewModel.swift",
        "        if let latin, isSubsequence(needle, of: latin) { return 4 }\n",
        "        // MUTATION: the latin subsequence branch is gone\n",
        "drop the latin subsequence branch — the initials \"wx\" no longer find 微信",
    ),
    (
        "M107-the-latin-key-keeps-its-spaces",
        "LaunchpadViewModel.swift",
        '        let value = latinized(name)?.replacingOccurrences(of: " ", with: "") ?? ""',
        '        let value = latinized(name) ?? ""',
        "stop stripping the spaces the transliteration inserts — the latin key is no\n"
        "  longer the no-space form the search compares against",
    ),
    (
        "M108-transliteration-keeps-its-tone-marks",
        "LaunchpadViewModel.swift",
        "kCFStringTransformStripDiacritics",
        "kCFStringTransformToLatin",
        "skip the diacritic strip — the latin key keeps tone marks, so plain ASCII\n"
        "  pinyin no longer matches",
    ),
    (
        "M109-the-dock-policy-is-inverted",
        "DeckSettings.swift",
        "        showDockIcon ? .regular : .accessory",
        "        showDockIcon ? .accessory : .regular",
        "invert the Dock-icon policy — turning the icon *on* removes it",
    ),
    (
        "M110-the-dock-guard-lies",
        "DeckSettings.swift",
        "        guard mayPersist else { return false }\n"
        "        NSApp.setActivationPolicy(DockIconPolicy.policy(showDockIcon: showDockIcon))\n"
        "        return true",
        "        guard mayPersist else { return true }\n"
        "        NSApp.setActivationPolicy(DockIconPolicy.policy(showDockIcon: showDockIcon))\n"
        "        return true",
        "make the headless guard claim it changed the Dock icon when it did not —\n"
        "  the same lie M35 pinned for the menu bar",
    ),

    # ---- Batch 2a: screen policy, self-exclusion, Dock-icon trap ----
    (
        "M111-the-pointer-policy-blindly-takes-the-first-screen",
        "ScreenTarget.swift",
        "            return screens.firstIndex { $0.frame.contains(pointer) } ?? fallback",
        "            return fallback",
        "the pointer policy stops following the pointer and always answers the\n"
        "  menu-bar screen — indistinguishable from .main",
    ),
    (
        "M112-the-menu-bar-screen-is-never-recognized",
        "ScreenTarget.swift",
        "        screens.firstIndex { $0.carriesMenuBar } ?? 0",
        "        0",
        "every fallback lands on screen 0 regardless of where the menu bar is,\n"
        "  so a Mac whose primary display is not screens[0] gets the wrong screen",
    ),
    (
        "M113-the-dock-reserve-is-never-seen",
        "ScreenTarget.swift",
        "        return screens.firstIndex { s in\n"
        "            reserved(s.visibleFrame.minX, s.frame.minX)        // Dock on the left\n"
        "                || reserved(s.frame.maxX, s.visibleFrame.maxX) // Dock on the right\n"
        "                || reserved(s.visibleFrame.minY, s.frame.minY) // Dock at the bottom\n"
        "        }",
        "        return nil",
        "the dock policy can never find a Dock and silently degrades to .main\n"
        "  for every user who parked the Dock on a secondary display",
    ),
    (
        "M114-the-active-policy-ignores-the-frontmost-app",
        "ScreenTarget.swift",
        "            if let activeScreenID,\n"
        "               let hit = screens.firstIndex(where: { $0.id == activeScreenID }) {\n"
        "                return hit\n"
        "            }",
        "            if false, let hit = screens.firstIndex(where: { $0.id == activeScreenID }) {\n"
        "                return hit\n"
        "            }",
        "the active policy stops consulting the frontmost app and collapses into\n"
        "  .main",
    ),
    (
        "M115-the-deck-lists-itself",
        "AppScanner.swift",
        "        guard let bundleID, let ownBundleID else { return true }\n"
        "        return bundleID != ownBundleID",
        "        guard let bundleID, let ownBundleID else { return true }\n"
        "        return bundleID == ownBundleID",
        "the gate flips: OpenDeck is the one app the deck refuses to show and\n"
        "  everything else is dropped",
    ),
    (
        "M116-the-dock-icon-trap-is-left-unrepaired",
        "DeckSettings.swift",
        "        if showDockIcon || showMenuBarIcon { return (showDockIcon, showMenuBarIcon) }\n"
        "        return (showDockIcon, true)",
        "        return (showDockIcon, showMenuBarIcon)",
        "the impossible pair passes through untouched and the app can be two\n"
        "  clicks away from being unquittable from the UI",
    ),
    (
        "M117-the-repair-reaches-for-the-wrong-icon",
        "DeckSettings.swift",
        "        return (showDockIcon, true)",
        "        return (true, showMenuBarIcon)",
        "the repair forces the Dock icon back on instead of the menu bar icon,\n"
        "  overriding the user's explicit Dock-icon choice",
    ),

    # ---- Report 44: merge motion (decoded from LaunchOS) ----

    (
        "M118-the-merge-scale-drifts",
        "Models/MergeMotion.swift",
        "static let scale: CGFloat = 0.8090169943749475",
        "static let scale: CGFloat = 0.9",
        "the decoded constant is not the decoded constant — the suite must pin\n"
        "  0x3FE9EB851EB851EC exactly, not \"about 0.8\"",
    ),
    (
        "M119-the-merge-duration-drifts",
        "Models/MergeMotion.swift",
        "static let duration: Double = 0.18",
        "static let duration: Double = 0.3",
        "same for 0x3FC70A3D70A3D70A — a \"nicer\" number is a different motion",
    ),
    (
        "M120-folding-into-an-existing-folder-stays-silent",
        "Services/DeckStore.swift",
        "            flashMerge(.absorbed, folder: fid)\n",
        "",
        "the merge-into-existing branch publishes no flash and the tile never\n"
        "  plays the absorb motion",
    ),
    (
        "M121-the-birth-of-a-folder-stays-silent",
        "Services/DeckStore.swift",
        "        flashMerge(.absorbed, folder: folder.id)\n",
        "",
        "the two-loose-apps birth path publishes no flash",
    ),
    (
        "M122-adding-to-a-folder-stays-silent",
        "Services/DeckStore.swift",
        "        flashMerge(.absorbed, folder: folderID)\n"
        "        return true",
        "        return true",
        "addToFolder publishes no flash on success",
    ),
    (
        "M123-ungrouping-stays-silent",
        "Services/DeckStore.swift",
        "        flashMerge(.released, folder: folderID)\n"
        "        folders.removeValue(forKey: folderID)",
        "        folders.removeValue(forKey: folderID)",
        "ungroup publishes no flash and the release motion never plays",
    ),
    (
        "M124-a-dissolving-removal-stays-silent",
        "Services/DeckStore.swift",
        "            flashMerge(.released, folder: folderID)\n"
        "            let leftovers",
        "            let leftovers",
        "the dissolving branch of removeFromFolder publishes no flash",
    ),
    (
        "M125-the-flash-token-never-moves",
        "Services/DeckStore.swift",
        "        mergeFlashToken += 1\n",
        "",
        "the token stalls and a second flash on the same folder never\n"
        "  re-triggers the animation",
    ),
    (
        "M126-ungroup-flashes-the-wrong-direction",
        "Services/DeckStore.swift",
        "        flashMerge(.released, folder: folderID)\n"
        "        folders.removeValue(forKey: folderID)",
        "        flashMerge(.absorbed, folder: folderID)\n"
        "        folders.removeValue(forKey: folderID)",
        "ungroup reports absorbed — the tile would pulse inward while its\n"
        "  members scatter",
    ),
    (
        "M127-the-drop-hover-zoom-drifts",
        "Models/MergeMotion.swift",
        "static let hoverZoom: CGFloat = 1.05",
        "static let hoverZoom: CGFloat = 1.0",
        "the drop-hover zoom is not the decoded constant — the suite must pin\n"
        "  0x3FF0CCCCCCCCCCCD (1.05) exactly, not \"roughly bigger\"",
    ),
    (
        "M128-hovering-a-folder-publishes-nothing",
        "UI/DragState.swift",
        "            combineCandidate = target\n"
        "            if case .folder(let id) = target { combineFolderID = id } else { combineFolderID = nil }",
        "            combineCandidate = target\n"
        "            combineFolderID = nil",
        "the tile can never zoom — the drop-hover signal never names a folder",
    ),
    (
        "M129-leaving-the-folder-keeps-it-hovered",
        "UI/DragState.swift",
        "        case .cancel:\n"
        "            combineCandidate = nil\n"
        "            combineFolderID = nil\n"
        "            combineAppID = nil\n"
        "        }",
        "        case .cancel:\n"
        "            combineCandidate = nil\n"
        "        }",
        "the last folder stays zoomed after the pointer moves away",
    ),
    (
        "M130-a-release-keeps-the-drop-hover",
        "UI/DeckDragHost.swift",
        "        store.setDropHoverFolder(nil)\n"
        "        // Read the page through the single derived point",
        "        // Read the page through the single derived point",
        "the tile stays zoomed after the button comes up",
    ),
    (
        "M131-the-margin-arms-a-fold",
        "UI/DragState.swift",
        "        if decision != .keep, !tester.overTile(at: local, index: index) {\n"
        "            decision = .cancel\n"
        "        }",
        "        if false {\n"
        "            decision = .cancel\n"
        "        }",
        "the whole cell arms the merge again — a pointer in the margin folds instead\n"
        "  of inserting, and repositioning near tiles becomes impossible",
    ),
    (
        "M132-a-merge-hover-reflows",
        "UI/DragState.swift",
        "        if case .start = decision { return }",
        "        // MUTATION: the merge hover reflows like any other move",
        "the hovered tile gets slid aside while the merge is armed — the target runs\n"
        "  from the pointer (the defect the user reported)",
    ),
    (
        "M133-the-app-merge-signal-is-never-published",
        "UI/DragState.swift",
        "            if case .app(let id) = target { combineAppID = id } else { combineAppID = nil }",
        "            combineAppID = nil",
        "the target app never learns it is the merge candidate — no ring, no zoom,\n"
        "  while DragState still folds on the release",
    ),
    (
        "M134-crossing-is-never-recorded",
        "UI/DragState.swift",
        "            // The touch marks the tile crossed: the gap may only open past it.\n"
        "            crossedTileIDs.insert(pageItems[index].id)",
        "            // MUTATION: crossing is never recorded",
        "the tile touch no longer marks the cell crossed — the gap never opens past\n"
        "  an icon, so reordering by sweeping across a row stops working entirely",
    ),
    (
        "M135-the-approach-gate-is-wired-open",
        "UI/DragState.swift",
        "        if let occupant, occupant != item, !crossedTileIDs.contains(occupant.id) {\n"
        "            return\n"
        "        }",
        "        if let occupant, occupant != item, false {\n"
        "            return\n"
        "        }",
        "the approach side of a tile moves the icons again — the defect the user\n"
        "  reported: positions shift while merely approaching the target",
    ),
    (
        "M136-a-release-past-the-gate-still-repositions",
        "UI/DragState.swift",
        "        if index < pageItems.count, pageItems[index] != item,\n"
        "           !crossedTileIDs.contains(pageItems[index].id) {\n"
        "            return .none\n"
        "        }",
        "        if index < pageItems.count, pageItems[index] != item,\n"
        "           false {\n"
        "            return .none\n"
        "        }",
        "releasing on the approach side inserts the icon there anyway — a reposition\n"
        "  the pointer never earned by crossing the tile",
    ),
    (
        "M137-the-promotion-never-happens",
        "UI/DragState.swift",
        "        guard source != .grid else { return }\n"
        "        source = .grid",
        "        guard source != .grid else { return }",
        "the pull-out drag keeps its member contract — the release after leaving the\n"
        "  panel places instead of folding, and the reflow never becomes a grid drag",
    ),
    (
        "M138-the-exit-test-loses-the-plate",
        "UI/DragState.swift",
        "        !panelFrame.insetBy(dx: -padding, dy: -padding).contains(pointer)",
        "        !panelFrame.contains(pointer)",
        "the exit boundary shrinks to the grid box — pulling into the plate's padding\n"
        "  band (visibly still over the folder) would collapse the folder early",
    ),
    (
        "M139-the-exit-gate-is-always-open",
        "UI/DeckDragHost.swift",
        "        guard DragState.exitedPanel(pointer: point, panelFrame: panel.frame,\n"
        "                                    padding: FolderOverlayView.panelPadding) else { return }",
        "        _ = DragState.exitedPanel(pointer: point, panelFrame: panel.frame,\n"
        "                                  padding: FolderOverlayView.panelPadding)",
        "the pull-out fires while the pointer is still inside the panel — the folder\n"
        "  would collapse and the member would join the grid without ever leaving",
    ),
    (
        "M140-the-panel-never-asks-to-collapse",
        "UI/DeckDragHost.swift",
        "                vm.folderMinimizing = true\n",
        "",
        "the folder stays open after the member leaves it — the collapse half of the\n"
        "  pull-out is missing and the panel lingers over a drag it no longer owns",
    ),
    (
        "M141-the-drag-keeps-its-member-source",
        "UI/DeckDragHost.swift",
        "                drag.promoteToGrid()\n",
        "",
        "the placed member never becomes a grid drag — the release stays on the\n"
        "  member contract and can never fold into another tile",
    ),
    (
        "M142-an-off-grid-exit-lands-at-the-head",
        "UI/DeckDragHost.swift",
        "        let index = drag.hoverIndex.map { min(max($0, 0), count) } ?? count",
        "        let index = drag.hoverIndex.map { min(max($0, 0), count) } ?? 0",
        "leaving the panel off the grid drops the member at the page head instead of\n"
        "  the tail",
    ),
    (
        "M143-a-hidden-deck-still-forces-a-raised-panel",
        "UI/AuxiliaryWindows.swift",
        "        guard deckVisible else { return nil }",
        "        guard true else { return nil }",
        "raise the settings panel even with no deck on screen — an ordinary window\n"
        "  floated over the Dock and the menu bar",
    ),
    (
        "M144-the-panel-is-put-below-the-deck",
        "UI/AuxiliaryWindows.swift",
        "        return NSWindow.Level(rawValue: deckLevel.rawValue + 1)",
        "        return NSWindow.Level(rawValue: deckLevel.rawValue - 1)",
        "put the settings window *below* the deck instead of above it — behind a\n"
        "  full-screen deck it is simply invisible, which is the state report 47 was\n"
        "  written to fix",
    ),
    (
        "M145-the-panel-rises-past-the-drag-image",
        "UI/AuxiliaryWindows.swift",
        "        return NSWindow.Level(rawValue: deckLevel.rawValue + 1)",
        "        return NSWindow.Level(rawValue: deckLevel.rawValue + 500)",
        "raise the panel past the level AppKit composites the dragged icon at — an\n"
        "  icon in the air would fall behind our own window",
    ),
    (
        "M146-the-caption-shrinks-below-legibility",
        "Models/GridMetrics.swift",
        "        return min(max(scaled, minimumPointSize), maximumPointSize)",
        "        return min(max(scaled, 0), maximumPointSize)",
        "drop the caption's readability floor — a 20 pt icon gets a 2 pt name",
    ),
    (
        "M147-the-caption-ignores-the-icon",
        "Models/GridMetrics.swift",
        "        let scaled = (referencePointSize * scale).rounded()",
        "        let scaled = referencePointSize",
        "pin the caption back to one size — the bug report 49 exists to fix, with\n"
        "  the icon scaling underneath an unmoving name",
    ),
    (
        "M148-the-press-target-stops-covering-the-caption",
        "Models/GridMetrics.swift",
        "        (48 * pointSize(scale: scale) / referencePointSize).rounded()",
        "        48",
        "keep the caption block at 48 pt whatever the caption's size — the press\n"
        "  target stops covering the text it is drawn around",
    ),
    (
        "M149-the-caption-keeps-its-bundle-extension",
        "Services/AppNaming.swift",
        "        guard trimmed.hasSuffix(\".app\") else { return trimmed }",
        "        guard false else { return trimmed }",
        "let the display name keep its .app tail — on a machine with \"show all\n"
        "  filename extensions\" every caption in the deck ends in .app",
    ),
    (
        "M150-the-plist-wins-over-the-file-manager",
        "Services/AppNaming.swift",
        "            withoutBundleExtension(finderDisplayName),",
        "            nil,",
        "fall back to the plist for the caption — VoiceMemos instead of Voice Memos,\n"
        "  which is the difference report 50 exists to remove",
    ),
    (
        "M151-the-uninstall-panel-drops-behind-the-deck",
        "UI/AuxiliaryWindows.swift",
        "    static let panel: NSWindow.Level = .screenSaver + 1",
        "    static let panel: NSWindow.Level = .floating",
        "put the confirmation panel back at `.floating` — under the full-screen deck\n"
        "  it was opened from, which is the bug report 51 exists to fix",
    ),
    (
        "M152-ungroup-all-dissolves-in-reverse-order",
        "Services/DeckStore.swift",
        "        for id in all { ungroup(id) }",
        "        for id in all.reversed() { ungroup(id) }",
        "dissolve the folders back-to-front — the deterministic grid-order cascade\n"
        "  report 52 pins collapses into a different final layout",
    ),
    (
        "M153-ungroup-all-leaves-off-grid-folders",
        "Services/DeckStore.swift",
        "        let all = onGrid + offGrid",
        "        let all = onGrid",
        "skip folders that are not on the grid — they survive 'ungroup all',\n"
        "  invisible to the user but still holding their members",
    ),
    (
        "M154-reorganize-ignores-sort-direction",
        "Models/LayoutOrganizer.swift",
        "            return asc ? r == .orderedAscending : r == .orderedDescending",
        "            return r == .orderedAscending",
        "always sort names ascending — 'Descending' silently stops working in\n"
        "  the Reorganize sheet",
    ),
    (
        "M155-reorganize-swaps-apple-placement",
        "Models/LayoutOrganizer.swift",
        "            orderedApps = others + apples",
        "            orderedApps = apples + others",
        "put Apple's apps first whatever the placement says — the default\n"
        "  'After Other Apps' inverts",
    ),
    (
        "M156-reorganize-swaps-folder-placement",
        "Models/LayoutOrganizer.swift",
        "                ordered = sortedFolders.map(\\.slot) + ordered",
        "                ordered += sortedFolders.map(\\.slot)",
        "append the folders instead of prepending them — 'Before Apps'\n"
        "  becomes 'After Apps'",
    ),
    (
        "M157-reorganize-ignores-page-scope",
        "Models/LayoutOrganizer.swift",
        "            return selectedPages.filter { $0 >= 0 && $0 < pageCount }.sorted()",
        "            return Array(0 ..< max(pageCount, 0))",
        "treat 'Selected Pages' as 'All Pages' — reorganizing rewrites the\n"
        "  pages the user deliberately left out",
    ),
    (
        "M158-reorganize-skips-ungroup-all",
        "Models/LayoutOrganizer.swift",
        "        if options.ungroupAllFolders {",
        "        if false {",
        "ignore 'Ungroup All Folders' — the folders survive a reorganize that\n"
        "  promised to dissolve them",
    ),
    (
        "M159-reorganize-ignores-across-pages",
        "Models/LayoutOrganizer.swift",
        "        if options.acrossPages {",
        "        if false {",
        "always reorganize page by page — items stop moving between pages,\n"
        "  which is the whole point of 'Reorganize Across Pages'",
    ),
    (
        "M160-reorganize-rules-accepts-empty-selection",
        "UI/ReorganizeView.swift",
        "        if options.pageScope == .selectedPages, options.scope(pageCount: pageCount).isEmpty {\n            return false\n        }",
        "        if false {\n            return false\n        }",
        "let 'Reorganize' run with Selected Pages and nothing selected — the\n"
        "  sheet's own 'Select at least one page' rule stops applying",
    ),
    (
        "M161-reorganize-scope-keeps-out-of-range-pages",
        "Models/LayoutOrganizer.swift",
        "            return selectedPages.filter { $0 >= 0 && $0 < pageCount }.sorted()",
        "            return selectedPages.sorted()",
        "keep page indices the layout no longer has — a stale selection\n"
        "  reorganizes pages that are not there",
    ),
    (
        "M162-open-motion-drifts-from-the-decoded-0-28",
        "Models/MergeMotion.swift",
        "    static let duration: Double = 0.28",
        "    static let duration: Double = 0.34",
        "drift the folder-open duration back to the spring stand-in's 0.34 —\n"
        "  the original runs 0.28 s ease-in-out, measured at 0x10010df6c",
    ),
    (
        "M163-hidden-badge-symbol-drifts-from-0-64",
        "UI/AppCell.swift",
        "    static let symbolFraction: CGFloat = 0.64",
        "    static let symbolFraction: CGFloat = 0.5",
        "shrink the hidden badge's symbol inside its white circle — the\n"
        "  original sizes it at 0.64 x min(bounds), measured at 0x1000e5b9c",
    ),
    (
        "M164-caption-shadow-drifts-from-the-decoded-0-26",
        "UI/AppCell.swift",
        "    static let alpha: Double = 0.26",
        "    static let alpha: Double = 0.85",
        "put the caption shadow back at 0.85 — that was the *text* colour's\n"
        "  alpha from the label builder's other branch; the shadow is 0.26",
    ),
    (
        "M165-caption-shadow-drifts-from-the-decoded-offset",
        "UI/AppCell.swift",
        "    static let offsetY: CGFloat = -1",
        "    static let offsetY: CGFloat = 1",
        "flip the caption shadow downward — the original offsets it (0, -1),\n"
        "  measured at 0x100003f34",
    ),
    (
        "M166-caption-ignores-the-localized-name",
        "Services/AppNaming.swift",
        "            cleaned(localizedDisplayName),",
        "            nil,",
        "drop the localised plist name from the chain — every localised app\n"
        "  (腾讯会议, 微信) falls back to its English base-plist name, the bug\n"
        "  report 55 exists to fix",
    ),
    (
        "M167-uninstall-needles-drop-the-bundle-spelling",
        "Services/AppUninstaller.swift",
        "        add(folderName)",
        "        add(nil as String?)",
        "match leftovers on the localised caption alone — a vendor folder\n"
        "  named after the bundle (TencentMeeting) stops being found the day\n"
        "  the caption becomes 腾讯会议",
    ),
    (
        "M168-dock-tile-loses-its-file-data",
        "Services/DockSync.swift",
        "                \"file-data\": [\n                    \"_CFURLString\": urlString,\n                    \"_CFURLStringType\": 15,\n                ] as [String: Any],",
        "                \"file-data\": [:] as [String: Any],",
        "write a Dock tile with no URL — the Dock ignores it and the app the\n"
        "  user asked for never appears",
    ),
    (
        "M169-dock-dedup-forgets-the-trailing-slash",
        "Services/DockSync.swift",
        "        a == b || a.hasSuffix(\"/\") && String(a.dropLast()) == b\n            || b.hasSuffix(\"/\") && String(b.dropLast()) == a",
        "        a == b",
        "compare the Dock's slash-terminated URL with the bare one — the\n"
        "  same app gets appended to the Dock twice",
    ),
    (
        "M170-uninstall-mode-arms-on-control",
        "Models/UninstallMode.swift",
        "        modifierFlags.contains(.option)",
        "        modifierFlags.contains(.control)",
        "arm uninstall mode on Control — the bit the LaunchOS binary tests,\n"
        "  but not the modifier its own setting names (Option)",
    ),
    (
        "M171-backup-accepts-any-json",
        "Models/LayoutBackup.swift",
        "              container.format == formatMarker else {",
        "              true else {",
        "import any JSON that happens to decode — another app's file is\n"
        "  accepted as a layout and applied",
    ),
    (
        "M172-backup-accepts-a-future-version",
        "Models/LayoutBackup.swift",
        "        guard container.version <= formatVersion else {",
        "        guard true else {",
        "read a backup written by a newer OpenDeck — the version check that\n"
        "  exists to refuse half-readable containers stops working",
    ),
    (
        "M173-backup-adopts-an-empty-layout",
        "Services/DeckStore.swift",
        "        guard let file = try? JSONDecoder().decode(LayoutFile.self, from: data),\n              !file.pages.isEmpty else { return false }",
        "        guard let file = try? JSONDecoder().decode(LayoutFile.self, from: data) else { return false }",
        "accept a payload that lists no pages — an import wipes the user's\n"
        "  layout and rebuilds it from nothing",
    ),
    (
        "M174-window-mode-keeps-the-deck-level",
        "Models/DisplayMode.swift",
        "                usesDeckLevel: false,",
        "                usesDeckLevel: true,",
        "leave the windowed deck at the full-screen level — a 'window' that\n"
        "  still sits over every other app",
    ),
    (
        "M175-window-mode-covers-the-screen",
        "Models/DisplayMode.swift",
        "                contentSize: CGSize(width: width, height: height)",
        "                contentSize: screen",
        "make the windowed deck full-screen sized — the mode stops being a\n"
        "  window at all",
    ),
    (
        "M176-scroll-mode-still-shows-page-dots",
        "Models/BrowsingStyle.swift",
        "    var showsPageDots: Bool { self == .paged }",
        "    var showsPageDots: Bool { true }",
        "draw page dots over a continuous column — the indicator points at\n"
        "  pages that are not on screen",
    ),
]



def build(sources_dir, out):
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    files = sorted(
        os.path.join(root, f)
        for root, _, names in os.walk(sources_dir)
        for f in names
        if f.endswith(".swift")
    )
    cmd = [
        "swiftc", "-sdk", sdk, "-target", "arm64-apple-macosx15.0",
        "-swift-version", "5", "-Onone",
    ] + files + ["-o", out]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return False, result.stderr[-3000:]
    return True, ""


def run(binary):
    result = subprocess.run([binary, "--selftest"], capture_output=True, text=True)
    lines = result.stdout.splitlines()
    fails = [ln for ln in lines if ln.startswith("FAIL")]
    summary = [ln for ln in lines if "checks passed" in ln]
    if not summary:
        # A crash (a trap aborts the process) is itself a signal.
        summary = ["<no summary — process exited %d>" % result.returncode]
    return fails, summary[-1], result.returncode


def main():
    only = sys.argv[1:] or None
    failures = []
    for name, filename, old, new, why in MUTATIONS:
        if only and name not in only:
            continue
        target = os.path.join(PROJECT, "Sources", "OpenDeck")
        # Locate the file (paths vary by directory). Entries may give a bare
        # name or a path under Sources/OpenDeck — compare both ways, else a
        # "Models/X.swift" entry silently matches nothing ("found 0").
        want = os.path.basename(filename)
        matches = [
            os.path.join(root, f)
            for root, _, names in os.walk(target)
            for f in names
            if f == filename or f == want
        ]
        if len(matches) != 1:
            print("!! %s: expected one %s, found %d" % (name, filename, len(matches)))
            failures.append(name)
            continue
        src = matches[0]
        rel = os.path.relpath(src, os.path.join(PROJECT, "Sources"))

        work = os.path.join(WORK, name)
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(work, exist_ok=True)
        shutil.copytree(os.path.join(PROJECT, "Sources"), os.path.join(work, "Sources"))

        broken = os.path.join(work, "Sources", rel)
        text = open(broken).read()
        if text.count(old) != 1:
            print("!! %s: anchor appears %d time(s), refusing to patch" % (name, text.count(old)))
            failures.append(name)
            continue
        open(broken, "w").write(text.replace(old, new))

        binary = os.path.join(work, "binary")
        ok, err = build(os.path.join(work, "Sources"), binary)
        if not ok:
            print("!! %s: build failed\n%s" % (name, err))
            failures.append(name)
            continue

        fails, summary, code = run(binary)
        print("=" * 78)
        print("%s\n  %s" % (name, why))
        print("  %s" % summary)
        for line in fails:
            print("  %s" % line[:160])
        if fails:
            pass
        elif code != 0:
            # The mutant no longer runs at all — a trap, or a missing summary.
            # Counted as killed, because the code did react to the change. It is
            # called out separately on purpose: a mutant that dies proves the
            # check is not hollow, but says nothing about whether it is *aimed*
            # well. `M76` first landed here — deleting the bounds check made
            # `items[index]` trap, which looked exactly like a surviving mutant
            # until the exit code was read.
            print("  †† MUTATION KILLED BY CRASH (exit %d) — the mutant no longer runs" % code)
        else:
            print("  ★★ MUTATION SURVIVED — the suite is still green; the check is hollow")
            failures.append(name)
        print()
        shutil.rmtree(work, ignore_errors=True)

    print("=" * 78)
    if failures:
        print("MUTATIONS THAT SURVIVED (fix the checks): %s" % ", ".join(failures))
        return 1
    print("ALL MUTATIONS KILLED — every new check has discriminating power")
    return 0


if __name__ == "__main__":
    sys.exit(main())
