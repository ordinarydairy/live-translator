import AVFoundation
import AVKit
import CoreImage
import SwiftUI

@MainActor
final class PictureInPictureManager: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false

    let displayLayer = AVSampleBufferDisplayLayer()
    private let renderContext = CIContext(options: [.useSoftwareRenderer: false])
    private var controller: AVPictureInPictureController?
    private weak var sourceView: UIView?

    func attach(to view: UIView) {
        guard sourceView !== view else { return }
        sourceView = view
        displayLayer.removeFromSuperlayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = view.bounds
        view.layer.addSublayer(displayLayer)

        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
        enqueue(makeWaitingFrame())
        refreshAvailability()
    }

    func layout(in bounds: CGRect) {
        displayLayer.frame = bounds
        refreshAvailability()
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            configureAudioSession()
            attemptStart(retriesRemaining: 8)
        }
    }

    private func attemptStart(retriesRemaining: Int) {
        guard let controller, !controller.isPictureInPictureActive else { return }
        refreshAvailability()
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
            return
        }
        guard retriesRemaining > 0 else { return }
        controller.invalidatePlaybackState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.attemptStart(retriesRemaining: retriesRemaining - 1)
        }
    }

    func enqueue(_ image: UIImage?) {
        guard let image,
              let ciImage = CIImage(image: image),
              let pixelBuffer = makePixelBuffer(width: 720, height: 1280)
        else { return }

        let sourceExtent = ciImage.extent
        let scale = min(720 / sourceExtent.width, 1280 / sourceExtent.height)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (720 - scaled.extent.width) / 2
        let y = (1280 - scaled.extent.height) / 2
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: x, y: y))
        let outputBounds = CGRect(x: 0, y: 0, width: 720, height: 1280)
        let background = CIImage(color: .black).cropped(to: outputBounds)
        let output = positioned.composited(over: background)

        renderContext.render(
            output,
            to: pixelBuffer,
            bounds: outputBounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        guard let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sampleBuffer)
        refreshAvailability()
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        return buffer
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        return sampleBuffer
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
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 38, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            NSString(string: "Waiting for live translation…").draw(
                in: CGRect(x: 60, y: 570, width: 600, height: 140),
                withAttributes: attributes
            )
        }
    }

    private func refreshAvailability() {
        isPossible = controller?.isPictureInPicturePossible == true
    }
}

extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }
}

extension PictureInPictureManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) { completionHandler() }

    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool { true }
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
