import AppKit
import Combine
import SwiftUI
import WorkjetCore

@main
struct WorkjetMenuBarApp: App {
    @NSApplicationDelegateAdaptor(WorkjetAppDelegate.self) private var appDelegate

    var body: some Scene {
        // The AppKit delegate owns the one menu-bar item and its popover.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class WorkjetAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model: WorkjetViewModel
    #if DEBUG
    private let uiTestMode: Bool
    #endif
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var modelChanges: AnyCancellable?
    #if DEBUG
    private var uiTestWindow: NSWindow?
    #endif

    override init() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let testHome = environment["WORKJET_UI_TEST_HOME"] ?? ""
        uiTestMode = environment["WORKJET_UI_TEST_WINDOW"] == "1"
            && environment["WORKJET_UI_TEST_SEED"] == "1"
            && testHome.hasPrefix("/")
            && !testHome.contains("\0")
        if uiTestMode {
            let paths = WorkjetPaths(homeDirectory: URL(fileURLWithPath: testHome, isDirectory: true))
            if !FileManager.default.fileExists(atPath: paths.configurationFile.path) {
                Self.seedUITestConfiguration(at: paths.configurationFile)
            }
            let bootstrap = WorkjetBootstrap.live(
                paths: paths,
                harnessLifecycle: HarnessLifecycleCoordinator(remoteClient: { _ in
                    WorkjetUITestRemoteHostClient()
                })
            )
            model = WorkjetViewModel(
                configuration: bootstrap.configuration,
                service: bootstrap.service,
                messages: bootstrap.messages,
                telemetryMaintenance: RunTelemetryStore(paths: paths)
            )
        } else {
            #if DEBUG
            if environment["WORKJET_PREVIEW"] == "1" {
                model = WorkjetViewModel(configuration: WorkjetDefaults.configuration())
            } else {
                model = WorkjetViewModel.live()
            }
            #endif
        }
        #else
        model = WorkjetViewModel.live()
        #endif
        super.init()
    }

    #if DEBUG
    /// Seeds only the isolated home supplied by the UI-test process. The
    /// production home and Keychain are never read or written by this fixture.
    private static func seedUITestConfiguration(at fileURL: URL) {
        var configuration = WorkjetDefaults.configuration()
        let providerID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let readyComputerID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let failedComputerID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        configuration.computers = [
            WorkjetDefaults.localComputer,
            Computer(
                id: readyComputerID,
                name: "Remote Ready",
                transport: .ssh,
                host: "ready.example.invalid",
                user: "workjet-ui-test",
                deploymentStatus: .installed,
                deploymentDetail: "Deterministische installierte UI-Test-Fixture.",
                installedContentHash: "ui-test-content-hash",
                installedSidecarVersion: PiSidecarRuntime.version
            ),
            Computer(
                id: failedComputerID,
                name: "Remote Offline",
                transport: .tailscale,
                host: "offline.example.invalid",
                user: "workjet-ui-test",
                deploymentStatus: .failed,
                deploymentDetail: "Deterministische nicht erreichbare UI-Test-Fixture."
            )
        ]
        configuration.providers = [
            Provider(
                id: providerID,
                name: "UI Test OpenAI",
                kind: .directAPI,
                endpoint: "https://example.invalid/v1",
                authentication: .none,
                modelProvider: .openAI,
                accountLabel: "ui-test@example.invalid",
                modelIDs: ["gpt-5.6-sol"],
                status: .connected,
                statusDetail: "Deterministische UI-Test-Fixture."
            )
        ]
        if let completionIndex = configuration.workers.firstIndex(where: { $0.name == "Sol · Completion" }) {
            configuration.workers[completionIndex].providerRoute = .pool(.openAI)
            configuration.workers[completionIndex].reasoningEffort = .high
        }
        if let uiWorkerIndex = configuration.workers.firstIndex(where: { $0.name == "Kimi · UI/UX" }) {
            configuration.workers[uiWorkerIndex].computerID = readyComputerID
        }
        try? JSONConfigurationStore(fileURL: fileURL).save(configuration)
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if uiTestMode {
            showUITestWindow()
            return
        }
        #endif

        model.startPolling()

        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: WJTheme.popoverWidth, height: WJTheme.popoverHeight)
        popover.contentViewController = NSHostingController(rootView: RootView().environmentObject(model))
        popover.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = menuBarImage(for: model.runtimeStatus)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("Workjet öffnen")

