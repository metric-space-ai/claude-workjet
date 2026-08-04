import AppKit
import Combine
import SwiftUI
import WorkjetCore

@main
struct WorkjetMenuBarApp: App {
    @NSApplicationDelegateAdaptor(WorkjetAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Workjet owns its status item and popover through AppKit. A SwiftUI
        // MenuBarExtra is intentionally not used: it cannot be targeted or
        // diagnosed reliably when several neighbouring status items are active.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class WorkjetAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model: WorkjetViewModel
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var modelChanges: AnyCancellable?
    private var uiTestWindow: NSWindow?

    override init() {
        let environment = ProcessInfo.processInfo.environment
        if let testHome = environment["WORKJET_UI_TEST_HOME"], !testHome.isEmpty {
            let paths = WorkjetPaths(homeDirectory: URL(fileURLWithPath: testHome, isDirectory: true))
            if environment["WORKJET_UI_TEST_SEED"] == "1",
               !FileManager.default.fileExists(atPath: paths.configurationFile.path) {
                Self.seedUITestConfiguration(at: paths.configurationFile)
            }
            model = WorkjetViewModel.live(paths: paths)
        } else if environment["WORKJET_PREVIEW"] == "1" {
            model = WorkjetViewModel(configuration: WorkjetDefaults.configuration())
        } else {
            model = WorkjetViewModel.live()
        }
        super.init()
    }

    /// Seeds only the isolated home supplied by the UI-test process. The
    /// production home and Keychain are never read or written by this fixture.
    private static func seedUITestConfiguration(at fileURL: URL) {
        var configuration = WorkjetDefaults.configuration()
        let providerID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        configuration.providers = [
            Provider(
                id: providerID,
                name: "UI Test OpenAI",
                kind: .directAPI,
                endpoint: "https://example.invalid/v1",
                authentication: .none,
                modelProvider: .openAI,
                accountLabel: "michael@gmail.com",
                modelIDs: ["gpt-5.6-sol"],
                status: .connected,
                statusDetail: "Deterministische UI-Test-Fixture."
            )
        ]
        if let completionIndex = configuration.workers.firstIndex(where: { $0.name == "Completion Engine" }) {
            configuration.workers[completionIndex].providerRoute = .account(providerID)
            configuration.workers[completionIndex].reasoningEffort = .high
        }
        try? JSONConfigurationStore(fileURL: fileURL).save(configuration)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startPolling()

        if ProcessInfo.processInfo.environment["WORKJET_UI_TEST_WINDOW"] == "1" {
            showUITestWindow()
            return
        }

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
        button.sendAction(on: [.leftMouseUp])
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
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

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

    private func menuBarImage(for status: WorkjetRuntimeStatus) -> NSImage? {
        let badgeColor: Color? = switch status {
        case .ready: nil
        case .active: Color(nsColor: .systemBlue)
        case .attention: Color(nsColor: .systemOrange)
        }
        let renderer = ImageRenderer(
            content: ZStack(alignment: .topTrailing) {
                WorkjetMark()
                    .fill(Color(nsColor: .labelColor), style: FillStyle(eoFill: true))
                    .frame(width: 18, height: 18)
                if let badgeColor {
                    Circle()
                        .fill(badgeColor)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                        .frame(width: 7, height: 7)
                        .offset(x: 1, y: -1)
                }
            }
            .frame(width: 20, height: 18)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        // A template image would discard the orange/blue status badge.
        image?.isTemplate = badgeColor == nil
        image?.size = NSSize(width: 20, height: 18)
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
