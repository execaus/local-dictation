import SwiftUI

struct SleepSettingsView: View {
    @ObservedObject var model: SleepModel
    @State private var customMinutes = "45"
    private let days: [(Int, String)] = [(2, "Пн"), (3, "Вт"), (4, "Ср"), (5, "Чт"),
                                         (6, "Пт"), (7, "Сб"), (1, "Вс")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Не засыпать", systemImage: "sun.max.fill")
                        .font(.title2.bold())
                    Text("Удерживать Mac и дисплей активными при бездействии.")
                        .foregroundStyle(.secondary)
                }
                GroupBox("Состояние") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(model.stateText, systemImage: model.reason == .inactive ? "moon.zzz" : "sun.max.fill")
                        if let error = model.error { Text(error).foregroundStyle(.red) }
                        HStack {
                            Button("Включить до выключения") { model.startManual() }
                            Button("Выключить") { model.stop() }.disabled(model.reason == .inactive)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Таймер") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            ForEach([15, 30, 60, 120], id: \.self) { minutes in
                                Button(minutes < 60 ? "\(minutes) мин" : "\(minutes / 60) ч") {
                                    model.startTimer(minutes: minutes)
                                }
                            }
                        }
                        HStack {
                            TextField("Минуты", text: $customMinutes).frame(width: 90)
                            Button("Включить на указанное время") {
                                model.startTimer(minutes: Int(customMinutes) ?? 0)
                            }
                        }
                        Text("Можно задать от 1 минуты до 7 дней.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Повторяющееся расписание") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach($model.rules) { $rule in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Toggle("Активно", isOn: $rule.isEnabled)
                                    Spacer()
                                    Button("Удалить", role: .destructive) {
                                        model.rules.removeAll { $0.id == rule.id }
                                    }
                                }
                                HStack {
                                    ForEach(days, id: \.0) { weekday, title in
                                        Toggle(title, isOn: Binding(
                                            get: { rule.weekdays.contains(weekday) },
                                            set: { selected in
                                                if selected { rule.weekdays.insert(weekday) }
                                                else { rule.weekdays.remove(weekday) }
                                            }
                                        )).toggleStyle(.button)
                                    }
                                }
                                HStack {
                                    Text("С")
                                    timePicker(minute: $rule.startMinute)
                                    Text("до")
                                    timePicker(minute: $rule.endMinute)
                                }
                                if rule.startMinute == rule.endMinute || rule.weekdays.isEmpty {
                                    Text("Выберите день и разные часы начала и конца.")
                                        .font(.caption).foregroundStyle(.orange)
                                } else if rule.endMinute < rule.startMinute {
                                    Text("Окончание — на следующий день.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                        Button("Добавить интервал") {
                            model.rules.append(ScheduleRule(weekdays: [2, 3, 4, 5, 6],
                                                            startMinute: 9 * 60, endMinute: 18 * 60))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Запуск") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Запускать при входе в macOS", isOn: $model.launchAtLogin)
                        Text("Для работы расписания после перезагрузки войдите в свою учётную запись.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Режим влияет только на сон от бездействия. Блокировка, явный сон, закрытая крышка и системные политики действуют как обычно.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(.ultraThinMaterial)
    }

    private func timePicker(minute: Binding<Int>) -> some View {
        let date = Binding<Date>(
            get: {
                Calendar.current.date(bySettingHour: minute.wrappedValue / 60,
                                      minute: minute.wrappedValue % 60, second: 0, of: Date()) ?? Date()
            },
            set: { value in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
                minute.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
        return DatePicker("", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden().frame(width: 95)
    }
}
