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

/// How heavy the frosted-glass backdrop is.
///
/// Five tiers. Each one is a **system material** on an `NSVisualEffectView`: the
/// window server composites the real desktop through it every frame, so the
/// backdrop tracks a shuffling wallpaper, a display change or a Space switch
/// with no work of ours.
///
/// The desktop picture is deliberately **never** read back and blurred by hand.
/// That approach cannot stay in sync with a wallpaper the system is free to
/// change, costs a full-screen decode and blur per switch, and is precisely what
/// the system material already does correctly.
///
/// `regular` maps to `.fullScreenUI`, which is what the backdrop used before
/// this was a setting — so an install that never touches the picker renders
/// exactly as it did.
enum GlassMaterial: String, CaseIterable, Identifiable {
    case ultraThin
    case thin
    case regular
    case thick
    case ultraThick

    var id: String { rawValue }

    var material: NSVisualEffectView.Material {
        switch self {
        case .ultraThin: return .underWindowBackground
        case .thin: return .sidebar
        case .regular: return .fullScreenUI
        case .thick: return .hudWindow
        case .ultraThick: return .popover
        }
    }

    var label: String {
        switch self {
        case .ultraThin: return "Ultra thin"
        case .thin: return "Thin"
        case .regular: return "Regular"
        case .thick: return "Thick"
        case .ultraThick: return "Ultra thick"
        }
    }
}

/// What the backdrop actually draws for a given configuration.
///
/// Split out as a value so the rule is checkable rather than buried in a view
/// builder: the live deck takes its frost from a **system material** and never
/// from a blurred copy of the desktop picture, and the only thing ever blurred
/// is an image the user pinned themselves.
enum BackdropRender: Equatable {
    /// Nothing of ours: the window stays transparent and the real desktop shows.
    case liveDesktop
    /// A system material, sampling the real desktop behind the window.
    case systemMaterial(GlassMaterial)
    /// An image is drawn: the user's pinned picture, blurred when the slider is up.
    case picture(blurred: Bool)
}

/// The system material blur.
///
/// This is the same mechanism the Dock, Notification Centre and Launchpad use,
/// so the result always matches the real wallpaper exactly and looks native.
/// Drawing a Gaussian-blurred copy of the wallpaper could never stay in sync
/// with a shuffling desktop, which is why nothing here does it.
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
    /// Which frosted-glass tier the system material uses.
    var glassMaterial: GlassMaterial = .regular

    /// The decision behind the picture, exposed so the self-test can lock it in.
    ///
    /// Pure on purpose: `offscreen` is passed in rather than read from
    /// `AppEnvironment`, so both branches are reachable in one process.
    static func render(
        mode: BackdropMode,
        customImagePath: String?,
        blurRadius: Double,
        glassMaterial: GlassMaterial,
        offscreen: Bool
    ) -> BackdropRender {
        // No desktop exists behind an offscreen render, so the picture is drawn
        // as a stand-in for the material — and drawn **as-is**. The material
        // itself cannot be reproduced without the window server, and blurring
        // the wallpaper to fake it is the thing this design avoids.
        if offscreen { return .picture(blurred: false) }

        switch mode {
        case .desktop:
            return .liveDesktop
        case .glass:
            return .systemMaterial(glassMaterial)
        case .custom:
            // A pinned image is the user's own picture, not the desktop, so the
            // blur slider is allowed to apply to it.
            guard let path = customImagePath, !path.isEmpty else {
                return .systemMaterial(glassMaterial)
            }
            return .picture(blurred: blurRadius > 0)
        }
    }

    private var render: BackdropRender {
        Self.render(
            mode: mode,
            customImagePath: customImagePath,
            blurRadius: blurRadius,
            glassMaterial: glassMaterial,
            offscreen: AppEnvironment.isOffscreenRender
        )
    }

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
        switch render {
        case .liveDesktop:
            Color.clear
        case .systemMaterial(let tier):
            VisualEffectBackdrop(material: tier.material)
        case .picture:
            wallpaperImage
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

    /// The image to draw.
    ///
    /// Only a **pinned image** is ever blurred. The desktop picture reaches this
    /// point only through the offscreen branch of `render`, and is drawn as-is
    /// there.
    private var resolvedImage: NSImage? {
        if mode == .custom, let path = customImagePath, !path.isEmpty {
            if blurRadius > 0 {
                return WallpaperProvider.blurredFile(at: path, radius: blurRadius, for: screen)
            }
            return WallpaperProvider.image(at: path, for: screen)
        }
        return WallpaperProvider.wallpaper(for: screen)
    }
}
