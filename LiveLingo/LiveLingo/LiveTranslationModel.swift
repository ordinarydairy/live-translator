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
    @Published var regionEnabled = AppGroup.preferences?.bool(forKey: AppGroup.regionEnabledKey) ?? false
    @Published var regionCenterX = 0.5
    @Published var regionCenterY = 0.5
    @Published var regionWidth = 0.9
    @Published var regionHeight = 0.45

    private var pollingTask: Task<Void, Never>?
    private let loopbackServer = LoopbackFrameServer()
    private var pending: [ScreenObservation] = []
    private var lastObservationData: Data?
    private var translationGeneration = 0
    private var optimisticBroadcastUntil = Date.distantPast
    private var lastTextSignature = ""
    private var translationRequestedAt = Date.distantPast

    init() {
        let preferences = AppGroup.preferences
        if preferences?.object(forKey: AppGroup.regionWidthKey) != nil {
            let x = preferences?.double(forKey: AppGroup.regionXKey) ?? 0.05
            let y = preferences?.double(forKey: AppGroup.regionYKey) ?? 0.275
            regionWidth = max(0.1, preferences?.double(forKey: AppGroup.regionWidthKey) ?? 0.9)
            regionHeight = max(0.1, preferences?.double(forKey: AppGroup.regionHeightKey) ?? 0.45)
            regionCenterX = x + regionWidth / 2
            regionCenterY = y + regionHeight / 2
        }
    }

    func saveTranslationRegion() {
        let width = min(max(regionWidth, 0.1), 1)
        let height = min(max(regionHeight, 0.1), 1)
        let x = min(max(regionCenterX - width / 2, 0), 1 - width)
        let y = min(max(regionCenterY - height / 2, 0), 1 - height)
        regionCenterX = x + width / 2
        regionCenterY = y + height / 2
        let preferences = AppGroup.preferences
        preferences?.set(regionEnabled, forKey: AppGroup.regionEnabledKey)
        preferences?.set(x, forKey: AppGroup.regionXKey)
        preferences?.set(y, forKey: AppGroup.regionYKey)
        preferences?.set(width, forKey: AppGroup.regionWidthKey)
        preferences?.set(height, forKey: AppGroup.regionHeightKey)
        preferences?.synchronize()
        lastTextSignature = ""
    }

    var statusText: String { isReceiving ? "Receiving live screen" : "Ready to translate" }

    func startPolling() async {
        guard pollingTask == nil else { return }
        loopbackServer.onFrame = { [weak self] imageData, observationData in
            Task { @MainActor in
                guard let self,
                      let image = UIImage(data: imageData),
                      let observations = try? JSONDecoder().decode([ScreenObservation].self, from: observationData)
                else { return }
                self.optimisticBroadcastUntil = Date().addingTimeInterval(5)
                self.isBroadcasting = true
                if observations.isEmpty {
                    await self.scanImage(image, live: true)
                } else {
                    self.accept(image: image, observations: observations, live: true)
                }
            }
        }
        loopbackServer.start()
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
        loopbackServer.stop()
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
        LoopbackTransport.sendStop()
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
        if observations.isEmpty {
            await scanImage(image, live: true)
        } else {
            accept(image: image, observations: observations, live: true)
        }
    }

    func scanImportedImage(_ image: UIImage) async {
        await scanImage(image, live: false)
    }

    private func scanImage(_ image: UIImage, live: Bool) async {
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
            accept(image: normalizedImage, observations: observations, live: live)
        } catch {
            translations = []
        }
    }

    private func accept(image: UIImage, observations: [ScreenObservation], live: Bool) {
        let observations = deduplicated(observations)
        frameImage = image
        isReceiving = live
        let signature = observations
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "|")
        if live, signature == lastTextSignature { return }
        if live, translations.isEmpty,
           translationConfiguration != nil,
           Date().timeIntervalSince(translationRequestedAt) < 8 {
            return
        }
        lastTextSignature = signature
        pending = observations
        translations = []
        translationGeneration += 1
        if live {
            renderDetectedTextFrame(observations)
        }
        requestTranslation()
    }

    private func deduplicated(_ input: [ScreenObservation]) -> [ScreenObservation] {
        var output: [ScreenObservation] = []
        for item in input.sorted(by: { ($0.width * $0.height) > ($1.width * $1.height) }) {
            let normalized = item.text
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count > 1 else { continue }
            let duplicate = output.contains { existing in
                let other = existing.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalized == other else { return false }
                let a = CGRect(x: item.x, y: item.y, width: item.width, height: item.height)
                let b = CGRect(x: existing.x, y: existing.y, width: existing.width, height: existing.height)
                let intersection = a.intersection(b)
                let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
                return overlap > 0 || hypot(a.midX - b.midX, a.midY - b.midY) < 0.08
            }
            if !duplicate { output.append(item) }
        }
        return output
    }

    private func renderDetectedTextFrame(_ observations: [ScreenObservation]) {
        guard !observations.isEmpty else { return }
        let detected = observations
            .sorted {
                ($0.width * $0.height) > ($1.width * $1.height)
            }
            .prefix(5)
            .sorted { $0.y > $1.y }
            .map(\.text)
            .joined(separator: "\n")

        let cardSize = CGSize(width: 1200, height: 420)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        pictureInPictureFrame = UIGraphicsImageRenderer(size: cardSize, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: cardSize))
            drawFittedText(
                detected,
                in: CGRect(x: 44, y: 52, width: 1112, height: 270),
                color: .white,
                maximumFontSize: 48
            )
            drawFittedText(
                "Translating…",
                in: CGRect(x: 44, y: 340, width: 1112, height: 48),
                color: UIColor(red: 0.42, green: 0.96, blue: 0.83, alpha: 1),
                maximumFontSize: 28
            )
        }
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
            self.translationRequestedAt = Date()
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
        guard !translations.isEmpty else { return }
        let selected = translations
            .sorted {
                ($0.observation.width * $0.observation.height) >
                ($1.observation.width * $1.observation.height)
            }
            .prefix(4)
            .sorted { $0.observation.y > $1.observation.y }

        let translatedText = selected.map(\.translatedText).joined(separator: "\n")
        let cardSize = CGSize(width: 1200, height: 420)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        pictureInPictureFrame = UIGraphicsImageRenderer(size: cardSize, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: cardSize))

            if showOriginalText {
                let originalText = selected.map(\.observation.text).joined(separator: "\n")
                drawFittedText(originalText, in: CGRect(x: 44, y: 28, width: 1112, height: 158), color: .white, maximumFontSize: 42)
                UIColor.white.withAlphaComponent(0.35).setFill()
                context.fill(CGRect(x: 70, y: 205, width: 1060, height: 2))
                drawFittedText(translatedText, in: CGRect(x: 44, y: 230, width: 1112, height: 160), color: UIColor(red: 0.42, green: 0.96, blue: 0.83, alpha: 1), maximumFontSize: 46)
            } else {
                drawFittedText(translatedText, in: CGRect(x: 54, y: 44, width: 1092, height: 332), color: UIColor(red: 0.42, green: 0.96, blue: 0.83, alpha: 1), maximumFontSize: 54)
            }
        }
    }

    private func drawFittedText(
        _ text: String,
        in rect: CGRect,
        color: UIColor,
        maximumFontSize: CGFloat
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        var fontSize = maximumFontSize
        var attributes: [NSAttributedString.Key: Any] = [:]

        while fontSize >= 18 {
            attributes = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
            let measured = NSString(string: text).boundingRect(
                with: rect.size,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
            if measured.width <= rect.width && measured.height <= rect.height { break }
            fontSize -= 1
        }
        NSString(string: text).draw(in: rect, withAttributes: attributes)
    }
}

