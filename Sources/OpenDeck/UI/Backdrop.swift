import SwiftUI
import AppKit

/// How the deck is backed.
enum BackdropMode: String, CaseIterable, Identifiable {
    /// The real desktop, subtly dimmed. This is what Launchpad itself does.
    case desktop
    /// The real desktop, blurred by the system material.
    case glass
    /// A specific image chosen by the user.
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .desktop: return "Desktop"
        case .glass: return "Frosted glass"
        case .custom: return "Custom image"
        }
    }

    var detail: String {
        switch self {
        case .desktop: return "Your actual desktop, slightly dimmed — what Launchpad does"
        case .glass: return "Your desktop blurred by the system material"
        case .custom: return "Pin one image, ignoring the desktop"
        }
    }
}

/// The system material blur.
///
/// This is the same mechanism the Dock, Notification Centre and Launchpad use,
/// so the result always matches the real wallpaper exactly and looks native.
/// Drawing a Gaussian-blurred copy of the wallpaper (the previous approach)
/// could never stay in sync with a shuffling desktop.
struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.state = .active
    }
}

/// The wallpaper layer of the deck.
struct BackdropView: View {
    let screen: NSScreen
    let mode: BackdropMode
    let dim: Double
    let customImagePath: String?
    let blurRadius: Double

    var body: some View {
        ZStack {
            layer
            // Both Apple and LaunchOS dim the backdrop so white labels stay
            // legible; the system material alone is not enough.
            Color.black.opacity(dim)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var layer: some View {
        if AppEnvironment.isOffscreenRender {
            // No desktop exists behind an offscreen render, so draw the image.
            wallpaperImage
        } else {
            switch mode {
            case .desktop:
                Color.clear
            case .glass:
                VisualEffectBackdrop()
            case .custom:
                if customImagePath != nil {
                    wallpaperImage
                } else {
                    VisualEffectBackdrop()
                }
            }
        }
    }

    @ViewBuilder
    private var wallpaperImage: some View {
        if let image = resolvedImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(
                colors: [Color(white: 0.12), Color(white: 0.03)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var resolvedImage: NSImage? {
        if mode == .custom, let path = customImagePath {
            if blurRadius > 0 {
                return WallpaperProvider.blurredFile(at: path, radius: blurRadius, for: screen)
            }
            return WallpaperProvider.image(at: path, for: screen)
        }
        if blurRadius > 0 {
            return WallpaperProvider.blurredWallpaper(for: screen, radius: blurRadius)
        }
        return WallpaperProvider.wallpaper(for: screen)
    }
}
