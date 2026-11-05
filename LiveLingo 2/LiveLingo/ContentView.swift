import PhotosUI
import ReplayKit
import SwiftUI
import Translation

struct ContentView: View {
    @StateObject private var model = LiveTranslationModel()
    @State private var showLanguagePicker = false
    @State private var showBroadcastHelp = false
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 0.93, green: 1.0, blue: 0.77).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header
                    languageCard
                    previewCard
                    actionGrid
                    compatibilityNote
                    Color.clear.frame(height: 82)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }
            bottomBar
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePicker(model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("LiveContainer limitation", isPresented: $showBroadcastHelp) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("LiveContainer cannot register ReplayKit broadcast extensions. Install the IPA directly with AltStore, SideStore, or Sideloadly for live capture. Screenshot translation works inside LiveContainer.")
        }
        .translationTask(model.translationConfiguration) { session in
            await model.translatePending(using: session)
        }
        .task { await model.startPolling() }
        .onDisappear { model.stopPolling() }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await model.scanImportedImage(image)
                }
                selectedPhoto = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.black).frame(width: 50, height: 50)
                Image(systemName: "character.bubble.fill")
                    .font(.title2)
                    .foregroundStyle(Color(red: 0.77, green: 0.98, blue: 0.38))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("LiveLingo").font(.system(size: 25, weight: .bold, design: .rounded))
                Text(model.statusText).font(.caption.weight(.medium)).foregroundStyle(.black.opacity(0.55))
            }
            Spacer()
            Button { showBroadcastHelp = true } label: {
                Image(systemName: "questionmark")
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.76), in: Circle())
            }
            .foregroundStyle(.black)
        }
    }

    private var languageCard: some View {
        Button { showLanguagePicker = true } label: {
            HStack(spacing: 12) {
                languageTile(title: "From", language: model.sourceLanguage.name, color: Color(red: 0.77, green: 0.93, blue: 1.0))
                Image(systemName: "arrow.right")
                    .font(.subheadline.bold())
                    .frame(width: 34, height: 34)
                    .background(.black, in: Circle())
                    .foregroundStyle(.white)
                languageTile(title: "To", language: model.targetLanguage.name, color: Color(red: 1.0, green: 0.89, blue: 0.47))
            }
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
    }

    private func languageTile(title: String, language: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.45))
            Text(language).font(.subheadline.weight(.bold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(color, in: RoundedRectangle(cornerRadius: 19))
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live translation").font(.title3.bold())
                    Text(model.isReceiving ? "Screen feed connected" : "Waiting for a screen or photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(model.isReceiving ? Color.green : Color.orange).frame(width: 10, height: 10)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(Color(red: 0.96, green: 0.97, blue: 0.95))
                if let image = model.frameImage {
                    GeometryReader { proxy in
                        let imageFrame = aspectFitRect(imageSize: image.size, in: proxy.size)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ForEach(model.translations) { item in
                            TranslationOverlay(item: item, imageFrame: imageFrame)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                } else {
                    VStack(spacing: 11) {
                        Image(systemName: "viewfinder").font(.system(size: 44, weight: .light)).foregroundStyle(.black.opacity(0.6))
                        Text("Translations appear here").font(.subheadline.weight(.semibold))
                    }
                }
            }
            .frame(height: 350)
            Toggle("Show original text", isOn: $model.showOriginalText)
                .font(.subheadline.weight(.semibold))
                .tint(Color(red: 0.48, green: 0.78, blue: 0.18))
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 30))
        .shadow(color: .black.opacity(0.06), radius: 20, y: 9)
    }

    private var actionGrid: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                BroadcastPicker()
                    .frame(width: 58, height: 58)
                Text("Start broadcast").font(.subheadline.bold())
                Text("Tap the broadcast icon").font(.system(size: 9, weight: .medium)).foregroundStyle(.black.opacity(0.52))
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(Color(red: 0.55, green: 0.84, blue: 0.31), in: RoundedRectangle(cornerRadius: 24))

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.title2.bold())
                    Text("Translate photo").font(.subheadline.bold())
                }
                .frame(maxWidth: .infinity, minHeight: 104)
                .background(Color(red: 1.0, green: 0.86, blue: 0.88), in: RoundedRectangle(cornerRadius: 24))
                .foregroundStyle(.black)
            }
        }
    }

    private var compatibilityNote: some View {
        Button { showBroadcastHelp = true } label: {
            HStack(spacing: 11) {
                Image(systemName: "info.circle.fill").foregroundStyle(Color(red: 0.32, green: 0.61, blue: 0.11))
                Text("Using LiveContainer? Use Translate photo, or install the IPA directly to enable live broadcasting.")
                    .font(.caption.weight(.medium)).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.bold())
            }
            .padding(15)
            .background(.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 21))
            .foregroundStyle(.black.opacity(0.72))
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack(spacing: 38) {
            bottomItem("house.fill", selected: true)
            bottomItem("clock", selected: false)
            bottomItem("gearshape", selected: false)
        }
        .padding(.horizontal, 26).padding(.vertical, 12)
        .background(.white, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
        .padding(.bottom, 10)
    }

    private func bottomItem(_ icon: String, selected: Bool) -> some View {
        Image(systemName: icon).font(.headline).frame(width: 42, height: 34)
            .background(selected ? Color(red: 1.0, green: 0.88, blue: 0.3) : .clear, in: Capsule())
            .foregroundStyle(.black.opacity(selected ? 1 : 0.45))
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct TranslationOverlay: View {
    let item: TranslatedObservation
    let imageFrame: CGRect

    var body: some View {
        let rect = CGRect(x: imageFrame.minX + item.observation.x * imageFrame.width,
                          y: imageFrame.minY + (1 - item.observation.y - item.observation.height) * imageFrame.height,
                          width: item.observation.width * imageFrame.width,
                          height: max(item.observation.height * imageFrame.height, 22))
        Text(item.displayText)
            .font(.system(size: max(11, min(18, rect.height * 0.58)), weight: .semibold))
            .lineLimit(3).minimumScaleFactor(0.65).padding(.horizontal, 6)
            .frame(width: max(rect.width, 60), height: max(rect.height, 28))
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(.white).position(x: rect.midX, y: rect.midY)
    }
}

private struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.showsMicrophoneButton = false
        picker.tintColor = .black
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
