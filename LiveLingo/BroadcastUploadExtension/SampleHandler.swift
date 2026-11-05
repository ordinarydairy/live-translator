import CoreImage
import ReplayKit
import UIKit
import Vision

final class SampleHandler: RPBroadcastSampleHandler {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let queue = DispatchQueue(label: "LiveLingo.OCR", qos: .userInitiated)
    private var lastProcessed = Date.distantPast
    private var isProcessing = false

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        setBroadcastActive(true)
    }

    override func broadcastFinished() {
        setBroadcastActive(false)
    }

    private func setBroadcastActive(_ active: Bool) {
        AppGroup.preferences?.set(active, forKey: AppGroup.broadcastActiveKey)
        AppGroup.preferences?.set(Date().timeIntervalSince1970, forKey: AppGroup.broadcastHeartbeatKey)
        AppGroup.preferences?.synchronize()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              Date().timeIntervalSince(lastProcessed) >= 1.0,
              !isProcessing,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        lastProcessed = Date()
        isProcessing = true
        setBroadcastActive(true)

        queue.async { [weak self] in
            defer {
                self?.isProcessing = false
            }
            self?.recognizeAndStore(pixelBuffer)
        }
    }

    private func recognizeAndStore(_ pixelBuffer: CVPixelBuffer) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = AppGroup.recognitionLanguages
        request.minimumTextHeight = 0.01

        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])
            let observations = (request.results ?? []).compactMap { result -> ScreenObservation? in
                guard let candidate = result.topCandidates(1).first else { return nil }
                let box = result.boundingBox
                return ScreenObservation(text: candidate.string, x: box.minX, y: box.minY, width: box.width, height: box.height)
            }
            try store(pixelBuffer: pixelBuffer, observations: observations)
        } catch {
            // Dropping a frame is preferable to ending the broadcast.
        }
    }

    private func store(pixelBuffer: CVPixelBuffer, observations: [ScreenObservation]) throws {
        guard let frameURL = AppGroup.frameURL,
              let observationURL = AppGroup.observationURL
        else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.72)
        else { return }

        try data.write(to: frameURL, options: Data.WritingOptions.atomic)
        let json = try JSONEncoder().encode(observations)
        try json.write(to: observationURL, options: Data.WritingOptions.atomic)
    }
}

