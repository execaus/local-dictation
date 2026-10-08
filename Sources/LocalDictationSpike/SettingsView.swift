import SwiftUI

private enum SettingsSection: Hashable {
    case general, microphone, keyboard, dictionary
}

struct SettingsView: View {
    @State private var section: SettingsSection = .general
    @ObservedObject var microphoneStore: MicrophoneStore
    @ObservedObject var dictionaryStore: DictionaryStore
    let trigger: DictationTrigger
    let applyTrigger: (DictationTrigger) -> String?
    let checkForUpdates: () -> Void
    let requestAccessibility: () -> Void

    var body: some View {
        TabView(selection: $section) {
            GeneralSettingsView(checkForUpdates: checkForUpdates,
                                requestAccessibility: requestAccessibility)
                .tabItem { Label("Общие", systemImage: "gearshape.fill") }
                .tag(SettingsSection.general)
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

private struct GeneralSettingsView: View {
    let checkForUpdates: () -> Void
    let requestAccessibility: () -> Void

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Сборка разработчика"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Локальная диктовка", systemImage: "waveform")
                    .font(.title2.bold())
                Text("Версия \(version)")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                Label("Обновления", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Text("Проверка GitHub запускается только по нажатию кнопки. Диктовка остаётся локальной.")
                    .foregroundStyle(.secondary)
                Button("Проверить и установить обновление…", action: checkForUpdates)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 16) {
                Label("Универсальный доступ", systemImage: "hand.raised")
                    .font(.headline)
                Text("Нужен для запуска правой Option и вставки текста в другие приложения.")
                    .foregroundStyle(.secondary)
                Button("Разрешить Универсальный доступ…", action: requestAccessibility)
                    .buttonStyle(.bordered)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
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
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.16)))

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
        .background(.ultraThinMaterial)
    }
}
