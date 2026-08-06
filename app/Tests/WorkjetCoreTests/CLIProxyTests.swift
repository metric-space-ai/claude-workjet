import XCTest
@testable import WorkjetCore

final class CLIProxyCopyTests: XCTestCase {
    func testUserFacingCoreErrorsGiveRecoveryWithoutImplementationDetails() throws {
        let messages = [
            try XCTUnwrap(CLIProxyAccountError.executableUnavailable.errorDescription),
            try XCTUnwrap(CLIProxyAccountError.gatewayCredentialUnavailable.errorDescription),
            try XCTUnwrap(CommandRunError.executableMustBeAbsolute.errorDescription),
            try XCTUnwrap(CommandRunError.launch("private runtime detail").errorDescription),
            try XCTUnwrap(TailscaleDeviceError.notConnected("Stopped").errorDescription),
            try XCTUnwrap(TailscaleDeviceError.outputTooLarge.errorDescription),
            try XCTUnwrap(AdHocLearningError.invalidLength.errorDescription),
        ]

        for message in messages {
            for forbidden in [
                "CLIProxyAPI", "CLIProxy-Schlüssel", "Executable", "Backendstatus",
                "Sicherheitslimit", "UTF-8-Bytes", "private runtime detail",
            ] {
                XCTAssertFalse(message.contains(forbidden), "User-facing error contains \(forbidden): \(message)")
            }
        }

        XCTAssertTrue(messages[0].contains("Web-Anmeldung"))
        XCTAssertTrue(messages[1].contains("Verbinde den Anbieter erneut"))
        XCTAssertTrue(messages[4].contains("Öffne Tailscale"))
    }

    func testProviderProbeCopyAvoidsInternalGatewayAndPlanTerminology() throws {
        let source = try sourceText("Sources/WorkjetCore/CLIProxy.swift")
        for forbidden in [
            "Modellantwort überschreitet das Sicherheitslimit",
            "OAuth/Abonnement wird im lokalen Gateway verwaltet",
            "Diese Anbieterprobe liefert keine account-spezifische Quote oder Rate",
            "MiniMax Token Plan:",
            "MiniMax Token Plan lieferte",
            "MiniMax Token Plan ist derzeit",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Provider copy contains \(forbidden)")
        }
        XCTAssertTrue(source.contains("Für diesen Zugang sind keine Kapazitätsdaten verfügbar."))
        XCTAssertTrue(source.contains(#"detail += " Kontingent: \(measured.summary).""#))
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceText(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
