import AppKit
import SwiftUI

@MainActor final class StatusPanel {
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 266, height: 76),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func showRecording() {
        show(StatusPill(mode: .recording(Date())))
    }

    func showProcessing() {
        show(StatusPill(mode: .processing))
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func show(_ view: StatusPill) {
        panel.contentView = NSHostingView(rootView: view)
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 133, y: frame.minY + 28))
        }
        panel.orderFrontRegardless()
    }
}

private struct StatusPill: View {
    enum Mode { case recording(Date), processing }
    let mode: Mode

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 38, height: 38)
                .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                switch mode {
                case .recording(let startedAt):
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(elapsed(since: startedAt, at: context.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                case .processing:
                    Text("Всё происходит на этом Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: 260, height: 68)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.48), .white.opacity(0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .padding(3)
    }

    private var icon: String {
        switch mode {
        case .recording: "record.circle.fill"
        case .processing: "waveform"
        }
    }

    private var iconColor: Color {
        switch mode {
        case .recording: .red
        case .processing: .accentColor
        }
    }

    private var title: String {
        switch mode {
        case .recording: "Запись речи"
        case .processing: "Распознавание…"
        }
    }

    private func elapsed(since start: Date, at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
