import SwiftUI
import WorkjetCore

struct ActiveAreaView: View {
    @EnvironmentObject private var model: WorkjetViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WJSectionHeader(title: "Aktiv")
            if model.activeRuns.isEmpty {
                Text("Keine laufenden Worker").font(.system(size: 12)).foregroundStyle(WJTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.activeRuns) { run in
                            ActiveRunRow(run: run, onStop: { model.stopRun(id: run.id) })
                            if run.id != model.activeRuns.last?.id { WJDivider() }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(height: 168).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActiveRunRow: View {
    let run: ActiveRun
    let onStop: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(run.workerName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(DurationFormatter.string(for: context.date.timeIntervalSince(run.startedAt)))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(WJTheme.secondaryText)
                    }
                }
                Text(run.activity).font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText).lineLimit(1)
                Text("Run \(run.sourceRunID) · \(run.delivery.rawValue)" + heartbeatText)
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(WJTheme.tertiaryText).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onStop) { Image(systemName: "stop.fill") }.buttonStyle(WJIconButtonStyle(tint: Color(nsColor: .systemRed)))
                .accessibilityLabel("\(run.workerName) stoppen").help("Exakt verifizierten Run-PID mit TERM stoppen")
        }.padding(.vertical, 6)
    }
    private var heartbeatText: String {
        guard let heartbeat = run.lastHeartbeat else { return " · Heartbeat unbekannt" }
        return " · Heartbeat \(heartbeat.formatted(date: .omitted, time: .standard))"
    }
}
