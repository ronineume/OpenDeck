import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The full-screen deck: backdrop, search field, paged grid and page dots.
///
/// The deck renders; it does not drive the drag. Pointer input reaches
/// `DeckDragHost` through the window (see `DeckWindow.sendEvent`), which is the
/// only place that can see a press before the scroll view, the tiles' tap
/// gestures and the context menus have had a go at it. The view's part is to
/// report geometry the host cannot compute — the grid's frame, the dots' frame,
/// the scroll offset — and to draw the strip.
struct LaunchpadView: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var vm: LaunchpadViewModel
    let metrics: GridMetrics
    let screen: NSScreen
    /// Shared with `DeckDragHost`, which drives it. Deliberately *not* observed
    /// by this view: observing it would re-render the whole deck on every
    /// pointer move.
    let drag: DragState
    /// The moving page strip. Held here only to hand it to `DragStripLayer`, the
    /// one layer that observes it.
    let offset: DragOffsetModel

    @FocusState private var searchFocused: Bool
    @ObservedObject var settings = DeckSettings.shared

    var body: some View {
        ZStack {
            BackdropView(
                screen: screen,
                mode: settings.backdropMode,
                dim: settings.dimStrength,
                customImagePath: settings.pinnedWallpaperPath,
                blurRadius: settings.blurRadius,
                glassMaterial: settings.glassMaterial
            )
            // Clicking empty space dismisses, as Launchpad does.
            .contentShape(Rectangle())
            .onTapGesture { vm.dismiss?() }
            content

            if let folderID = vm.openedFolder {
                FolderOverlayView(
                    store: store,
                    vm: vm,
                    drag: drag,
                    folderID: folderID,
                    metrics: metrics,
                    onLaunch: { app in
                        LaunchService.launch(app)
                        vm.dismiss?()
                    },
                    onClose: { withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { vm.closeFolder() } },
                    // Report 46: the pull-out teardown. The drag is still live,
                    // so this clears the overlay's own state only — the store's
                    // drag session stays open until the commit closes it.
                    onMinimize: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            vm.openedFolder = nil
                            vm.folderOrigin = nil
                            vm.selection = -1
                            vm.isEditingFolderName = false
                        }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "deck")
        .overlay { DragNoticeLayer(drag: drag) }
        .contextMenu { deckMenu }
        .onAppear {
            searchFocused = true
            _ = WallpaperProvider.wallpaper(for: screen)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            SearchBar(
                text: $vm.query,
                isFocused: $searchFocused,
                onSubmit: { vm.activateSelection() },
                onSettings: { vm.openSettings?() }
            )
            .padding(.top, 42)
            .padding(.bottom, 26)

            if vm.isSearching {
                searchResults
            } else if settings.browsingStyle == .scroll {
                // LaunchOS's Scroll style (report 56 §6): the same pages, laid
                // out as one continuous column — no dots, no sideways swipe.
                ScrollDeck(
                    store: store,
                    metrics: metrics,
                    showLabels: settings.showLabels,
                    uninstallModeArmed: settings.holdOptionForUninstall,
                    onOpenApp: { app in
                        LaunchService.launch(app)
                        vm.dismiss?()
                    },
                    onOpenFolder: { vm.openFolder($0) },
                    appMenu: { AnyView(appMenu($0)) },
                    folderMenu: { AnyView(folderMenu($0)) }
                )
            } else {
                PagesScroller(
                    store: store,
                    selection: vm.selection,
                    showLabels: settings.showLabels,
                    uninstallModeArmed: settings.holdOptionForUninstall,
                    onPageSettled: { page in DeckSettings.shared.lastPage = page },
                    openedFolder: vm.openedFolder,
                    drag: drag,
                    badge: drag.badge,
                    offset: offset,
                    landing: offset.landingSignal,
                    onBackgroundTap: { vm.dismiss?() },
                    jumper: vm.jumper,
                    paging: vm.paging,
                    jumpGuard: vm.jumpGuard,
                    metrics: metrics,
                    onOpenApp: { app in
                        LaunchService.launch(app)
                        vm.dismiss?()
                    },
                    onOpenFolder: { vm.openFolder($0) },
                    appMenu: { AnyView(appMenu($0)) },
                    folderMenu: { AnyView(folderMenu($0)) }
                )

                PageDotsView(
                    count: vm.pageCount,
                    paging: vm.paging,
                    jumper: vm.jumper
                )
                .padding(.bottom, 34)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { drag.dotsFrame = proxy.frame(in: .named("deck")); drag.dotCount = vm.pageCount }
                            .onChange(of: proxy.frame(in: .named("deck"))) { _, frame in
                                drag.dotsFrame = frame
                                drag.dotCount = vm.pageCount
                            }
                    }
                }
            }
        }
    }

    // MARK: - Search results

    private var searchResults: some View {
        let results = vm.searchResults
        return Group {
            if results.isEmpty {
                VStack(spacing: 10) {
                    Text("No Results")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("Nothing matches \(vm.query)")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(metrics.cellWidth), spacing: GridMetrics.hSpacing),
                            count: metrics.columns
                        ),
                        spacing: GridMetrics.vSpacing
                    ) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                            AppCell(
                                app: app,
                                metrics: metrics,
                                isSelected: vm.selection == index,
                                isRunning: LaunchService.isRunning(app),
                                showLabel: settings.showLabels,
                                // The decoded hidden badge (report 54 §2).
                                // The pool only includes hidden apps when the
                                // user asked for them in search, so this is
                                // false for every visible result.
                                isHidden: store.hidden.contains(app.id),
                                onUninstallMode: settings.holdOptionForUninstall
                                    ? { NotificationCenter.default.post(name: .deckRequestUninstall, object: app.id) }
                                    : nil,
                                onOpen: {
                                    LaunchService.launch(app)
                                    vm.dismiss?()
                                }
                            )
                            .contextMenu { appMenu(app) }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { vm.dismiss?() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Menus

    @ViewBuilder
    private var deckMenu: some View {
        Button("Close") { vm.dismiss?() }
        Divider()
        Button("OpenDeck Settings…") { vm.openSettings?() }
        Button("Import Launchpad Layout…") {
            NotificationCenter.default.post(name: .deckOpenSettings, object: nil)
        }
        Divider()
        Button("Fill Gaps") { store.fillEmptySlots(capacity: metrics.capacity) }
        Button("Reset Order") { store.restartToDefaultOrder(capacity: metrics.capacity) }
        Button("Reorganize Layout…") {
            NotificationCenter.default.post(name: .deckRequestReorganize, object: nil)
        }
        Divider()
        Button("Export Backup…") { LayoutBackupService.export(store: store) }
        Button("Import Backup…") { LayoutBackupService.importBackup(into: store) }
        Menu("Display Mode") {
            ForEach(DisplayMode.allCases) { mode in
                Button(mode.label) {
                    settings.displayMode = mode
                    // The window is built when the deck opens, so the change
                    // lands on the next open — say so instead of looking dead.
                    NotificationCenter.default.post(name: .deckDisplayModeChanged, object: nil)
                }
            }
        }
        Menu("Browsing Style") {
            ForEach(BrowsingStyle.allCases) { style in
                Button(style.label) { settings.browsingStyle = style }
            }
        }
        Divider()
        Button("Quit OpenDeck") { NSApp.terminate(nil) }
    }

    @ViewBuilder
    func appMenu(_ app: AppInfo) -> some View {
        Button("Open") {
            LaunchService.launch(app)
            vm.dismiss?()
        }
        if LaunchService.isRunning(app) {
            Divider()
            Button("Quit") { LaunchService.quit(app, force: false) }
            Button("Force Quit") { LaunchService.quit(app, force: true) }
        }
        Divider()
        Button("Show in Finder") { LaunchService.revealInFinder(app) }
        Button("Get Info") { LaunchService.showInfo(app) }
        Button("Add to Dock") { DockSync.addToDock(app: app) }
        Divider()
        moveToPageMenu(.app(app.id))
        moveToFolderMenu(appID: app.id)
        newFolderItem(appID: app.id)
        Divider()
        if store.hidden.contains(app.id) {
            Button("Unhide") { store.setHidden(app.id, false) }
        } else {
            Button("Hide") { store.setHidden(app.id, true) }
        }
        Button("Uninstall…") {
            NotificationCenter.default.post(name: .deckRequestUninstall, object: app.id)
        }
    }

    /// "New Folder" — a folder holding just this app, waiting for a second one.
    ///
    /// ⚠️ **This is the one menu item LaunchOS does not have.** Report 41: its
    /// string table (en *and* zh-Hans), its raw binary strings and its selector
    /// list contain no create-folder anything — it can rename, ungroup and move
    /// apps *into* folders, but never make one. So this is a deliberate
    /// departure from parity, not parity, and it is the reason a folder may now
    /// exist with a single member.
    ///
    /// Offered only for a standalone grid slot: an app that is already a folder
    /// member (I2), or is not placed at all, has no slot that could become a
    /// folder. `makeFolder(holding:)` re-checks rather than trusting the menu.
    @ViewBuilder
    func newFolderItem(appID: String) -> some View {
        if store.isGridSlot(appID) {
            Button("New Folder") { store.makeFolder(holding: appID) }
        }
    }

    @ViewBuilder
    func folderMenu(_ fid: UUID) -> some View {
        Button("Open") { vm.openFolder(fid) }
        Divider()
        Button("Ungroup") {
                            withAnimation(.easeOut(duration: MergeMotion.duration)) {
                                store.ungroup(fid)
                            }
                        }
        Divider()
        moveToPageMenu(.folder(fid))
    }

    /// "Move to Page" — the menu route to the same move a drag performs.
    ///
    /// LaunchOS has `moveToPage:` on both its icon view and its folder view;
    /// OpenDeck had no menu route at all, so moving an item meant dragging it —
    /// which a keyboard cannot do at all. The page the item is already on is
    /// listed but disabled, so the menu never looks like it did nothing.
    @ViewBuilder
    func moveToPageMenu(_ slot: DeckSlot) -> some View {
        let current = vm.paging.resolved(count: store.pages.count)
        Menu("Move to Page") {
            ForEach(Array(store.pages.indices), id: \.self) { page in
                Button("Page \(page + 1)") { store.moveItem(slot, toPage: page) }
                    .disabled(page == current)
            }
        }
    }

    /// "Move to Folder" — LaunchOS's `moveToFolder:`, which OpenDeck lacked.
    ///
    /// Only an app can move between folders. A folder already holding the app is
    /// listed but disabled rather than silently doing nothing.
    @ViewBuilder
    func moveToFolderMenu(appID: String) -> some View {
        Menu("Move to Folder") {
            let folders = store.folders.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if folders.isEmpty {
                Text("No folders yet")
            } else {
                ForEach(folders) { folder in
                    Button(folder.name) { store.addToFolder(appID, folder: folder.id) }
                        .disabled(folder.appIDs.contains(appID))
                }
            }
        }
    }

}

/// Offsets the whole page strip by the drag's presented offset.
///
/// This layer exists to be the *only* thing that observes the moving offset. If
/// `PagesScroller` read `applied` itself it would re-evaluate on every frame of
/// every drag, and re-evaluating that body means rebuilding the page grids —
/// which is the "175 cells per frame" problem the scroll observation is already
/// careful to avoid. The content is built once and handed in finished; only the
/// offset changes, and SwiftUI can apply it as a transform.
private struct DragStripLayer<Content: View>: View {
    @ObservedObject private var offset: DragOffsetModel
    private let content: Content

    init(offset: DragOffsetModel, @ViewBuilder content: () -> Content) {
        _offset = ObservedObject(wrappedValue: offset)
        self.content = content()
    }

    var body: some View {
        content.offset(x: offset.applied)
    }
}

/// Explains a drag the deck refused to start.
///
/// The one thing left in an overlay that used to hold three. The icon in the air
/// is AppKit's now — a real dragging session composites it, which is why it
/// tracks the pointer without the main thread doing any work per frame — and the
/// other two, an insertion seam and a 1.2 s countdown ring, were OpenDeck
/// inventions that LaunchOS does not have. What tells the user where a drop will
/// land is the grid itself making room, which is also how the original reads.
///
/// The grid deliberately does not observe `DragState`, so this rides the one
/// overlay that already does — no extra frames for the cells, and it is torn
/// down with the deck.
private struct DragNoticeLayer: View {
    @ObservedObject var drag: DragState

    @ViewBuilder
    var body: some View {
        if let notice = drag.blockedNotice {
            Text(notice)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.7), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .padding(.bottom, 54)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Backdrop

// MARK: - Paged grid

/// The horizontally paged grid.
///
/// The page is derived from the live scroll geometry, so a swipe moves the
/// indicator as it crosses each page boundary without republishing every frame.
/// The scroll position is deliberately *not* a two-way binding on shared state:
/// that published twice per frame and rebuilt all 175 cells.
///
/// The deck as one continuous vertical column — LaunchOS's `Scroll` browsing
/// style (report 56 §6).
///
/// The store keeps its page model either way; this view simply lays every
/// page's slots out one after another, with no page boundaries, no dots and no
/// sideways swipe. Cells register their frames in `FrameRegistry` exactly as
/// the paged grid does, so drag, drop targets and the context menus keep
/// working unchanged.
///
/// **Not carried over from paged mode**: the keyboard's arrow-key selection
/// (it indexes into a page, and there are no pages on screen here) and the
/// page-dot indicator. Both are named in report 56 §7.
private struct ScrollDeck: View {
    @ObservedObject var store: DeckStore
    let metrics: GridMetrics
    let showLabels: Bool
    let uninstallModeArmed: Bool
    let onOpenApp: (AppInfo) -> Void
    let onOpenFolder: (UUID) -> Void
    let appMenu: (AppInfo) -> AnyView
    let folderMenu: (UUID) -> AnyView

    private var items: [DeckSlot] { store.pages.flatMap { $0 } }

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(metrics.cellWidth), spacing: GridMetrics.hSpacing),
                    count: metrics.columns
                ),
                spacing: GridMetrics.vSpacing
            ) {
                ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
                    cell(item)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func cell(_ item: DeckSlot) -> some View {
        Group {
            switch item {
            case .app(let id):
                if let app = store.app(id: id) {
                    AppCell(
                        app: app,
                        metrics: metrics,
                        isRunning: LaunchService.isRunning(app),
                        showLabel: showLabels,
                        isDropHover: store.dropHoverAppID == id,
                        onUninstallMode: uninstallModeArmed
                            ? { NotificationCenter.default.post(name: .deckRequestUninstall, object: app.id) }
                            : nil,
                        onOpen: { onOpenApp(app) }
                    )
                    .contextMenu { appMenu(app) }
                }
            case .folder(let fid):
                FolderCell(
                    apps: store.folderApps(fid),
                    name: store.folder(fid)?.name ?? "Folder",
                    metrics: metrics,
                    showLabel: showLabels,
                    isDropHover: store.dropHoverFolderID == fid,
                    onOpen: { onOpenFolder(fid) }
                )
                .contextMenu { folderMenu(fid) }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        FrameRegistry.shared.record(item.id, frame: proxy.frame(in: .global))
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        FrameRegistry.shared.record(item.id, frame: frame)
                    }
            }
        }
    }
}

