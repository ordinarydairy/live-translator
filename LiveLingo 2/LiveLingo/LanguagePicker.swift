import SwiftUI

struct LanguagePicker: View {
    @ObservedObject var model: LiveTranslationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Translate from") {
                    Picker("Source", selection: $model.sourceLanguage) {
                        ForEach(LanguageChoice.choices) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                Section("Translate to") {
                    Picker("Target", selection: $model.targetLanguage) {
                        ForEach(LanguageChoice.choices.filter { !$0.code.isEmpty }) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Languages")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

