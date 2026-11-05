import Foundation
import SwiftUI
import Translation
import Vision

struct LanguageChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let code: String

    static let choices = [
        LanguageChoice(id: "auto", name: "Auto-detect", code: ""),
        LanguageChoice(id: "en", name: "English", code: "en"),
        LanguageChoice(id: "es", name: "Spanish", code: "es"),
        LanguageChoice(id: "fr", name: "French", code: "fr"),
        LanguageChoice(id: "de", name: "German", code: "de"),
        LanguageChoice(id: "ja", name: "Japanese", code: "ja"),
        LanguageChoice(id: "ko", name: "Korean", code: "ko"),
        LanguageChoice(id: "zh", name: "Chinese", code: "zh-Hans")
    ]
}

struct TranslatedObservation: Identifiable {
    let id: UUID
    let observation: ScreenObservation
    var translatedText: String
    var showOriginal: Bool
    var displayText: String { showOriginal ? "\(observation.text)\n\(translatedText)" : translatedText }
}

@MainActor
final class LiveTranslationModel: ObservableObject {
    @Published var frameImage: UIImage?
    @Published var pictureInPictureFrame: UIImage?
    @Published var translations: [TranslatedObservation] = []
    @Published var isReceiving = false
    @Published var isBroadcasting = false
    @Published var sourceLanguage = LanguageChoice.choices[0] {
        didSet {
            AppGroup.preferences?.set(sourceLanguage.code, forKey: AppGroup.sourceLanguageKey)
            resetTranslation()
        }
    }
    @Published var targetLanguage = LanguageChoice.choices[1] { didSet { resetTranslation() } }
    @Published var showOriginalText = false {
        didSet {
            translations = translations.map { .init(id: $0.id, observation: $0.observation, translatedText: $0.translatedText, showOriginal: showOriginalText) }
            renderPictureInPictureFrame()
        }
    }
    @Published var translationConfiguration: TranslationSession.Configuration?

    private var pollingTask: Task<Void, Never>?
    private var pending: [ScreenObservation] = []
    private var lastObservationData: Data?
    private var translationGeneration = 0
    private var optimisticBroadcastUntil = Date.distantPast

    var statusText: String { isReceiving ? "Receiving live screen" : "Ready to translate" }

    func startPolling() async {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshBroadcastStatus()
                await self?.loadLatestFrame()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func refreshBroadcastStatus() {
        AppGroup.preferences?.synchronize()
        let active = AppGroup.preferences?.bool(forKey: AppGroup.broadcastActiveKey) ?? false
        let heartbeat = AppGroup.preferences?.double(forKey: AppGroup.broadcastHeartbeatKey) ?? 0
        let recentlyActive = Date().timeIntervalSince1970 - heartbeat < 4
        isBroadcasting = (active && recentlyActive) || Date() < optimisticBroadcastUntil
    }

    func beginBroadcastSession() {
        optimisticBroadcastUntil = Date().addingTimeInterval(15)
        isBroadcasting = true
        AppGroup.preferences?.set(false, forKey: AppGroup.stopBroadcastKey)
        AppGroup.preferences?.synchronize()
    }

    func requestBroadcastStop() {
        optimisticBroadcastUntil = .distantPast
        isBroadcasting = false
        AppGroup.preferences?.set(true, forKey: AppGroup.stopBroadcastKey)
        AppGroup.preferences?.synchronize()
    }

    private func loadLatestFrame() async {
        guard let frameURL = AppGroup.frameURL,
              let observationURL = AppGroup.observationURL,
              let imageData = try? Data(contentsOf: frameURL),
              let observationData = try? Data(contentsOf: observationURL),
              observationData != lastObservationData,
              let image = UIImage(data: imageData),
              let observations = try? JSONDecoder().decode([ScreenObservation].self, from: observationData)
        else { return }

        lastObservationData = observationData
        accept(image: image, observations: observations, live: true)
    }

    func scanImportedImage(_ image: UIImage) async {
        let normalizedImage = normalized(image)
        guard let cgImage = normalizedImage.cgImage else { return }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = AppGroup.recognitionLanguages(for: sourceLanguage.code)
        request.minimumTextHeight = 0.01

        do {
            try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
            let observations = (request.results ?? []).compactMap { result -> ScreenObservation? in
                guard let candidate = result.topCandidates(1).first else { return nil }
                let box = result.boundingBox
                return ScreenObservation(text: candidate.string, x: box.minX, y: box.minY, width: box.width, height: box.height)
            }
            accept(image: normalizedImage, observations: observations, live: false)
        } catch {
            translations = []
        }
    }

    private func accept(image: UIImage, observations: [ScreenObservation], live: Bool) {
        frameImage = image
        pictureInPictureFrame = image
        isReceiving = live
        pending = observations
        translations = []
        translationGeneration += 1
        requestTranslation()
    }

    private func requestTranslation() {
        translationConfiguration?.invalidate()
        translationConfiguration = nil
        guard !pending.isEmpty else {
            return
        }
        let generation = translationGeneration
        let sourceCode = sourceLanguage.code
        let targetCode = targetLanguage.code
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, generation == self.translationGeneration else { return }
            self.translationConfiguration = .init(
                source: sourceCode.isEmpty ? nil : Locale.Language(identifier: sourceCode),
                target: Locale.Language(identifier: targetCode)
            )
        }
    }

