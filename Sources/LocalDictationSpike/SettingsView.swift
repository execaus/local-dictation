import SwiftUI

private enum SettingsSection: Hashable {
    case microphone, keyboard, dictionary
}

struct SettingsView: View {
    @State private var section: SettingsSection = .microphone
    @ObservedObject var microphoneStore: MicrophoneStore
    @ObservedObject var dictionaryStore: DictionaryStore
    let trigger: DictationTrigger
    let applyTrigger: (DictationTrigger) -> String?

    var body: some View {
        TabView(selection: $section) {
            MicrophoneSettingsView(store: microphoneStore)
                .tabItem { Label("Микрофон", systemImage: "mic.fill") }
                .tag(SettingsSection.microphone)
            TriggerSettingsView(trigger: trigger, apply: applyTrigger)
                .tabItem { Label("Клавиши", systemImage: "keyboard") }
                .tag(SettingsSection.keyboard)
            DictionaryView(store: dictionaryStore)
                .tabItem { Label("Словарь", systemImage: "text.book.closed") }
                .tag(SettingsSection.dictionary)
        }
        .frame(width: 720, height: 490)
    }
}

private struct MicrophoneSettingsView: View {
    @ObservedObject var store: MicrophoneStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Источник записи", systemImage: "mic.fill")
                    .font(.title2.bold())
                Text("Выберите микрофон для диктовки. Настройка действует только в этом приложении.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Picker("Микрофон", selection: $store.selectedUID) {
                    Text("Системный микрофон").tag(nil as String?)
                    ForEach(store.devices) { device in
                        Text(device.name).tag(device.id as String?)
                    }
                }
                .frame(maxWidth: .infinity)
                Button("Обновить список") { store.refresh() }
                    .buttonStyle(.bordered)
            }
            .padding(16)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))

            if store.selectedDeviceMissing {
                Label("Выбранный микрофон сейчас не подключён. Подключите его или выберите другой.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Text("Если запись почти беззвучна, проверьте доступ к микрофону и уровень входа в Системных настройках macOS. Изменения источника применяются к следующей записи.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }
}
