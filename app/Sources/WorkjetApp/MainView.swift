import AppKit
import SwiftUI
import WorkjetCore

/// Main popover screen: header (computers), search row, worker list on top,
/// pinned "Aktiv" area at the bottom.
struct MainView: View {
    @EnvironmentObject private var model: WorkjetViewModel
    @State private var activePaneHeight: CGFloat?
    @State private var dragStartActivePaneHeight: CGFloat?

    let onOpenSettings: () -> Void
    let onOpenHealthRecovery: () -> Void
    let onAddWorker: () -> Void
    let onEditWorker: (Worker) -> Void
    let onAddComputer: () -> Void
    let onEditComputer: (Computer) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(onOpenHealthRecovery: onOpenHealthRecovery, onAddComputer: onAddComputer, onEditComputer: onEditComputer)
            WJDivider()
            searchRow
            WJDivider()
            GeometryReader { geometry in
                let layout = splitLayout(totalHeight: geometry.size.height)
                VStack(spacing: 0) {
                    WorkerListView(onEditWorker: onEditWorker)
                        .frame(height: layout.worker)
                    splitHandle(layout: layout)
                    ActiveAreaView()
                        .frame(height: layout.active, alignment: .top)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Worker und aktive Ausführungen")
            .accessibilityIdentifier("main.worker-active-split")
        }
    }

    private var activePaneIdealHeight: CGFloat {
        let count = model.activeRunPresentations.count
        return count == 0 ? 72 : min(300, CGFloat(count) * 70 + 38)
    }

    private struct SplitLayout {
        let worker: CGFloat
        let active: CGFloat
        let minimumActive: CGFloat
        let maximumActive: CGFloat
    }

    private func splitLayout(totalHeight: CGFloat) -> SplitLayout {
        let contentHeight = max(0, totalHeight - 12)
        let minimumActive = min(72, contentHeight * 0.35)
        let minimumWorker = min(170, max(0, contentHeight - minimumActive))
        let maximumActive = max(minimumActive, contentHeight - minimumWorker)
        let requestedActive = activePaneHeight ?? activePaneIdealHeight
        let active = min(max(requestedActive, minimumActive), maximumActive)
        return SplitLayout(
            worker: max(0, contentHeight - active),
            active: active,
            minimumActive: minimumActive,
            maximumActive: maximumActive
        )
    }

    private func splitHandle(layout: SplitLayout) -> some View {
        Button {
            activePaneHeight = nil
        } label: {
            ZStack {
                WJDivider()
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(WJTheme.secondaryText.opacity(0.75))
                    .frame(width: 38, height: 3)
            }
        }
        .buttonStyle(.plain)
        .frame(height: 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartActivePaneHeight == nil {
                        dragStartActivePaneHeight = layout.active
                    }
                    let start = dragStartActivePaneHeight ?? layout.active
                    activePaneHeight = min(
                        max(start - value.translation.height, layout.minimumActive),
                        layout.maximumActive
                    )
                }
                .onEnded { _ in dragStartActivePaneHeight = nil }
        )
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel("Größe von Worker und Aktiv ändern")
        .accessibilityIdentifier("main.worker-active-divider")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = 40
            switch direction {
            case .increment:
                activePaneHeight = min(layout.active + step, layout.maximumActive)
            case .decrement:
                activePaneHeight = max(layout.active - step, layout.minimumActive)
            @unknown default:
                break
            }
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
    let onOpenHealthRecovery: () -> Void
    let onAddComputer: () -> Void
    let onEditComputer: (Computer) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Workjet")
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                RuntimeStatusView(onOpenHealthRecovery: onOpenHealthRecovery)
            }
            .frame(width: 195, alignment: .leading)

            HStack(spacing: 8) {
                if let local = model.computers.first(where: \.isLocal) {
                    computerChoice(local)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.computers.filter { !$0.isLocal }) { computer in
                            computerChoice(computer)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("header.computer-scroll")
                Button(action: onAddComputer) {
                    Image(systemName: "plus")
                }
                .buttonStyle(WJIconButtonStyle())
                .accessibilityLabel("Computer hinzufügen")
                .help("Neuen Computer einrichten (Tailscale oder SSH)")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func computerChoice(_ computer: Computer) -> some View {
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
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct RuntimeStatusView: View {
    @EnvironmentObject private var model: WorkjetViewModel
    let onOpenHealthRecovery: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            activationStatus
            let health = HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if model.runtimeStatus == .attention {
                Button(action: onOpenHealthRecovery) { health }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Problem beheben: \(label)")
                    .accessibilityIdentifier("header.health-recovery")
                    .help("Problem beheben")
            } else {
                health
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(activationLabel). \(accessibilityLabel)")
    }

    @ViewBuilder
    private var activationStatus: some View {
        let content = HStack(spacing: 5) {
            Circle().fill(activationColor).frame(width: 6, height: 6)
            Text(activationLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(activationColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        if model.workjetActivationStatus.state == .ready || model.workjetActivationStatus.state == .checking {
            content.help(activationHelp)
        } else {
            Button {
                Task { await model.installOrRepairWorkjetSkill() }
            } label: { content }
            .buttonStyle(.plain)
            .help("Workjet für Claude Code einrichten oder reparieren")
        }
    }

    private var activationLabel: String {
        switch model.workjetActivationStatus.state {
        case .checking: return "Claude Code · wird geprüft"
        case .ready:
            return model.claudeRestartRequired
                ? "Claude · Neustart erforderlich"
                : "Claude · Workjet aktuell"
        case .missing: return "Claude Code · Workjet einrichten"
        case .outOfDate: return "Claude Code · Workjet aktualisieren"
        case .failed: return "Claude Code · Workjet reparieren"
        }
    }

    private var activationColor: Color {
        switch model.workjetActivationStatus.state {
        case .checking: return WJTheme.secondaryText
        case .ready:
            return model.claudeRestartRequired
                ? Color(nsColor: .systemOrange)
                : WJTheme.accent
        case .missing, .outOfDate, .failed: return Color(nsColor: .systemOrange)
        }
    }

    private var activationHelp: String {
        if model.workjetActivationStatus.state == .ready, model.claudeRestartRequired {
            return "Die Workjet-Änderung ist gespeichert. Laufende Claude-Code- und Claude-Desktop-Sitzungen verwenden noch den vorherigen Prompt. Claude vollständig beenden und neu starten."
        }
        return model.workjetActivationStatus.detail
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
