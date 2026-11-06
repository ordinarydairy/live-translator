import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class PictureInPictureManager: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    @Published private(set) var statusText = "Preparing Picture in Picture"

    private let inlineImageView = UIImageView()
    private let floatingImageView = UIImageView()
    private let floatingController = AVPictureInPictureVideoCallViewController()
    private var controller: AVPictureInPictureController?
    private weak var sourceView: UIView?
    private var latestImage: UIImage?

    override init() {
        super.init()
        [inlineImageView, floatingImageView].forEach {
            $0.contentMode = .scaleAspectFit
            $0.backgroundColor = .black
            $0.clipsToBounds = true
        }

        floatingController.preferredContentSize = CGSize(width: 720, height: 1280)
        floatingImageView.translatesAutoresizingMaskIntoConstraints = false
        floatingController.view.backgroundColor = .black
        floatingController.view.addSubview(floatingImageView)
        NSLayoutConstraint.activate([
            floatingImageView.leadingAnchor.constraint(equalTo: floatingController.view.leadingAnchor),
            floatingImageView.trailingAnchor.constraint(equalTo: floatingController.view.trailingAnchor),
            floatingImageView.topAnchor.constraint(equalTo: floatingController.view.topAnchor),
            floatingImageView.bottomAnchor.constraint(equalTo: floatingController.view.bottomAnchor)
        ])

        let waiting = makeWaitingFrame()
        latestImage = waiting
        inlineImageView.image = waiting
        floatingImageView.image = waiting
    }

    func attach(to view: UIView) {
        guard sourceView !== view else { return }
        sourceView = view
        inlineImageView.removeFromSuperview()
        inlineImageView.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
        view.addSubview(inlineImageView)
        NSLayoutConstraint.activate([
            inlineImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inlineImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inlineImageView.topAnchor.constraint(equalTo: view.topAnchor),
            inlineImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            statusText = "Picture in Picture is unavailable on this device"
            return
        }

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: view,
            contentViewController: floatingController
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
        refreshAvailability()
    }

    func layout(in bounds: CGRect) {
        refreshAvailability()
    }

    func enqueue(_ image: UIImage?) {
        guard let image else { return }
        latestImage = image
        inlineImageView.image = image
        floatingImageView.image = image
        refreshAvailability()
    }

    func toggle() {
        guard let controller else {
            statusText = "Open the live preview before starting Picture in Picture"
            return
        }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
            return
        }
        configureAudioSession()
        attemptStart(retriesRemaining: 12)
    }

    private func attemptStart(retriesRemaining: Int) {
        guard let controller, !controller.isPictureInPictureActive else { return }
        refreshAvailability()
        if controller.isPictureInPicturePossible {
            statusText = "Starting Picture in Picture"
            controller.startPictureInPicture()
            return
        }
        guard retriesRemaining > 0 else {
            statusText = "Picture in Picture is not ready. Keep the preview visible and try again."
            return
        }
        statusText = "Preparing Picture in Picture…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.attemptStart(retriesRemaining: retriesRemaining - 1)
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    private func makeWaitingFrame() -> UIImage {
        let size = CGSize(width: 720, height: 1280)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            NSString(string: "Waiting for live translation…").draw(
                in: CGRect(x: 60, y: 570, width: 600, height: 140),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 38, weight: .semibold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph
                ]
            )
        }
    }

    private func refreshAvailability() {
        isPossible = controller?.isPictureInPicturePossible == true
        if isPossible && !isActive { statusText = "Picture in Picture is ready" }
    }
}

extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = true
            self.statusText = "Picture in Picture is active"
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = false
            self.refreshAvailability()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isActive = false
            self.statusText = "PiP failed: \(error.localizedDescription)"
        }
    }
}

struct PictureInPictureSourceView: UIViewRepresentable {
    let manager: PictureInPictureManager

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        manager.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        manager.layout(in: uiView.bounds)
    }
}
