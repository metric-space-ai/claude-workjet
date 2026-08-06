import XCTest
@testable import WorkjetCore

/// Opt-in production-home acceptance test. It updates only the already
/// configured target computer and is never enabled by the ordinary test suite.
final class RemoteWorkerProvisioningLiveTests: XCTestCase {
    @MainActor
    func testConfiguredTargetDeploysHostHarnessAndManagedSkillsBeforePersistence() async throws {
        guard ProcessInfo.processInfo.environment["WORKJET_LIVE_REMOTE_PROVISIONING"] == "1" else {
            throw XCTSkip("Real remote provisioning requires explicit opt-in.")
        }

        let model = WorkjetViewModel.live()
        let computer = try XCTUnwrap(model.computers.first(where: { $0.name == "gpu3-a4500" }))
        XCTAssertFalse(computer.isLocal)

        let deployed = await model.bootstrapRemoteComputer(computer)
        XCTAssertEqual(deployed.deploymentStatus, .installed, deployed.deploymentDetail)

        let provisioning = await model.provisionConfiguredWorkers(on: deployed)
        XCTAssertTrue(provisioning.succeeded, provisioning.failure?.userVisibleDetail ?? "Remote provisioning failed.")
        XCTAssertTrue(provisioning.verifiedCapabilities.contains("claude-code"))
        XCTAssertTrue(provisioning.verifiedCapabilities.contains("greppy"))
        XCTAssertEqual(
            provisioning.components.first(where: { $0.kind == .managedSkill && $0.id == "greppy" })?.version,
            RemoteManagedSkillArtifact.greppyVersion
        )

        let saved = await model.saveComputerDurably(deployed)
        XCTAssertEqual(saved, .succeeded)
    }
}