/// No gesture recogniser lives here any more. A drag is a window-level affair
/// (see `DeckDragHost`): a `DragGesture` could not express the 4-point slop the
/// original uses, and once a dragging session is running AppKit stops delivering
/// dragged events to this view at all.
private struct PagesScroller: View {
    @ObservedObject var store: DeckStore
    /// Only the raw selection index, so that selection changes repaint cells.
    let selection: Int
    let showLabels: Bool
    /// Whether "Hold Option for Uninstall" is on (report 56 §4) — arms the
    /// apps' tap routing.
    let uninstallModeArmed: Bool
/// Reports the settled page so it can be remembered across launches.
    let onPageSettled: (Int) -> Void
    /// The tile of the open folder hides so the growing panel replaces it.
    let openedFolder: UUID?
    /// Not observed: the drag drives itself; the window routes the input.
    let drag: DragState
    /// Which tile is lifted out of the grid. Observed — it changes twice per
    /// drag, and the grid has to hide that tile while it is in the air.
    @ObservedObject var badge: DragSourceBadge
    /// Deliberately not observed *here*: only `DragStripLayer` reads it, so a
    /// strip moving at display rate never re-evaluates the pages.
    let offset: DragOffsetModel
    /// Observed, and it has to be: this view is the only thing that can move the
    /// scroll view to catch the strip as it lands, so it has to be re-evaluated
    /// when the landing is published. It is a separate object from `offset`
    /// precisely so that observing it does not drag the per-frame offset in with
    /// it — see `DragLandingSignal`.
    @ObservedObject var landing: DragLandingSignal
    let onBackgroundTap: () -> Void
    @ObservedObject var jumper: PageJumper
    /// THE page model. Deliberately **not** observed here: observing it would
    /// rebuild the grid on every settled page (see `PagingModel`'s invariant).
    let paging: PagingModel
    /// Arbitration for programmatic jumps, owned by the view model. A class, and
    /// deliberately not observed here: recording the page each geometry callback
    /// reports must **not** re-evaluate this view on every scroll tick.
    let jumpGuard: PageJumpGuard
    let metrics: GridMetrics
    let onOpenApp: (AppInfo) -> Void
    let onOpenFolder: (UUID) -> Void
    let appMenu: (AppInfo) -> AnyView
    let folderMenu: (UUID) -> AnyView

