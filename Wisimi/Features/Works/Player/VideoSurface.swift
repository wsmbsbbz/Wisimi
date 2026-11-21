import AVFoundation
import SwiftUI
import UIKit

/// A presentation surface only; playback commands stay in WorkAudioPlayer.
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> VideoSurfaceView {
        let view = VideoSurfaceView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: VideoSurfaceView, context: Context) {
        view.playerLayer.player = scenePhase == .background ? nil : player
    }

    static func dismantleUIView(_ view: VideoSurfaceView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class VideoSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
