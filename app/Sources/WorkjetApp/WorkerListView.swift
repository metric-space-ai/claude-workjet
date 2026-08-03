import SwiftUI
import WorkjetCore

struct WorkerListView: View {
    @EnvironmentObject private var model: WorkjetViewModel
    let onEditWorker: (Worker) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visibleWorkers) { worker in
                    WorkerRow(worker: worker, onEdit: { onEditWorker(worker) })
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
    let onEdit: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(worker.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(worker.model) · \(worker.harness.rawValue)").font(.system(size: 11)).foregroundStyle(WJTheme.secondaryText).lineLimit(1)
                    CapacityIndicator(capacity: worker.capacity, label: worker.name)
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
        HStack(spacing: 4) {
            if let fraction = capacity.fraction {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(color).frame(width: 22 * fraction)
                }.frame(width: 22, height: 4)
            } else {
                Capsule().stroke(WJTheme.secondaryText, lineWidth: 1).frame(width: 22, height: 4)
            }
            Circle().fill(color).frame(width: 5, height: 5)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Kapazität \(label): \(detail)").help(detail)
    }
}
