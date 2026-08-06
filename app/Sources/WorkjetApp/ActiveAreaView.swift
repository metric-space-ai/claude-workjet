import SwiftUI
import WorkjetCore

struct ActiveAreaView: View {
    @EnvironmentObject private var model: WorkjetViewModel
    @State private var pendingStop: ActiveRunPresentation?
    var body: some View {
        let runs = model.activeRunPresentations
        Group {
            if runs.isEmpty {
                HStack {
                    WJSectionHeader(title: "Aktiv")
                    Spacer()
                    Text("Keine laufenden Worker")
                        .font(.system(size: 11))
                        .foregroundStyle(WJTheme.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    WJSectionHeader(title: "Aktiv")
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(runs) { run in
                                ActiveRunRow(
                                    run: run,
                                    onStop: { pendingStop = run },
                                    onRecover: run.recoveryComputerID.map { computerID in
                                        { NotificationCenter.default.post(name: Notification.Name("workjet.open-computer-recovery"), object: computerID) }
                                    }
                                )
                                if run.id != runs.last?.id { WJDivider() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: runs.count)
        .confirmationDialog(
            "Worker stoppen?",
            isPresented: Binding(
                get: { pendingStop != nil },
                set: { if !$0 { pendingStop = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingStop
        ) { run in
            Button("\(run.workerName) stoppen", role: .destructive) {
                stop(run)
                pendingStop = nil
            }
            Button("Abbrechen", role: .cancel) { pendingStop = nil }
        } message: { run in
            Text("Die laufende Ausführung von „\(run.workerName)“ wird beendet.")
        }
    }

    private func stop(_ run: ActiveRunPresentation) {
        switch run.origin {
        case let .local(runID):
            model.stopRun(id: runID)
        case let .remote(workerID):
            Task { await model.stopRemoteWorker(id: workerID) }
        }
    }
}

struct ActiveRunRow: View {
    let run: ActiveRunPresentation
    let onStop: () -> Void
    let onRecover: (() -> Void)?
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(run.workerName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let startedAt = run.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(DurationFormatter.string(for: context.date.timeIntervalSince(startedAt)))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(WJTheme.secondaryText)
                        }
                    } else {
                        Text("—").font(.system(size: 11, design: .monospaced)).foregroundStyle(WJTheme.secondaryText)
                    }
                }
                Text(metadataLine).font(.system(size: 10)).foregroundStyle(WJTheme.secondaryText).lineLimit(1)
                Text(statusLine).font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let onRecover {
                Button("Computer öffnen", action: onRecover)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("active.recover.\(run.id)")
            }
            Button(action: onStop) { Image(systemName: "stop.fill") }.buttonStyle(WJIconButtonStyle(tint: Color(nsColor: .systemRed)))
                .accessibilityLabel("\(run.workerName) stoppen").help("Worker stoppen")
                .accessibilityIdentifier("active.stop.\(run.id)")
        }
        .padding(.vertical, 6)
    }

    private var statusLine: String {
        "\(run.computerName) · \(run.state) · \(run.activity)"
    }

    private var metadataLine: String {
        var facts: [String] = []
        if let model = run.model { facts.append(model) }
        if let reasoning = run.reasoning { facts.append("Reasoning \(reasoning.rawValue)") }
        if let speed = run.speed { facts.append(speed == .fast ? "Tempo schnell" : "Tempo normal") }
        if let route = run.providerRoute { facts.append(route) }

        let missingCount = 4 - facts.count
        guard !facts.isEmpty else { return "Laufzeitdetails nicht erfasst" }
        if missingCount > 0 { facts.append("weitere Details nicht erfasst") }
        return facts.joined(separator: " · ")
    }
}
