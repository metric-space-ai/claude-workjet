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

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(onAddComputer: onAddComputer)
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
            .help("Neuen Worker anlegen")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(WJIconButtonStyle())
            .accessibilityLabel("Einstellungen öffnen")
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

    var body: some View {
        HStack(spacing: 10) {
            Text("Workjet")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.computers) { computer in
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