    func translatePending(using session: TranslationSession) async {
        guard !pending.isEmpty else { return }
        let current = pending
        let generation = translationGeneration
        do {
            let requests = current.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString) }
            let responses = try await session.translations(from: requests)
            let byID = Dictionary(uniqueKeysWithValues: responses.compactMap { response -> (String, String)? in
                guard let id = response.clientIdentifier else { return nil }
                return (id, response.targetText)
            })
            guard generation == translationGeneration else { return }
            translations = current.map {
                TranslatedObservation(
                    id: $0.id,
                    observation: $0,
                    translatedText: byID[$0.id.uuidString] ?? $0.text,
                    showOriginal: showOriginalText
                )
            }
            renderPictureInPictureFrame()
        } catch {
            guard generation == translationGeneration else { return }
            translations = current.map { .init(id: $0.id, observation: $0, translatedText: $0.text, showOriginal: showOriginalText) }
            renderPictureInPictureFrame()
        }
    }

    private func resetTranslation() {
        translations = []
        translationGeneration += 1
        requestTranslation()
    }

    private func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private func renderPictureInPictureFrame() {
        guard let image = frameImage else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        pictureInPictureFrame = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))

            for item in translations {
                let box = item.observation
                let originalRect = CGRect(
                    x: box.x * image.size.width,
                    y: (1 - box.y - box.height) * image.size.height,
                    width: max(box.width * image.size.width, 24),
                    height: max(box.height * image.size.height, 18)
                )
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                let bubbleRect = originalRect.insetBy(dx: -2, dy: -1)
                let textRect = bubbleRect.insetBy(dx: 4, dy: 2)
                var fontSize = max(8, min(28, originalRect.height * 0.7))
                var attributes: [NSAttributedString.Key: Any] = [:]
                while fontSize >= 6 {
                    attributes = [
                        .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                        .foregroundColor: UIColor.white,
                        .paragraphStyle: paragraph
                    ]
                    let measured = NSString(string: item.displayText).boundingRect(
                        with: textRect.size,
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: attributes,
                        context: nil
                    )
                    if measured.width <= textRect.width && measured.height <= textRect.height { break }
                    fontSize -= 1
                }

                UIColor.black.withAlphaComponent(0.86).setFill()
                UIBezierPath(roundedRect: bubbleRect, cornerRadius: 4).fill()
                item.displayText.draw(
                    in: textRect,
                    withAttributes: attributes
                )
            }
        }
    }
}