        modelChanges = model.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                // objectWillChange is emitted before the new published value is
                // installed. Updating on the next main-actor turn reads the new state.
                await Task.yield()
                self?.updateStatusAppearance()
            }
        }
        updateStatusAppearance()

        // Explicit diagnostics only. Normal launches remain silent.
        if ProcessInfo.processInfo.environment["WORKJET_OPEN_POPOVER"] == "1" {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.showPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopPolling()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(for: sender)
            return
        }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        showPopover()
    }

    private func showContextMenu(for button: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let menu = NSMenu()
        let status = NSMenuItem(title: "Status: \(model.runtimeSubtitle)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(contextMenuItem(title: "Workjet öffnen", action: #selector(openFromContextMenu)))
        menu.addItem(contextMenuItem(title: "Einstellungen …", action: #selector(openSettingsFromContextMenu), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(contextMenuItem(title: "Workjet beenden", action: #selector(quitFromContextMenu), keyEquivalent: "q"))
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    private func contextMenuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func openFromContextMenu() {
        showPopover()
    }

    @objc private func openSettingsFromContextMenu() {
        showPopover()
        Task { @MainActor in
            await Task.yield()
            NotificationCenter.default.post(name: .workjetOpenSettings, object: nil)
        }
    }

    @objc private func quitFromContextMenu() {
        NSApp.terminate(nil)
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    #if DEBUG
    /// Presents the production RootView in a normal window for deterministic
    /// UI automation. It is enabled only by an explicit test environment flag;
    /// normal menu-bar launches never create a window or alter activation mode.
    private func showUITestWindow() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WJTheme.popoverWidth, height: 900),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Workjet UI Test"
        window.identifier = NSUserInterfaceItemIdentifier("workjet.ui-test-window")
        window.level = .floating
        window.contentViewController = NSHostingController(rootView: RootView(viewportHeight: 900).environmentObject(model))
        let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        if let visibleFrame = primaryScreen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visibleFrame.minX + 40, y: visibleFrame.maxY - window.frame.height - 40))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        uiTestWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
    #endif

    private func menuBarImage(for status: WorkjetRuntimeStatus) -> NSImage? {
        let markColor: Color = switch status {
        case .ready: Color(nsColor: .labelColor)
        case .active: Color(nsColor: .systemBlue)
        case .attention: Color(nsColor: .systemOrange)
        }
        let renderer = ImageRenderer(
            content: WorkjetMark()
                .fill(markColor, style: FillStyle(eoFill: true))
                .frame(width: 18, height: 18)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = status == .ready
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    private func updateStatusAppearance() {
        guard let button = statusItem?.button else { return }
        button.toolTip = model.runtimeSubtitle
        button.image = menuBarImage(for: model.runtimeStatus)
        button.contentTintColor = nil
        button.setAccessibilityTitle(accessibilityTitle)
    }

    private var accessibilityTitle: String {
        switch model.runtimeStatus {
        case .ready:
            "Workjet bereit. Öffnen"
        case let .active(count):
            "Workjet aktiv, \(count) laufende Worker. Öffnen"
        case .attention:
            "Workjet benötigt Aufmerksamkeit. Öffnen"
        }
    }
}

#if DEBUG
/// Deterministic remote lifecycle service for the isolated XCUITest home.
/// The production view and persistence stack stay unchanged; only the network
/// boundary is replaced so a click journey never contacts a real computer.
private struct WorkjetUITestRemoteHostClient: RemoteHostCalling {
    func call(_ request: RemoteHostRequest) async throws -> RemoteHostResponse {
        if request.operation == .probe {
            return RemoteHostResponse(
                ok: true,
                hostVersion: "ui-test",
                capabilities: ["harness-lifecycle-v2"]
            )
        }
        guard let harnessID = request.harnessID,
              let action = request.operation.harnessAction else {
            throw RemoteHostProtocolError.rejected("Die UI-Test-Fixture unterstützt nur Harness-Lifecycle-Anfragen.")
        }
        return RemoteHostResponse(
            ok: true,
            hostVersion: "ui-test",
            harnessResult: RemoteHarnessLifecycleResult(
                harnessID: harnessID,
                action: action,
                state: .installed,
                version: "ui-test"
            )
        )
    }
}
#endif
