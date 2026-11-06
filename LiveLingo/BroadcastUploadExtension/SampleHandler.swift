import CoreImage
import ImageIO
import Network
import ReplayKit
import UIKit
import Vision

final class SampleHandler: RPBroadcastSampleHandler {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let queue = DispatchQueue(label: "LiveLingo.OCR", qos: .userInitiated)
    private var lastProcessed = Date.distantPast
    private var isProcessing = false
    private var stopListener: NWListener?

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        AppGroup.preferences?.set(false, forKey: AppGroup.stopBroadcastKey)
        setBroadcastActive(true)
        startStopListener()
    }

    override func broadcastFinished() {
        stopListener?.cancel()
        stopListener = nil
        setBroadcastActive(false)
    }

    private func setBroadcastActive(_ active: Bool) {
        AppGroup.preferences?.set(active, forKey: AppGroup.broadcastActiveKey)
        AppGroup.preferences?.set(Date().timeIntervalSince1970, forKey: AppGroup.broadcastHeartbeatKey)
        AppGroup.preferences?.synchronize()
    }

    private func startStopListener() {
        guard let listener = try? NWListener(using: .tcp, on: LoopbackTransport.stopPort) else { return }
        stopListener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { data, _, _, _ in
                connection.cancel()
                guard data == Data("STOP".utf8) else { return }
                self?.setBroadcastActive(false)
                self?.finishBroadcastWithError(NSError(
                    domain: "LiveLingo.Broadcast",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Broadcast stopped from LiveLingo"]
                ))
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        AppGroup.preferences?.synchronize()
        if AppGroup.preferences?.bool(forKey: AppGroup.stopBroadcastKey) == true {
            AppGroup.preferences?.set(false, forKey: AppGroup.stopBroadcastKey)
            setBroadcastActive(false)
            finishBroadcastWithError(NSError(
                domain: "LiveLingo.Broadcast",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Broadcast stopped from LiveLingo"]
            ))
            return
        }

        guard sampleBufferType == .video,
              Date().timeIntervalSince(lastProcessed) >= 1.0,
              !isProcessing,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        lastProcessed = Date()
        isProcessing = true
        setBroadcastActive(true)
        let frameOrientation = orientation(from: sampleBuffer)

        queue.async { [weak self] in
            defer {
                self?.isProcessing = false
            }
            self?.recognizeAndStore(pixelBuffer, orientation: frameOrientation)
        }
    }

    private func orientation(from sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let value = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber else { return .up }
        return CGImagePropertyOrientation(rawValue: value.uint32Value) ?? .up
    }

    private func recognizeAndStore(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = AppGroup.recognitionLanguages
        request.minimumTextHeight = 0.01

        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([request])
            var results = request.results ?? []

            if results.isEmpty {
                let fallback = VNRecognizeTextRequest()
                fallback.recognitionLevel = .accurate
                fallback.usesLanguageCorrection = true
                fallback.automaticallyDetectsLanguage = true
                fallback.minimumTextHeight = 0.008
                try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([fallback])
                results = fallback.results ?? []
            }

            let region = AppGroup.translationRegion
            let observations = results.compactMap { result -> ScreenObservation? in
                guard let candidate = result.topCandidates(1).first else { return nil }
                let box = result.boundingBox
                if let region, !region.contains(CGPoint(x: box.midX, y: box.midY)) { return nil }
                return ScreenObservation(text: candidate.string, x: box.minX, y: box.minY, width: box.width, height: box.height)
            }
            try store(pixelBuffer: pixelBuffer, orientation: orientation, observations: observations)
        } catch {
            // Dropping a frame is preferable to ending the broadcast.
        }
    }

    private func store(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        observations: [ScreenObservation]
    ) throws {
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.72)
        else { return }

        let json = try JSONEncoder().encode(observations)
        if let frameURL = AppGroup.frameURL,
           let observationURL = AppGroup.observationURL {
            try data.write(to: frameURL, options: Data.WritingOptions.atomic)
            try json.write(to: observationURL, options: Data.WritingOptions.atomic)
        }
        LoopbackTransport.sendFrame(imageData: data, observationsData: json)
    }
}

