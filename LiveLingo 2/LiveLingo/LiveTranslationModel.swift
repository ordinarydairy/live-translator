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
    @Published var translations: [TranslatedObservation] = []
    @Published var isReceiving = false
    @Published var sourceLanguage = LanguageChoice.choices[0] { didSet { resetTranslation() } }
    @Published var targetLanguage = LanguageChoice.choices[1] { didSet { resetTranslation() } }
    @Published var showOriginalText = false {
        didSet { translations = translations.map { .init(id: $0.id, observation: $0.observation, translatedText: $0.translatedText, showOriginal: showOriginalText) } }
    }
    @Published var translationConfiguration: TranslationSession.Configuration?

    private var pollingTask: Task<Void, Never>?
    private var pending: [ScreenObservation] = []
    private var lastObservationData: Data?
    private var translationGeneration = 0

    var statusText: String { isReceiving ? "Receiving live screen" : "Ready to translate" }

    func startPolling() async {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadLatestFrame()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
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
        } catch {
            guard generation == translationGeneration else { return }
            translations = current.map { .init(id: $0.id, observation: $0, translatedText: $0.text, showOriginal: showOriginalText) }
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
}