    private var pageCount: Int { max(store.pages.count, 1) }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    // The strip is drawn *inside* the scroll view and offset by
                    // the drag, on top of wherever the scroll view has put it.
                    // This layer is the only thing that observes the moving
                    // offset, so the pages themselves are never re-evaluated at
                    // display rate.
                    DragStripLayer(offset: offset) {
                        // Eager on purpose — this must NOT be a LazyHStack.
                        //
                        // A lazy stack materialises each page asynchronously, on
                        // the layout pass that brings it near the viewport. During
                        // a fast swipe the paging snap lands on the destination
                        // page's offset *before* that page has been built, so the
                        // viewport is left showing a blank page. It only recovers
                        // when something forces materialisation — which is exactly
                        // what tapping a page dot does: `applyJump`'s
                        // `proxy.scrollTo(page, anchor: .center)` both builds the
                        // page and re-snaps to its true centre. The dot tap looked
                        // like a fix for what was really a blank-page race.
                        //
                        // A launchpad has only a handful of viewport-sized pages,
                        // so laying them all out up front is cheap and is what
                        // LaunchOS / Launchpad does. This does **not** reintroduce
                        // the per-scroll-tick rebuild the design guards against:
                        // the strip still does not observe `paging`, and a plain
                        // swipe changes none of the states this view observes, so
                        // the body is never re-evaluated per frame.
                        HStack(spacing: 0) {
                            ForEach(0 ..< pageCount, id: \.self) { page in
                                pageGrid(page)
                                    .frame(width: geo.size.width)
                                    .id(page)
                            }
                        }
                        .scrollTargetLayout()
                    }
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { drag.gridFrame = proxy.frame(in: .named("deck")) }
                            .onChange(of: proxy.frame(in: .named("deck"))) { _, frame in
                                drag.gridFrame = frame
                            }
                    }
                }
                // Purpose-built scroll observation. Tracking the offset through a
                // PreferenceKey never fired here, which is why the dots stayed
                // on page 0 while swiping.
                .onScrollGeometryChange(for: Int.self) { geometry in
                    let width = max(geometry.containerSize.width, 1)
                    return Int((geometry.contentOffset.x / width).rounded())
                } action: { _, page in
                    guard page >= 0, page < pageCount else { return }
                    // A jump reports every page it passes through on the way. One
                    // of those adopted here would overwrite the jump before it
                    // lands and persist the wrong page — see `PageJumpGuard`.
                    guard jumpGuard.observe(reported: page,
                                            requested: paging.resolved(count: pageCount)) else { return }
                    paging.set(page, count: pageCount)
                    onPageSettled(page)
                }
                // The raw scroll offset, recorded rather than published: it
                // changes on every scroll frame and republishing it would
                // rebuild the grid. A drag reads it once, as it begins.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.x
                } action: { _, x in
                    drag.scrollOffset = x
                }
                // The hand-back. Both writes land in one transaction, so the
                // scroll view takes over the position the strip is already at.
                // Done apart, the deck would show a page it is not on for a
                // single frame — the flash this whole design exists to avoid.
                //
                // Driven from `landing` (an object this view observes) and not
                // from `offset.landing`: `onChange` only fires when the view is
                // re-evaluated, and this view deliberately does not observe the
                // per-frame offset. Reading the landing off it meant the signal
                // was published into the void and the deck was left wherever the
                // drag had pushed it.
                .onChange(of: landing.page) { _, page in
                    guard let page else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(page, anchor: .center)
                        paging.set(page, count: pageCount)
                        onPageSettled(page)
                        offset.completeLanding()
                    }
                }
                .onChange(of: jumper.target) { _, target in
                    guard let target else { return }
                    // LaunchOS has no fixed page-jump animation. A page turn *is*
                    // the display-link glide it also uses for an edge-dwell drag
                    // (report 33, ported in `DragMotion`/`DragOffsetModel`). So a
                    // dot tap or an arrow key glides via that same motion instead
                    // of an invented easeInOut — and the landing snaps the scroll
                    // view in one transaction, exactly like a drag hand-back.
                    //
                    // The glide needs a display server. Headless runs (`--bench`,
                    // `--selftest`) have none — `DragOffsetModel` deliberately
                    // never starts its link there — so they take the direct
                    // scroll path, which is what lets the suite assert the scroll
                    // view actually moved to the page.
                    if canGlide {
                        DispatchQueue.main.async { jumper.target = nil }
                        let clamped = min(max(target, 0), pageCount - 1)
                        if paging.resolved(count: pageCount) != clamped {
                            glideToPage(clamped)
                        }
                    } else {
                        applyJump(target, proxy: proxy)
                    }
                }
                // A target published *before* this view existed never reaches
                // `onChange` at all: `onChange` reports changes, and by the time
                // the grid appears the change has already happened. That is
                // exactly the resume-last-page case — the window controller names
                // the page as it builds the view. Consuming it here is what makes
                // the jump happen, instead of being lost and then overwritten by
                // the grid's own first report.
                .onAppear {
                    // `show()` has already cleared the guard, through
                    // `vm.reset()`, so all that is left is to consume the page
                    // the controller asked for.
                    applyJump(jumper.target, proxy: proxy, animated: false)
                }
            }
        }
    }

    /// Drives the scroll view to a jumped-to page.
    ///
    /// - Parameter animated: `false` for the page restored at open. Animating
    ///   that one would show the first page sliding across to the remembered one,
    ///   which is not what "resume where I left off" means.
    private func applyJump(_ target: Int?, proxy: ScrollViewProxy, animated: Bool = true) {
        guard let target else { return }
        // Clear the signal first: the jump no longer needs the value, and
        // publishing from inside a view update is not safe.
        DispatchQueue.main.async { jumper.target = nil }
        let clamped = min(max(target, 0), pageCount - 1)
        paging.set(clamped, count: pageCount)
        // Arm *before* asking for the scroll: the scroll view can report the page
        // it is leaving within the same frame, and by then the guard has to
        // already know a jump is on its way.
        guard jumpGuard.arm(clamped) else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo(clamped, anchor: .center)
            }
        } else {
            proxy.scrollTo(clamped, anchor: .center)
        }
    }

    /// Whether a programmatic page jump may ride the real display-link glide.
    ///
    /// Headless runs (`--bench`, `--selftest`) build the view but never start a
    /// display link — `DragOffsetModel` refuses to, by design — so the glide
    /// cannot run there and those runs fall back to the direct `applyJump`
    /// scroll, which is what lets the suite assert the scroll view actually
    /// moved. A laid-out grid (`gridFrame.width > 0`) is required for the glide's
    /// page width to be meaningful.
    private var canGlide: Bool {
        !AppEnvironment.isHeadless && !AppEnvironment.isOffscreenRender && drag.gridFrame.width > 0
    }

    /// Glides the page strip to `page` with the ported LaunchOS motion, reusing
    /// the very `DragOffsetModel` an edge-dwell drag turns pages with.
    ///
    /// The strip approaches the page frame by frame (report 33's ramp) while the
    /// scroll view stays put; once it settles, `offset` publishes its landing and
    /// the existing `landing` observer swaps the scroll view over in one
    /// transaction — the same two-phase hand-back a drag landing uses, and the
    /// same reason there is no "missed a frame" flash. There is deliberately no
    /// duration here: the pace is LaunchOS's measured ramp, not ours.
    private func glideToPage(_ page: Int) {
        offset.begin(scrollOffset: Double(drag.scrollOffset),
                     pageWidth: Double(drag.gridFrame.width),
                     pageCount: pageCount)
        offset.nudge(to: page)
        offset.release()
    }

    private func pageGrid(_ page: Int) -> some View {
        // Never render more items than the grid can hold: the empty-slot range
        // below becomes invalid (and traps) if items.count exceeds capacity.
        let capacity = metrics.capacity
        let all = (page >= 0 && page < store.pages.count) ? store.pages[page] : []
        let items = Array(all.prefix(capacity))

        return VStack {
            Spacer(minLength: 0)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(metrics.cellWidth), spacing: GridMetrics.hSpacing),
                    count: metrics.columns
                ),
                spacing: GridMetrics.vSpacing
            ) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    cell(item, index: index, page: page)
                }
                ForEach(items.count ..< capacity, id: \.self) { _ in
                    EmptySlot(metrics: metrics, isTargeted: false)
                        .onTapGesture(perform: onBackgroundTap)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .background {
            // Empty space *inside* the page must dismiss. Relying on the click
            // falling through to the backdrop does not work: a ScrollView
            // swallows events for its entire frame, gaps between icons
            // included.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onBackgroundTap)
        }
    }

    @ViewBuilder
    private func cell(_ item: DeckSlot, index: Int, page: Int) -> some View {
        let isSelected = selection == index

        Group {
            switch item {
            case .app(let id):
                if let app = store.app(id: id) {
                    AppCell(
                        app: app,
                        metrics: metrics,
                        isSelected: isSelected,
                        isRunning: LaunchService.isRunning(app),
                        showLabel: showLabels,
                        isDropHover: store.dropHoverAppID == id,
                        onUninstallMode: uninstallModeArmed
                            ? { NotificationCenter.default.post(name: .deckRequestUninstall, object: app.id) }
                            : nil,
                        onOpen: { onOpenApp(app) }
                    )
                    .contextMenu { appMenu(app) }
                }
            case .folder(let fid):
                FolderCell(
                    apps: store.folderApps(fid),
                    name: store.folder(fid)?.name ?? "Folder",
                    metrics: metrics,
                    isSelected: isSelected,
                    showLabel: showLabels,
                    isOpen: openedFolder == fid,
                    mergePulse: store.mergeFlash?.folderID == fid ? store.mergeFlash : nil,
                    isDropHover: store.dropHoverFolderID == fid,
                    onOpen: {
                        // The decoded LaunchOS open motion (report 54 §1):
                        // 0.28 s ease-in-out, same as the panel's own expand.
                        withAnimation(OpenMotion.animation) {
                            onOpenFolder(fid)
                        }
                    }
                )
                .contextMenu { folderMenu(fid) }
                .transition(.scale(scale: MergeMotion.scale).combined(with: .opacity))
                .opacity(openedFolder == fid ? 0 : 1)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        FrameRegistry.shared.record(item.id, frame: proxy.frame(in: .global))
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        FrameRegistry.shared.record(item.id, frame: frame)
                    }
            }
        }
        // The tile that is in the air is hidden, so the deck shows one icon
        // instead of two. Hidden rather than removed, because the frame
        // registry still has to see it — a folder's zoom proxy is measured from
        // exactly this frame.
        .opacity(badge.slotID == item.id ? 0 : 1)
    }

}

