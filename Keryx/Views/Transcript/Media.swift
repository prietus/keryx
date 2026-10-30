import SwiftUI
import AppKit
import AVKit

/// An image that plays if it's animated (GIF): `NSImageView` animates GIF
/// frames natively, which SwiftUI's `Image` can't. With "Reduce motion" on,
/// or animation turned off in Settings, it stays still and plays on hover.
struct AnimatedImage: NSViewRepresentable {
    let image: NSImage
    var animates: Bool

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.isEditable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
        view.animates = animates
    }
}

extension NSImage {
    /// More than one frame: a GIF (or similar) worth animating.
    var isAnimated: Bool {
        representations.contains { (($0 as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? Int ?? 1) > 1 }
    }
}

enum Motion {
    /// The user asked macOS for less motion.
    @MainActor static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// "0:42", "12:05", "1:02:10".
func formattedDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// The ▶ over a poster, and the running time in a corner.
struct PlayBadge: View {
    var duration: TimeInterval?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "play.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: Circle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let duration, duration > 0 {
                Text(verbatim: formattedDuration(duration))
                    .font(Chrome.small.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                    .padding(5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A linked video file: its first frame with ▶ and the running time.
/// Click plays it right here with the system's controls, never by itself;
/// ⌘-click (or double-click) opens it outside. Only the bytes needed for
/// the first frame are fetched until you press play.
struct VideoPlate: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let url: URL
    @State private var poster: NSImage?
    @State private var duration: TimeInterval?
    @State private var naturalSize: CGSize?
    @State private var playing = false
    @State private var unplayable = false

    var body: some View {
        let maxHeight = CGFloat(model.preferences.imageSize)
        let natural = naturalSize ?? poster?.size ?? CGSize(width: 16, height: 9)
        let size = fit(natural, maxWidth: maxHeight * 1.8, maxHeight: maxHeight, upscale: playing)
        Group {
            if playing {
                InlinePlayer(url: url)
                    .frame(width: max(size.width, 240), height: max(size.height, 135))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else if !unplayable {
                ZStack {
                    if let poster {
                        Image(nsImage: poster).resizable().interpolation(.high)
                    } else {
                        Rectangle().fill(Palette.rule.opacity(0.5))
                    }
                    PlayBadge(duration: duration)
                }
                .frame(width: max(size.width, 160), height: max(size.height, 90))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openURL(url) }
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.command) { openURL(url) } else { playing = true }
                }
                .help(url.absoluteString)
            }
        }
        .padding(.vertical, 2)
        .task(id: url) { await loadPoster() }
    }

    private func loadPoster() async {
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable else {
            unplayable = true
            return
        }
        duration = (try? await asset.load(.duration)).map(\.seconds).flatMap { $0.isFinite ? $0 : nil }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            naturalSize = CGSize(width: abs(rect.width), height: abs(rect.height))
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        if let (image, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) {
            poster = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    private func fit(_ natural: CGSize, maxWidth: CGFloat, maxHeight: CGFloat, upscale: Bool) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        var scale = min(maxWidth / natural.width, maxHeight / natural.height)
        if !upscale { scale = min(scale, 1) }
        return CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }
}

/// The system's own player, inline, started when shown.
private struct InlinePlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = AVPlayer(url: url)
        view.player?.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
