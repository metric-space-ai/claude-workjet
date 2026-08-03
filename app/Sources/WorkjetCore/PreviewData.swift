import Foundation

/// Realistic preview data matching the Workjet role model.
public enum PreviewData {
    public static let localComputer = Computer(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Local",
        transport: .local
    )

    public static let devbox = Computer(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "devbox",
        transport: .tailscale,
        host: "devbox.tailnet-7f3a.ts.net",
        user: "mw",
        port: 22,
        sandboxEnabled: true,
        pinnedSidecarVersion: "0.4.2",
        telemetryEnabled: true
    )

    public static let builder = Computer(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "builder-2",
        transport: .ssh,
        host: "192.168.1.42",
        user: "workjet",
        port: 22,
        sandboxEnabled: true,
        pinnedSidecarVersion: "0.4.2",
        telemetryEnabled: false
    )

    public static var computers: [Computer] { [localComputer, devbox, builder] }

    public static var workers: [Worker] {
        [
            Worker(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                name: "Completion Engine",
                harness: .claudeCode,
                model: "GPT-5.6",
                instructions: "Harte, detailreiche Umsetzung exakt nach Brief. Whitelist strikt einhalten, kein Scope-Drift.",
                computerID: localComputer.id,
                quota: QuotaStatus(usedPercent: 0.62, rateLimited: false)
            ),
            Worker(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                name: "Reviewer",
                harness: .claudeCode,
                model: "Kimi K3",
                instructions: "Unabhängiges Review substanzieller Integrationen; entscheidet Dispute zwischen Agents.",
                computerID: localComputer.id,
                quota: QuotaStatus(usedPercent: 0.18, rateLimited: false)
            ),
            Worker(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
                name: "UI/UX-Experte",
                harness: .piSidecar,
                model: "Kimi K3",
                instructions: "Greenfield-UI von Grund auf; Systemtypografie, lineare Hierarchie, keine dekorativen Elemente.",
                computerID: devbox.id,
                quota: QuotaStatus(usedPercent: 0.34, rateLimited: false)
            ),
            Worker(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
                name: "Bulk Worker",
                harness: .claudeCode,
                model: "MiniMax M3",
                instructions: "Klar umrissene, repetitive Massenarbeit: Generierung, Klassifikation, Tests. Write-only, kein Edit, kein git.",
                computerID: builder.id,
                quota: QuotaStatus(usedPercent: 0.87, rateLimited: true)
            )
        ]
    }

    public static var activeRuns: [ActiveRun] {
        let now = Date()
        return [
            ActiveRun(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                workerID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                workerName: "Completion Engine",
                activity: "Brief #42: API-Endpunkte implementieren",
                startedAt: now.addingTimeInterval(-192)
            ),
            ActiveRun(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
                workerID: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
                workerName: "Bulk Worker",
                activity: "Testfälle für Parser generieren (Batch 3/5)",
                startedAt: now.addingTimeInterval(-47)
            )
        ]
    }

    public static var providers: [Provider] {
        [
            Provider(
                name: "MiniMax Coding Plan",
                kind: .oauthSubscription,
                endpoint: "https://api.minimax.io/anthropic",
                status: .connected,
                quota: QuotaStatus(usedPercent: 0.87, rateLimited: true)
            ),
            Provider(
                name: "Kimi Coding Plan",
                kind: .oauthSubscription,
                endpoint: "https://api.moonshot.cn/anthropic",
                status: .connected,
                quota: QuotaStatus(usedPercent: 0.25, rateLimited: false)
            ),
            Provider(
                name: "Anthropic API",
                kind: .apiKey,
                endpoint: "https://api.anthropic.com",
                status: .offline,
                quota: QuotaStatus(usedPercent: 0.0, rateLimited: false)
            )
        ]
    }

    public static let cliProxy = CLIProxyStatus(
        endpoint: "http://127.0.0.1:8317",
        status: .connected,
        account: "ChatGPT Pro (OAuth)"
    )

    public static let skillRules = """
        Du bist der Workjet-Orchestrator. Zerlege die Aufgabe, schreibe präzise Briefs, \
        route Arbeit an die deklarierten Worker, integriere und verifiziere die Ergebnisse. \
        Massenarbeit delegierst du, die finale Bearbeitung machst du selbst.
        """

    public static func makeViewModel(service: WorkjetService = NullWorkjetService()) -> WorkjetViewModel {
        WorkjetViewModel(
            service: service,
            workers: workers,
            computers: computers,
            providers: providers,
            activeRuns: activeRuns,
            cliProxy: cliProxy,
            skillRules: skillRules,
            skillActivation: .skillOnly,
            injectWorkerDeclarations: true,
            telemetryClaudeCodeEvents: true,
            telemetrySidecarEvents: true,
            telemetryRetentionDays: 14,
            providerSlots: 3,
            probeTimeoutSeconds: 20,
            turnTimeoutSeconds: 900,
            degradationAllowed: true
        )
    }
}

public extension WorkjetViewModel {
    static func preview() -> WorkjetViewModel {
        PreviewData.makeViewModel()
    }
}
