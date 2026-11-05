import CoreImage
import ReplayKit
import Vision

final class SampleHandler: RPBroadcastSampleHandler {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let queue = DispatchQueue(label: "LiveLingo.OCR", qos: .userInitiated)
    private var lastProcessed = Date.distantPast
    private var isProcessing = false

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              Date().timeIntervalSince(lastProcessed) >= 0.7,
              !isProcessing,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        lastProcessed = Date()
        isProcessing = true
        CVPixelBufferRetain(pixelBuffer)

        queue.async { [weak self] in
            defer {
                CVPixelBufferRelease(pixelBuffer)
                self?.isProcessing = false
            }
            self?.recognizeAndStore(pixelBuffer)
        }
    }

    private func recognizeAndStore(_ pixelBuffer: CVPixelBuffer) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.018

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
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [.lossyCompressionQuality: 0.72]) else { return }

        try data.write(to: frameURL, options: .atomic)
        let json = try JSONEncoder().encode(observations)
        try json.write(to: observationURL, options: .atomic)
    }
}