/// The rounded search field, with the settings button to the left of the
/// magnifying glass.
struct SearchBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var onSettings: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            PassthroughButton(
                systemImage: "gearshape.fill",
                accessibilityLabel: "OpenDeck Settings — also on right-click anywhere",
                action: onSettings
            )

            Rectangle()
                .fill(.white.opacity(0.16))
                .frame(width: 1, height: 15)

            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .focused(isFocused)
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 310, height: 34)
        .background {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                }
        }
    }
}

/// One page dot. The tap target only: a drag crosses pages by moving the strip
/// (see `DragOffsetModel.nudge`), not by a system drop target.
private struct PageDot: View {
    let index: Int
    let isCurrent: Bool
    /// The current page count, so a tap can write through the clamped API.
    let count: Int
    /// Not observed by a single dot: a tap only writes; the owner redraws the row.
    let paging: PagingModel
    let jumper: PageJumper

    var body: some View {
        Circle()
            .fill(.white.opacity(isCurrent ? 0.95 : 0.32))
            .frame(width: 7, height: 7)
            .contentShape(Rectangle().inset(by: -9))
            .onTapGesture {
                // Single clamped write; the jump signal carries its result.
                jumper.target = paging.set(index, count: count)
            }
    }
}

/// Page indicator dots. Observes only the settled page.
struct PageDotsView: View {
    let count: Int
    @ObservedObject var paging: PagingModel
    let jumper: PageJumper

    var body: some View {
        HStack(spacing: 9) {
            ForEach(0 ..< max(count, 1), id: \.self) { index in
                PageDot(
                    index: index,
                    isCurrent: index == paging.resolved(count: count),
                    count: count,
                    paging: paging,
                    jumper: jumper
                )
            }
        }
        .padding(.top, 18)
    }
}

extension Notification.Name {
    static let deckRequestUninstall = Notification.Name("OpenDeck.requestUninstall")
    static let deckOpenSettings = Notification.Name("OpenDeck.openSettings")
    static let deckRequestReorganize = Notification.Name("OpenDeck.requestReorganize")
    /// The display mode changed; the deck must be rebuilt to match (report 56 §5).
    static let deckDisplayModeChanged = Notification.Name("OpenDeck.displayModeChanged")
}
