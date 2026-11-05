import ReplayKit
import SwiftUI
import Translation

struct ContentView: View {
    @StateObject private var model = LiveTranslationModel()
    @State private var showLanguagePicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.035, green: 0.045, blue: 0.075).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        languageBar
                        liveCanvas
                        controls
                        helpCard
                    }
                    .padding()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showLanguagePicker) {
                LanguagePicker(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .translationTask(model.translationConfiguration) { session in
                await model.translatePending(using: session)
            }
            .task { await model.startPolling() }
            .onDisappear { model.stopPolling() }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("LiveLingo")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(model.statusText)
                    .font(.subheadline)
                    .foregroundStyle(model.isReceiving ? .green : .secondary)
            }
            Spacer()
            Circle()
                .fill(model.isReceiving ? Color.green : Color.white.opacity(0.12))
                .frame(width: 12, height: 12)
                .shadow(color: model.isReceiving ? .green : .clear, radius: 8)
        }
    }

    private var languageBar: some View {
        Button { showLanguagePicker = true } label: {
            HStack(spacing: 14) {
                Label(model.sourceLanguage.name, systemImage: "character.bubble")
                Spacer()
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Spacer()
                Label(model.targetLanguage.name, systemImage: "text.bubble.fill")
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .padding(16)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private var liveCanvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26)
                .fill(.black)

            if let image = model.frameImage {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    ForEach(model.translations) { item in
                        TranslationOverlay(item: item, canvasSize: proxy.size)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 26))
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 48))
                        .foregroundStyle(.indigo)
                    Text("Your shared screen appears here")
                        .font(.headline)
                    Text("Start Broadcast, then choose LiveLingo.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 430)
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            BroadcastPicker()
                .frame(height: 56)
                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .leading) {
                    Label("Start Screen Broadcast", systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline)
                        .padding(.leading, 22)
                        .allowsHitTesting(false)
                }

            Toggle(isOn: $model.showOriginalText) {
                Label("Show original text", systemImage: "text.viewfinder")
            }
            .padding(16)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var helpCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill").foregroundStyle(.indigo)
            Text("Keep LiveLingo visible to see translated overlays. iOS does not allow third-party apps to place controls over other apps.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TranslationOverlay: View {
    let item: TranslatedObservation
    let canvasSize: CGSize

    var body: some View {
        let rect = CGRect(
            x: item.observation.x * canvasSize.width,
            y: (1 - item.observation.y - item.observation.height) * canvasSize.height,
            width: item.observation.width * canvasSize.width,
            height: max(item.observation.height * canvasSize.height, 26)
        )

        Text(item.displayText)
            .font(.system(size: max(11, min(18, rect.height * 0.58)), weight: .semibold))
            .lineLimit(3)
            .minimumScaleFactor(0.65)
            .padding(.horizontal, 6)
            .frame(width: max(rect.width, 60), height: max(rect.height, 28))
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.white)
            .position(x: rect.midX, y: rect.midY)
    }
}

private struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView()
        picker.preferredExtension = "com.example.LiveLingo.BroadcastUpload"
        picker.showsMicrophoneButton = false
        picker.tintColor = .clear
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

