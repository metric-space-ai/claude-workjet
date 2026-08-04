import SwiftUI
import WorkjetCore

/// Main popover screen: header (computers), search row, worker list on top,
/// pinned "Aktiv" area at the bottom.
struct MainView: View {
    @EnvironmentObject private var model: WorkjetViewModel

    let onOpenSettings: () -> Void
    let onAddWorker: () -> Void
    let onEditWorker: (Worker) -> Void
    let onAddComputer: () -> Void
    let onEditComputer: (Computer) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(onAddComputer: onAddComputer, onEditComputer: onEditComputer)
            WJDivider()
            searchRow
            WJDivider()
            WorkerListView(onEditWorker: onEditWorker)
                .frame(maxHeight: .infinity)
            WJDivider()
            ActiveAreaView()
        }
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            TextField("Worker suchen …", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(WJTheme.surface)
                )
                .accessibilityLabel("Worker suchen")
            Button(action: onAddWorker) {
                Image(systemName: "plus")
            }
            .buttonStyle(WJIconButtonStyle())
            .accessibilityLabel("Worker hinzufügen")
            .accessibilityIdentifier("main.add-worker")
            .help("Neuen Worker anlegen")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(WJIconButtonStyle())
            .accessibilityLabel("Einstellungen öffnen")
            .accessibilityIdentifier("main.open-settings")
            .help("Einstellungen")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Header: "Workjet" title, then directly clickable independent computer
/// buttons with visible gaps (Local always present), plus a separate `+`
/// button at the end. No dropdown, no segmented-control shell; horizontal
/// scrolling without an overflow arrow.
struct HeaderView: View {
    @EnvironmentObject private var model: WorkjetViewModel
    let onAddComputer: () -> Void
    let onEditComputer: (Computer) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Workjet")
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                RuntimeStatusView()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.computers) { computer in
                        HStack(spacing: 4) {
                            WJChoiceButton(
                                title: computer.name,
                                isSelected: model.selectedComputerID == computer.id,
                                accessibilityLabel: "Computer \(computer.name)",
                                help: computer.isLocal
                                    ? "Lokaler Rechner"
                                    : "\(computer.transport.rawValue): \(computer.host)"
                            ) {
                                model.toggleComputerSelection(computer.id)
                            }
                            if !computer.isLocal && model.selectedComputerID == computer.id {
                                Button { onEditComputer(computer) } label: { Image(systemName: "pencil") }
                                    .buttonStyle(WJIconButtonStyle())
                                    .accessibilityLabel("Computer \(computer.name) bearbeiten")
                            }
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            Button(action: onAddComputer) {
                Image(systemName: "plus")
            }
            .buttonStyle(WJIconButtonStyle())
            .accessibilityLabel("Computer hinzufügen")
            .help("Neuen Computer einrichten (Tailscale oder SSH)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct RuntimeStatusView: View {
    @EnvironmentObject private var model: WorkjetViewModel

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        model.runtimeSubtitle
    }

    private var color: Color {
        switch model.runtimeStatus {
        case .ready: return WJTheme.secondaryText
        case .active: return WJTheme.accent
        case .attention: return Color(nsColor: .systemOrange)
        }
    }

    private var accessibilityLabel: String {
        model.runtimeSubtitle
    }
}
