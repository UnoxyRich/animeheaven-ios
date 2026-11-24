import AVFoundation
import AVKit
import SwiftUI
import UIKit

public enum VideoResizeMode: String, CaseIterable, Sendable {
    case fit = "Fit"
    case fill = "Fill"
    case zoom = "Zoom"

    public var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resize
        case .zoom: return .resizeAspectFill
        }
    }

    public func next() -> VideoResizeMode {
        switch self {
        case .fit: return .zoom
        case .zoom: return .fill
        case .fill: return .fit
        }
    }
}

@MainActor
public final class PipCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    private var pipController: AVPictureInPictureController?
    public var onPipStateChanged: ((Bool) -> Void)?

    public var isPipSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    public func attach(to playerLayer: AVPlayerLayer) {
        guard isPipSupported else { return }
        if pipController?.playerLayer === playerLayer { return }
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        controller?.delegate = self
        self.pipController = controller
    }

    func detach(from playerLayer: AVPlayerLayer) {
        guard pipController?.playerLayer === playerLayer else { return }
        stopPip()
        pipController?.delegate = nil
        pipController = nil
        onPipStateChanged = nil
    }

    public func startPip() {
        guard let pipController, pipController.isPictureInPicturePossible else { return }
        pipController.startPictureInPicture()
    }

    public func stopPip() {
        guard let pipController, pipController.isPictureInPictureActive else { return }
        pipController.stopPictureInPicture()
    }

    public nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.onPipStateChanged?(true)
        }
    }

    public nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.onPipStateChanged?(false)
        }
    }

    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

final class PlayerContainerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let resizeMode: VideoResizeMode
    let pipCoordinator: PipCoordinator

    func makeCoordinator() -> PipCoordinator { pipCoordinator }

    func makeUIView(context: Context) -> PlayerContainerUIView {
        let view = PlayerContainerUIView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = resizeMode.gravity
        pipCoordinator.attach(to: view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != resizeMode.gravity {
            uiView.playerLayer.videoGravity = resizeMode.gravity
        }
        pipCoordinator.attach(to: uiView.playerLayer)
    }

    static func dismantleUIView(_ uiView: PlayerContainerUIView, coordinator: PipCoordinator) {
        coordinator.detach(from: uiView.playerLayer)
        uiView.playerLayer.player = nil
    }
}
