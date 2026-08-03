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
                    if worker.id != model.visibleWorkers.last?.id {
                        WJDivider().padding(.leading, 14)
                    }
                }
                if model.visibleWorkers.isEmpty {
                    Text("Keine Worker gefunden")
                        .font(.system(size: 12))
                        .foregroundStyle(WJTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .accessibilityLabel("Keine Worker gefunden")
                }
            }
        }
    }
}

/// Compact worker row, 60 pt total height: name, edit pencil, model/harness
/// metadata and tiny quota/rate indicators — no empty vertical bands.
struct WorkerRow: View {
    let worker: Worker
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(worker.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(worker.model) · \(worker.harness.rawValue)")
                        .font(.system(size: 11))
                        .foregroundStyle(WJTheme.secondaryText)
                        .lineLimit(1)
                    QuotaIndicator(quota: worker.quota, workerName: worker.name)
                }
            }
            Spacer(minLength: 8)
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(WJIconButtonStyle())
            .accessibilityLabel("\(worker.name) bearbeiten")
            .help("Worker bearbeiten")
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .accessibilityElement(children: .contain)
    }
}

/// Tiny quota bar + rate dot beside the model/harness metadata. Exact quota
/// details belong in Settings; here only glanceable state with an accessible
/// label and tooltip.
struct QuotaIndicator: View {
    let quota: QuotaStatus
    var workerName: String = ""

    private var barColor: Color {
        switch quota.level {
        case .ok: return WJTheme.quotaOK
        case .warning: return WJTheme.quotaWarning
        case .critical: return WJTheme.quotaCritical
        }
    }

    private var percentText: String {
        "\(Int((quota.usedPercent * 100).rounded())) Prozent"
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(barColor)
                    .frame(width: 22 * quota.usedPercent)
            }
            .frame(width: 22, height: 4)
            Circle()
                .fill(quota.rateLimited ? WJTheme.quotaCritical : WJTheme.quotaOK)
                .frame(width: 5, height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Quota \(workerName): \(percentText) belegt, \(quota.rateLimited ? "Rate-Limit aktiv" : "kein Rate-Limit")"
        )
        .help("Quota: \(percentText) belegt · \(quota.rateLimited ? "Rate-Limit aktiv" : "Rate ok") — Details in den Einstellungen")
    }
}
