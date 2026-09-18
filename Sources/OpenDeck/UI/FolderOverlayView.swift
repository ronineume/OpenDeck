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
    let onDragCommit: () -> Void
    let folderID: UUID
    let metrics: GridMetrics
    let onLaunch: (AppInfo) -> Void
    let onClose: () -> Void

    @StateObject private var zoom = FolderZoomState()
    @FocusState private var nameFocused: Bool

    private var apps: [AppInfo] { store.folderApps(folderID) }

    /// Launchpad sizes a folder panel to its contents; a fixed four-column grid
    /// left a five-app folder as a wide box with a large empty area. The rule
    /// lives in `FolderLayout` so keyboard navigation computes the same count.
    private var columns: Int { FolderLayout.columns(forMemberCount: apps.count) }

    /// Icons inside a folder sit slightly smaller than the grid ones.
    private var folderMetrics: GridMetrics {
        let scale: CGFloat = 0.84
        return GridMetrics(
            columns: columns,
            rows: 0,
            iconSize: (metrics.iconSize * scale).rounded(),
            cellWidth: (metrics.cellWidth * scale).rounded(),
            cellHeight: (metrics.cellHeight * scale).rounded()
        )
    }

    private var needsScrolling: Bool { apps.count > 12 }

    /// Cap the panel at four visible rows and size the viewport to a whole
    /// number of rows, so a scrolled grid never ends mid-icon.
    private var visibleRows: Int {
        let rows = Int(ceil(Double(apps.count) / Double(max(columns, 1))))
        return min(max(rows, 1), 4)
    }

    private var scrollHeight: CGFloat {
        CGFloat(visibleRows) * (folderMetrics.cellHeight + 6)
    }

    private var gridWidth: CGFloat {
        CGFloat(columns) * (folderMetrics.cellWidth + 12) + 24
    }

    private var panelWidth: CGFloat { gridWidth + 60 }

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
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                zoom.expanded = true
            }
        }
        // Two-phase close. SwiftUI's removal transition did not animate
        // reliably here, so the panel is scaled back toward the icon first and
        // only then removed.
        .onChange(of: vm.folderClosing) { _, closing in
            guard closing else { return }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
                zoom.expanded = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                vm.folderClosing = false
                onClose()
            }
        }
    }

    private var blurLayer: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.18))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .transition(.opacity)
            .onTapGesture { vm.folderClosing = true }
    }

    private var panel: some View {
        grid
            .padding(30)
            .transition(.scale(scale: 0.86).combined(with: .opacity))
            .background {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 28, y: 10)
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
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.black)
                .focused($nameFocused)
                .onSubmit(commitName)
                .onExitCommand(perform: cancelRename)
                .padding(.horizontal, 10)
                .frame(width: 200, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                Text(store.folder(folderID)?.name ?? "Folder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    .help("Double-click to rename")
                    .padding(.horizontal, 10)
                    .frame(height: 26)
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
        let content = LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(folderMetrics.cellWidth), spacing: 6),
                count: columns
            ),
            spacing: 6
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
                // Dragging an app out of the folder and onto the grid behind
                // puts it back on the page.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("deck"))
                        .onChanged { value in
                            let page = vm.paging.resolved(count: store.pages.count)
                            if !drag.isActive {
                                // Open a drag session symmetric with the grid
                                // gesture, so the model also defers reclamation
                                // for a folder-member drag (§8.4). Closed in
                                // `commitDrag`'s `defer` via `onDragCommit`.
                                store.beginDragSession()
                                drag.begin(
                                    item: .app(app.id),
                                    app: app,
                                    title: app.name,
                                    index: index,
                                    page: page,
                                    source: .folderMember(folderID),
                                    location: value.location
                                )
                            }
                            drag.update(
                                location: value.location,
                                page: page,
                                metrics: metrics,
                                pageItems: store.pages.indices.contains(page) ? store.pages[page] : [],
                                capacity: metrics.capacity
                            )
                        }
                        .onEnded { _ in onDragCommit() }
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
        .frame(width: gridWidth)

        return Group {
            if needsScrolling {
                ScrollView { content }.frame(height: scrollHeight)
            } else {
                content
            }
        }
    }
}
