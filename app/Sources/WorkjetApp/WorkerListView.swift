import SwiftUI
import WorkjetCore

struct WorkerListView: View {
    @EnvironmentObject private var model: WorkjetViewModel
    let onEditWorker: (Worker) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visibleWorkers) { worker in
                    WorkerRow(worker: worker, capacity: model.effectiveCapacity(for: worker), onEdit: { onEditWorker(worker) })
                    if worker.id != model.visibleWorkers.last?.id { WJDivider().padding(.leading, 14) }
                }
                if model.visibleWorkers.isEmpty {
                    Text("Keine Worker gefunden").font(.system(size: 12)).foregroundStyle(WJTheme.secondaryText)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
        }
    }
}

struct WorkerRow: View {
    let worker: Worker
    let capacity: CapacityStatus
    let onEdit: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(worker.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(worker.model) · \(worker.harness.rawValue)").font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText).lineLimit(1)
                    CapacityIndicator(capacity: capacity, label: worker.name)
                }
            }
            Spacer(minLength: 8)
            Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(WJIconButtonStyle())
                .accessibilityLabel("\(worker.name) bearbeiten").help("Worker bearbeiten")
        }
        .padding(.horizontal, 14).frame(height: 60).accessibilityElement(children: .contain)
    }
}

struct CapacityIndicator: View {
    let capacity: CapacityStatus
    var label = ""
    private var color: Color {
        switch capacity.level {
        case .ok: WJTheme.quotaOK
        case .warning: WJTheme.quotaWarning
        case .critical: WJTheme.quotaCritical
        case .unavailable: WJTheme.secondaryText
        }
    }
    private var detail: String {
        guard let fraction = capacity.fraction else { return capacity.reason ?? "Kapazität nicht verfügbar" }
        return "\(Int((fraction * 100).rounded())) Prozent belegt" + (capacity.rateLimited == true ? ", Rate-Limit aktiv" : "")
    }
    var body: some View {
        HStack(spacing: 3) {
            compactSignal(prefix: "Q", value: quotaValue, color: color)
            compactSignal(prefix: "R", value: rateValue, color: rateColor)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Kapazität \(label): \(detail)").help(detail)
    }

    private var quotaValue: String {
        guard let fraction = capacity.fraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private var rateValue: String {
        guard let limited = capacity.rateLimited else { return "—" }
        return limited ? "Limit" : "frei"
    }

    private var rateColor: Color {
        guard let limited = capacity.rateLimited else { return WJTheme.secondaryText }
        return limited ? WJTheme.quotaCritical : WJTheme.quotaOK
    }

    private func compactSignal(prefix: String, value: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(prefix).font(.system(size: 7, weight: .bold))
            Text(value).font(.system(size: 8, design: .monospaced))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}
