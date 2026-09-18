import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The full-screen deck: backdrop, search field, paged grid and page dots.
struct LaunchpadView: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var vm: LaunchpadViewModel
    let metrics: GridMetrics
    let screen: NSScreen

    @FocusState private var searchFocused: Bool
    @ObservedObject var settings = DeckSettings.shared
    /// Created but deliberately *not* observed here: observing it would
    /// re-render the whole deck on every pointer move.
    @StateObject private var drag = DragState()

    var body: some View {
        ZStack {
            BackdropView(
                screen: screen,
                mode: settings.backdropMode,
                dim: settings.dimStrength,
                customImagePath: settings.pinnedWallpaperPath,
                blurRadius: settings.blurRadius
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
                    onDragCommit: { commitDrag() },
                    folderID: folderID,
                    metrics: metrics,
                    onLaunch: { app in
                        LaunchService.launch(app)
                        vm.dismiss?()
                    },
                    onClose: { withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { vm.closeFolder() } }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "deck")
        .overlay { DragProxyLayer(drag: drag, metrics: metrics) }
        .contextMenu { deckMenu }
        .onAppear {
            searchFocused = true
            _ = WallpaperProvider.wallpaper(for: screen)
            // Drag outcomes are delivered through closures so that the drag
            // state never has to be observed by this view.
            drag.onRequestPage = { page in
                // Single clamped write point (`PagingModel.set` clamps): an
                // unclamped -1 used to reach `store.pages[-1]` and trap.
                vm.jumper.target = vm.paging.set(page, count: vm.pageCount)
            }
            drag.onFolderDrop = { source, target in
                switch target {
                case .app(let targetID):
                    store.makeFolder(dropping: source, onto: targetID)
                case .folder(let folderID):
                    store.addToFolder(source, folder: folderID)
                }
                drag.reset()
            }
            // Reflow while dragging so a gap follows the pointer.
            drag.onLiveMove = { slot, index in
                guard let from = store.locate(slot) else { return }
                let page = vm.paging.resolved(count: store.pages.count)
                let count = store.pages.indices.contains(page) ? store.pages[page].count : 0
                store.move(
                    itemAt: from,
                    to: IndexPath(item: min(max(index, 0), count), section: page)
                )
            }
            drag.deckSize = screen.frame.size
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
            } else {
                PagesScroller(
                    store: store,
                    selection: vm.selection,
                    showLabels: settings.showLabels,
                    onPageSettled: { page in DeckSettings.shared.lastPage = page },
                    onDragCommit: { commitDrag() },
                    openedFolder: vm.openedFolder,
                    drag: drag,
                    onBackgroundTap: { vm.dismiss?() },
                    jumper: vm.jumper,
                    paging: vm.paging,
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

    /// Resolve what the drag should do and apply it in one step.
    func commitDrag() {
        // Kill any half-finished rest-to-merge *before* the button-up is acted
        // on. `reset()` below also cancels it, but doing it first removes any
        // doubt that a pending dwell could mature after the pointer is released
        // ("手都松了还突然成组").
        drag.cancelFolderDwell()
        // Read the page through the single derived point (§2.2): never a stored,
        // possibly-stale index.
        let page = vm.paging.resolved(count: store.pages.count)
        let items = store.pages.indices.contains(page) ? store.pages[page] : []
        let action = drag.drop(metrics: metrics, pageItems: items)
        let dragged = drag.item
        // Both captured *before* `reset()` (which clears `source`→`.grid` and
        // `item`→nil). The explicit source lets the commit dispatch on where the
        // drag came from instead of re-resolving it with `store.locate(...)`,
        // which returns nil for a folder member (phenomenon B's root cause).
        let source = drag.source
        drag.reset()
        // One write for the whole drag. `endDragSession` reclaims the empty
        // pages deferred during the drag (Q1/§8.2) and then flushes exactly once.
        defer { store.endDragSession() }

        guard let slot = dragged else { return }
        switch action {
        case .none:
            break
        case .toPage(let target):
            // There is no grid cell under a page dot, so the item lands at the
            // end of the target page — matching Launchpad's dot-drop behaviour.
            let targetPage = DragState.clampPage(target, count: store.pages.count)
            switch (source, slot) {
            case (.folderMember(let fid), .app(let appID)):
                // Phenomenon B fix: an explicit folder-member source no longer
                // routes through a `locate()` that silently returns nil.
                let tail = store.pages.indices.contains(targetPage) ? store.pages[targetPage].count : 0
                if store.moveOutOfFolder(appID, folder: fid, toPage: targetPage, index: tail) {
                    // §8.3/L5: pulling a member out leaves that folder's view.
                    vm.folderClosing = true
                }
            default:
                store.moveItem(slot, toPage: targetPage)
            }
        case .toIndex(let index):
            switch (source, slot) {
            case (.folderMember(let fid), .app(let appID)):
                // Q3: the drop lands on the cell the pointer released over
                // (`hoverIndex`, carried by `drop()`), never `liveIndex` — a
                // folder member does not reflow, so only `hoverIndex` is valid.
                if store.moveOutOfFolder(appID, folder: fid, toPage: page, index: index) {
                    // Two-phase close: the overlay animates itself back toward
                    // the icon, then removes itself.
                    vm.folderClosing = true
                }
            case (.grid, _):
                guard let from = store.locate(slot) else { break }
                let limit = store.pages.indices.contains(page) ? store.pages[page].count : 0
                store.move(itemAt: from, to: IndexPath(item: min(max(index, 0), limit), section: page))
            default:
                break
            }
        }
    }

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

    @ViewBuilder
    func folderMenu(_ fid: UUID) -> some View {
        Button("Open") { vm.openFolder(fid) }
        Divider()
        Button("Ungroup") { store.ungroup(fid) }
    }

}

/// Draws the icon that follows the pointer while dragging, plus the drop
/// affordance for the slot under the pointer.
///
/// The grid deliberately does **not** observe `DragState` (observing it rebuilt
/// every cell on each pointer move — see `PagesScroller.drag`), so this overlay
/// is the one ready-made anchor that already observes the drag and holds
/// `metrics`. Two *mutually exclusive* affordances live here, which is what
/// finally makes "reorder" and "merge" tellable apart:
///   • a straight insertion seam while the drag means "reorder";
///   • a circular halo + progress ring while a 1.2 s rest means "merge".
private struct DragProxyLayer: View {
    @ObservedObject var drag: DragState
    let metrics: GridMetrics

    @ViewBuilder
    var body: some View {
        if drag.isActive, let app = drag.proxyApp {
            ZStack {
                targetAffordance

                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: metrics.iconSize, height: metrics.iconSize)
                    .scaleEffect(1.12)
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 7)
                    .position(drag.location)
            }
            .allowsHitTesting(false)
        }
    }

    /// Bounds of the slot under the pointer, in the deck's coordinate space.
    ///
    /// `gridFrame` is the scroll viewport in deck coordinates, and
    /// `GridHitTester` centres the grid inside that viewport exactly like the
    /// page grid does, so the mapping is 1:1 with what is on screen.
    private func targetRect() -> CGRect? {
        guard let index = drag.hoverIndex, drag.gridFrame.width > 0 else { return nil }
        let tester = GridHitTester(
            metrics: metrics,
            itemCount: drag.itemCount,
            containerSize: drag.gridFrame.size,
            slotCount: drag.capacity
        )
        let centre = tester.centre(of: index)
        return CGRect(
            x: drag.gridFrame.minX + centre.x - metrics.cellWidth / 2,
            y: drag.gridFrame.minY + centre.y - metrics.cellHeight / 2,
            width: metrics.cellWidth,
            height: metrics.cellHeight
        )
    }

    @ViewBuilder
    private var targetAffordance: some View {
        if let rect = targetRect() {
            // Mutual exclusion is the whole point: a running combine shows the
            // ring and never the seam; a plain reorder shows only the seam.
            if drag.combineProgress > 0 {
                combineRing(in: rect)
            } else {
                insertionSeam(in: rect)
            }
        }
    }

    /// Linear marker — "the dragged item lands here" (reorder).
    private func insertionSeam(in rect: CGRect) -> some View {
        let height = metrics.cellHeight * 0.52
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(.white.opacity(0.9))
            .frame(width: 4, height: height)
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            .position(x: rect.minX, y: rect.midY)
            // Slides between slots instead of teleporting.
            .animation(.spring(response: 0.28, dampingFraction: 0.80), value: rect.midY)
    }

    /// Circular marker — "release now and these two merge" (1.2 s countdown).
    ///
    /// Contrast is the point. Everything used to fade in *linearly* with
    /// `progress`, so a freshly-armed countdown was invisible and a bare white
    /// arc disappeared on a bright wallpaper. Now:
    ///   • a **constant-opacity track** makes "the countdown has started" read on
    ///     the very first frame;
    ///   • the **progress arc** is a solid, dark-shadowed, rounded stroke, floored
    ///     to a visible minimum so a just-started countdown shows as a small tick;
    ///   • the **halo** snaps to a fixed strength instead of crawling to a faint
    ///     0.16;
    ///   • the **diameter is enlarged** so the dragged icon (`scaleEffect` 1.12,
    ///     drawn above this) can never cover the ring.
    ///
    /// Driven by `combineProgress`, which ticks every 1/60 s, so no implicit
    /// animation is applied (that would fight the ticker).
    private func combineRing(in rect: CGRect) -> some View {
        let progress = drag.combineProgress
        let diameter = metrics.iconSize * 1.5
        // An arc shorter than a line-cap is invisible; floor it so the start reads.
        let arc = max(progress, 0.03)
        // Halo reaches its fixed strength within ~0.2 s, then stays.
        let halo = min(progress * 6, 1) * 0.20
        return ZStack {
            // Dark separation ring so the marker reads on a bright wallpaper too.
            Circle()
                .stroke(.black.opacity(0.35), lineWidth: 1)
                .frame(width: diameter + 6, height: diameter + 6)
            // Halo: a fixed, readable plate (not a linear crawl to a faint value).
            Circle()
                .fill(.white.opacity(halo))
                .frame(width: diameter, height: diameter)
            // Constant track: visible the instant the dwell arms.
            Circle()
                .stroke(.white.opacity(0.30), lineWidth: 3.5)
                .frame(width: diameter, height: diameter)
            // Progress arc: solid white, dark-shadowed, rounded.
            Circle()
                .trim(from: 0, to: arc)
                .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(-90))
                .shadow(color: .black.opacity(0.55), radius: 2.5, y: 0.5)
        }
        .position(x: rect.midX, y: rect.midY)
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
private struct PagesScroller: View {
    @ObservedObject var store: DeckStore
    /// Only the raw selection index, so that selection changes repaint cells.
    let selection: Int
    let showLabels: Bool
    /// Reports the settled page so it can be remembered across launches.
    let onPageSettled: (Int) -> Void
    /// Commits the drag. Owned by LaunchpadView so the folder overlay shares it.
    let onDragCommit: () -> Void
    /// The tile of the open folder hides so the growing panel replaces it.
    let openedFolder: UUID?
    /// Not observed: the drag drives itself and reports back through closures.
    let drag: DragState
    let onBackgroundTap: () -> Void
    @ObservedObject var jumper: PageJumper
    /// THE page model. Deliberately **not** observed here: observing it would
    /// rebuild the grid on every settled page (see `PagingModel`'s invariant).
    let paging: PagingModel
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
                // (grid frame captured below)
                    LazyHStack(spacing: 0) {
                        ForEach(0 ..< pageCount, id: \.self) { page in
                            pageGrid(page)
                                .frame(width: geo.size.width)
                                .id(page)
                        }
                    }
                    .scrollTargetLayout()
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
                    guard page >= 0, page < pageCount,
                          page != paging.resolved(count: pageCount) else { return }
                    paging.set(page, count: pageCount)
                    onPageSettled(page)
                }
                // On the container, not on each cell: flipping pages mid-drag
                // recycles the source cell in the lazy stack and would cancel
                // a per-cell gesture, which is what broke cross-page dragging.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("deck"))
                        .onChanged(handleDragChange)
                        .onEnded { _ in onDragCommit() }
                )
                .onChange(of: jumper.target) { _, target in
                    guard let target else { return }
                    DispatchQueue.main.async { jumper.target = nil }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(min(max(target, 0), pageCount - 1), anchor: .center)
                    }
                }
            }
        }
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
                    onOpen: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                            onOpenFolder(fid)
                        }
                    }
                )
                .contextMenu { folderMenu(fid) }
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
    }

    /// Start the drag from the slot under the pointer's *starting* position,
    /// then keep tracking on this stable view.
    private func handleDragChange(_ value: DragGesture.Value) {
        let page = paging.resolved(count: store.pages.count)
        let items = (page >= 0 && page < store.pages.count) ? store.pages[page] : []

        if !drag.isActive {
            let local = CGPoint(
                x: value.startLocation.x - drag.gridFrame.minX,
                y: value.startLocation.y - drag.gridFrame.minY
            )
            let tester = GridHitTester(
                metrics: metrics,
                itemCount: items.count,
                containerSize: drag.gridFrame.size,
                slotCount: metrics.capacity
            )
            guard let index = tester.index(at: local), index < items.count else { return }
            // Open a drag session: defer page reclamation and hold writes until
            // the drag lands (§8.2/§8.4).
            store.beginDragSession()

            let item = items[index]
            let proxy: AppInfo? = {
                if case .app(let id) = item { return store.app(id: id) }
                return nil
            }()
            let title: String? = {
                if case .folder(let id) = item { return store.folder(id)?.name }
                return proxy?.name
            }()
            drag.begin(
                item: item,
                app: proxy,
                title: title,
                index: index,
                page: page,
                location: value.location
            )
        }

        drag.update(
            location: value.location,
            page: page,
            metrics: metrics,
            pageItems: items,
            capacity: metrics.capacity
        )
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

/// One page dot. Cross-page dragging is handled by `DragState`'s edge bands and
/// dot hover, not by a system drop target, so this is only a tap target.
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
}
