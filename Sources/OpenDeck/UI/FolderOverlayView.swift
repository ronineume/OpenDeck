import SwiftUI
import AppKit

/// Drives the folder open/close transition.
final class FolderZoomState: ObservableObject {
    @Published var expanded = false
}

/// Expanded folder view.
///
/// Mirrors LaunchOS's approach: `OpenedFolderBlurView` blurs the deck behind
/// with a system material, and `FolderAnimationProxy*` animates the panel out
/// of the icon. The proxy is reproduced here by transforming the panel from the
/// icon's recorded frame, which is why it does not use `matchedGeometryEffect`.
struct FolderOverlayView: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var vm: LaunchpadViewModel
    /// Shared with the deck so an app can be dragged out onto the grid.
    let drag: DragState
    let folderID: UUID
    let metrics: GridMetrics
    let onLaunch: (AppInfo) -> Void
    let onClose: () -> Void
    /// Report 46 — the pull-out teardown. Fires after the collapse that a
    /// mid-drag exit asked for (`vm.folderMinimizing`). Deliberately **not**
    /// `onClose`: the drag is still live, so the store's drag session must stay
    /// open and only the overlay's own state may be cleared.
    let onMinimize: () -> Void

    @StateObject private var zoom = FolderZoomState()
    @FocusState private var nameFocused: Bool

    private var apps: [AppInfo] { store.folderApps(folderID) }

    /// Launchpad sizes a folder panel with the page's column count (LaunchOS's
    /// `columnsPerPage` — see `FolderLayout`): a fixed-width, left-aligned grid
    /// that only grows in height as the folder gains members.
    private var columns: Int { FolderLayout.columns(pageColumns: metrics.columns) }

    /// Icons inside a folder sit slightly smaller than the grid ones.
    private var folderMetrics: GridMetrics {
        let scale: CGFloat = 0.84
        return GridMetrics(
            columns: columns,
            rows: 0,
            iconSize: (metrics.iconSize * scale).rounded(),
            cellWidth: (metrics.cellWidth * scale).rounded(),
            cellHeight: (metrics.cellHeight * scale).rounded(),
            // The captions inside the panel follow the **user's** icon scale,
            // like the grid's do (report 49). The 0.84 above is the panel's own
            // geometry, not a font decision — scaling the caption by it as well
            // would shrink the name for a reason nobody asked for.
            iconScale: metrics.iconScale
        )
    }

    /// Spacing between folder tiles, in both directions.
    ///
    /// Named because the drag hit test has to undo exactly this to work out which
    /// tile a press landed on — a bare `6` in two files is how the two drift.
    private static let tileSpacing: CGFloat = 6

    /// Rows the grid needs at the page's column count. The panel grows in height
    /// with this (LaunchOS fixed-width, height-variable), never in width.
    private var rows: Int {
        max(1, Int(ceil(Double(apps.count) / Double(max(columns, 1)))))
    }

    /// Past four rows the panel is scrolled rather than grown — OpenDeck's own
    /// cap (LaunchOS's exact scroll threshold is not decoded), so a very large
    /// folder doesn't run off the screen.
    private var needsScrolling: Bool { rows > 4 }

    /// Cap the panel at four visible rows and size the viewport to a whole
    /// number of rows, so a scrolled grid never ends mid-icon.
    private var visibleRows: Int {
        return min(rows, 4)
    }

    private var scrollHeight: CGFloat {
        CGFloat(visibleRows) * (folderMetrics.cellHeight + 6)
    }

    /// The tiles' own width: what the hit test walks to find a column.
    private var gridContentWidth: CGFloat {
        CGFloat(columns) * folderMetrics.cellWidth
            + CGFloat(max(columns - 1, 0)) * Self.tileSpacing
    }

    private var gridWidth: CGFloat { gridContentWidth + 24 }

    private var panelWidth: CGFloat { gridWidth + 60 }

    /// The plate's breathing room around the grid. Exported because the drag
    /// host's pull-out test (`DragState.exitedPanel`) has to measure the same
    /// visible bounds the user sees — a bare `30` in two files is how they drift.
    static let panelPadding: CGFloat = 30

    /// Folder title / rename text sizes. LaunchOS's folder type is noticeably
    /// larger than OpenDeck's was; its exact point sizes aren't decoded constants,
    /// so these are tuned to live preview — nudge them here to move all sites.
    static let titleFontSize: CGFloat = 17
    static let renameFontSize: CGFloat = 20

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                blurLayer
                    .opacity(zoom.expanded ? 1 : 0)

                // Kept fully opaque: the panel is *seen* growing out of the
                // icon, so fading it in would hide the whole effect.
                panel
                    .scaleEffect(zoom.expanded ? 1 : startScale, anchor: .center)
                    .offset(
                        x: zoom.expanded ? 0 : startOffset(in: geo.size).width,
                        y: zoom.expanded ? 0 : startOffset(in: geo.size).height
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            guard !AppEnvironment.freezeFolderAnimation else { return }
            // LaunchOS's decoded open motion: 0.28 s ease-in-out
            // (`OpenMotion`, report 54 §1) — not a spring.
            withAnimation(OpenMotion.animation) {
                zoom.expanded = true
            }
        }
        // Two-phase close. SwiftUI's removal transition did not animate
        // reliably here, so the panel is scaled back toward the icon first and
        // only then removed. Report 46 adds a second trigger with the same
        // shape: a mid-drag exit (`folderMinimizing`) collapses the panel while
        // the pull-out drag keeps flying, and tears the overlay down lightly.
        .onChange(of: vm.folderClosing) { _, closing in
            guard closing else { return }
            collapseThen {
                vm.folderClosing = false
                onClose()
            }
        }
        .onChange(of: vm.folderMinimizing) { _, minimizing in
            guard minimizing else { return }
            collapseThen {
                vm.folderMinimizing = false
                onMinimize()
            }
        }
        .onDisappear { vm.folderPanel = nil }
    }

    /// The shared two-phase collapse: scale the panel back toward the icon,
    /// then run the teardown once the motion is over. The two triggers differ
    /// **only** in what the teardown is — the animation is the same close.
    private func collapseThen(_ then: @escaping () -> Void) {
        // The close is the open motion, reversed — measured from LaunchOS,
        // resolving the report-54 §4 open item that used to leave this a spring.
        // The open's `NSAnimationContext` block (`FUN_10010df6c`) sets **0.28 s**
        // + `kCAMediaTimingFunctionEaseInEaseOut` on the frame/opacity/transform
        // animations of the `FolderAnimationProxy`, and there is no separate
        // `runAnimationGroup` for the dismiss — it reuses that same group. So the
        // close is 0.28 s ease-in-out (`OpenMotion`), and the teardown waits the
        // same 0.28 s the animation actually runs (the old 0.26/0.9 spring with a
        // 0.24 s delay was a placeholder, not a measurement).
        withAnimation(OpenMotion.animation) {
            zoom.expanded = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + OpenMotion.duration) {
            then()
        }
    }

    private var blurLayer: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            // Light backdrop veil: dims the deck just enough for white type to
            // read over a now-clearer panel. Kept low so the folder still sees
            // through — LaunchOS's liquid-glass look is transparent, not frosted.
            .overlay(Color.black.opacity(0.08))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .transition(.opacity)
            .onTapGesture { vm.folderClosing = true }
    }

    private var panel: some View {
        grid
            .padding(Self.panelPadding)
            .transition(.scale(scale: 0.86).combined(with: .opacity))
            .background {
                // A clear glass sheet rather than a frosted plate: a very light
                // translucent fill over the (lightly blurred) deck, kept legible
                // by a stronger top specular highlight and a brighter edge.
                ZStack {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(.white.opacity(0.07))
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.22), .white.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
            }
            // LaunchOS keeps the title in a separate `FolderFloatingTitleView`
            // for exactly this reason: as a sibling in the panel's stack, the
            // text field's intrinsic width widened the whole folder.
            .overlay(alignment: .top) {
                floatingTitle.offset(y: -34)
            }
    }

    // MARK: - Proxy geometry

    /// The panel starts at the icon's size, so this is icon : panel.
    private var startScale: CGFloat {
        guard vm.folderOrigin != nil, panelWidth > 1 else { return 0.92 }
        return min(max(metrics.iconSize / panelWidth, 0.04), 1)
    }

    /// Offset from the panel's centre back to the icon's centre.
    ///
    /// The registry stores the whole cell (icon plus label), so the label band
    /// is subtracted to land on the icon itself.
    private func startOffset(in container: CGSize) -> CGSize {
        guard let origin = vm.folderOrigin else { return .zero }
        let labelBand = (metrics.cellHeight - metrics.iconSize) / 2
        return CGSize(
            width: origin.midX - container.width / 2,
            height: origin.midY - labelBand - container.height / 2
        )
    }

    // MARK: - Floating title (rename)

    /// Sits above the panel, outside its layout, so renaming can never resize
    /// the folder. In edit mode it becomes a small white field.
    /// The rename field hugs its text — LaunchOS's box is "just a bit bigger than
    /// the text" (not OpenDeck's old fixed 200 pt field), and its font is a bit
    /// larger. Measured with AppKit so it is exact and synchronous, with no
    /// GeometryReader round-trip. `folderNameDraft` is observed by this view
    /// already (the field edits it), so the width tracks typing live.
    private var nameFieldWidth: CGFloat {
        let text = vm.folderNameDraft.isEmpty ? " " : vm.folderNameDraft
        let measured = (text as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: Self.renameFontSize, weight: .semibold)])
            .width
        return min(max(measured + 34, 110), 420)
    }

    private var floatingTitle: some View {
        ZStack {
            if vm.isEditingFolderName {
                TextField(
                    "Folder",
                    text: Binding(
                        get: { vm.folderNameDraft },
                        set: { vm.folderNameDraft = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: Self.renameFontSize, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.black)
                .focused($nameFocused)
                .onSubmit(commitName)
                .onExitCommand(perform: cancelRename)
                .padding(.horizontal, 12)
                .frame(width: nameFieldWidth, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                Text(store.folder(folderID)?.name ?? "Folder")
                    .font(.system(size: Self.titleFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    .help("Double-click to rename")
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginRename() }
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: vm.isEditingFolderName)
    }

    private func beginRename() {
        vm.folderNameDraft = store.folder(folderID)?.name ?? ""
        withAnimation(.easeInOut(duration: 0.16)) {
            vm.isEditingFolderName = true
        }
        // Focus once the field exists.
        DispatchQueue.main.async { nameFocused = true }
    }

    private func cancelRename() {
        withAnimation(.easeInOut(duration: 0.16)) {
            vm.isEditingFolderName = false
        }
    }

    private func commitName() {
        store.rename(folderID, to: vm.folderNameDraft)
        withAnimation(.easeInOut(duration: 0.16)) {
            vm.isEditingFolderName = false
        }
    }

    // MARK: - Grid

    private var grid: some View {
        // Sized to the tiles, with the registry frame measured on exactly that
        // box: the drag hit test walks `cellWidth + spacing` across it to work
        // out which tile a press landed on, so measuring the padded container
        // instead would offset every hit by the padding.
        let content = LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(folderMetrics.cellWidth), spacing: Self.tileSpacing),
                count: columns
            ),
            spacing: Self.tileSpacing
        ) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                AppCell(
                    app: app,
                    metrics: folderMetrics,
                    isSelected: vm.selection == index,
                    isRunning: LaunchService.isRunning(app),
                    showLabel: DeckSettings.shared.showLabels,
                    onOpen: { onLaunch(app) }
                )
                .contextMenu {
                    Button("Open") { onLaunch(app) }
                    Divider()
                    Button("Remove from Folder") {
                        store.removeFromFolder(app.id, folder: folderID)
                        if store.folder(folderID) == nil { onClose() }
                    }
                }
            }
        }
        .frame(width: gridContentWidth)
        .background { geometryReporter }

        return Group {
            if needsScrolling {
                ScrollView { content }.frame(height: scrollHeight)
            } else {
                content
            }
        }
        .frame(width: gridWidth)
    }

    /// Publishes the tiles' frame so the window's drag hit test can find them.
    ///
    /// Only the view knows where the panel is — it is laid out here, animated
    /// from the icon's frame, and never told to the window. Dragging a member out
    /// and onto the grid is handled at the window level (`DeckDragHost`), the same
    /// path the grid itself uses, so the same panel geometry has to reach it.
    private var geometryReporter: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { recordPanel(proxy) }
                .onChange(of: proxy.frame(in: .named("deck"))) { _, _ in recordPanel(proxy) }
        }
    }

    private func recordPanel(_ proxy: GeometryProxy) {
        vm.folderPanel = FolderPanelLayout(
            frame: proxy.frame(in: .named("deck")),
            columns: columns,
            cellWidth: folderMetrics.cellWidth,
            cellHeight: folderMetrics.cellHeight,
            hSpacing: Self.tileSpacing,
            vSpacing: Self.tileSpacing
        )
    }
}
