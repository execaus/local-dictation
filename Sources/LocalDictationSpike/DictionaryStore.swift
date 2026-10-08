import Combine
import Foundation
import SwiftUI

struct DictionaryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var spoken: String
    var written: String
}

@MainActor final class DictionaryStore: ObservableObject {
    @Published var entries: [DictionaryEntry] {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "dictionary.v1"),
           let saved = try? JSONDecoder().decode([DictionaryEntry].self, from: data) {
            entries = saved
        } else {
            entries = [
                DictionaryEntry(spoken: "постгрес", written: "PostgreSQL"),
                DictionaryEntry(spoken: "юз эффект", written: "useEffect"),
            ]
        }
    }

    var rules: [TermRule] {
        entries.compactMap { entry in
            let spoken = entry.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let written = entry.written.trimmingCharacters(in: .whitespacesAndNewlines)
            return spoken.isEmpty || written.isEmpty ? nil : TermRule(spoken: spoken, written: written)
        }
    }

    func add() { entries.append(DictionaryEntry(spoken: "", written: "")) }
    func remove(id: UUID) { entries.removeAll { $0.id == id } }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: "dictionary.v1")
    }
}

struct DictionaryView: View {
    @ObservedObject var store: DictionaryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Словарь терминов", systemImage: "text.book.closed.fill")
                    .font(.title2.bold())
                Text("Как модель услышала слово → как его вставить в текст")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Распознанный вариант").frame(maxWidth: .infinity, alignment: .leading)
                Text("Правильное написание").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 24)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($store.entries) { $entry in
                        HStack(spacing: 10) {
                            TextField("например: постгрес", text: $entry.spoken)
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                            TextField("PostgreSQL", text: $entry.written)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                store.remove(id: entry.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Удалить запись")
                        }
                    }
                }
            }
            Button {
                store.add()
            } label: {
                Label("Добавить термин", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Text("Словарь хранится только на этом Mac. Замены применяются после распознавания.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 360)
        .background(.ultraThinMaterial)
    }
}
