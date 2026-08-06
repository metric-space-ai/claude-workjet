import Darwin
import Foundation
import XCTest
@testable import WorkjetCore

final class ConfigurationMigrationTransactionTests: XCTestCase {
    func testMutatingMigrationCreatesRestorablePrivateBackupBeforeAtomicReplacement() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.v1.json")
        let secret = "must-not-enter-migration-backup"
        let legacy = legacyConfiguration(marker: "first")
        let original = try legacyData(legacy, unknownSecret: secret)
        try original.write(to: file)

        let store = migrationStore(file: file, retention: 3, timestamp: 1_700_000_000)
        let migrated = try XCTUnwrap(store.load())

        XCTAssertEqual(migrated, WorkjetBootstrap.normalized(legacy))
        XCTAssertEqual(migrated.skillActivation, .global, "Legacy /workjet-only configurations must migrate to global activation.")
        XCTAssertEqual(try JSONDecoder().decode(WorkjetConfiguration.self, from: Data(contentsOf: file)), migrated)

        let backups = try migrationBackups(beside: file)
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(backups[0].lastPathComponent.contains("backup-v1-1700000000000-"))
        let backupData = try Data(contentsOf: backups[0])
        XCTAssertEqual(try JSONDecoder().decode(WorkjetConfiguration.self, from: backupData), legacy)
        XCTAssertFalse(String(decoding: backupData, as: UTF8.self).contains(secret))
        XCTAssertFalse(String(decoding: backupData, as: UTF8.self).contains("apiKey"))

        var info = stat()
        XCTAssertEqual(lstat(backups[0].path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        let migratedBytes = try Data(contentsOf: file)
        XCTAssertEqual(try store.load(), migrated)
        XCTAssertEqual(try Data(contentsOf: file), migratedBytes)
        XCTAssertEqual(try migrationBackups(beside: file), backups, "Eine bereits migrierte Konfiguration darf kein weiteres Backup erzeugen.")
    }

    func testMigrationFailureLeavesOriginalUntouchedAndReportsOnlySafeStatus() throws {
        enum ExpectedFailure: Error { case injected }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.v1.json")
        let original = try legacyData(legacyConfiguration(marker: "failure"), unknownSecret: "private-value")
        try original.write(to: file)
        let store = JSONConfigurationStore(
            fileURL: file,
            backupRetentionCount: 2,
            now: { Date(timeIntervalSince1970: 1_700_000_001) },
            migrate: { _ in throw ExpectedFailure.injected }
        )

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? LocalStateError, .migrationFailed)
            XCTAssertEqual(
                error.localizedDescription,
                "Die Workjet-Konfiguration konnte nicht sicher aktualisiert werden. Die bisherige Konfiguration bleibt erhalten."
            )
            XCTAssertFalse(error.localizedDescription.contains("injected"))
            XCTAssertFalse(error.localizedDescription.contains("private-value"))
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(try migrationBackups(beside: file).isEmpty)
    }

    func testMigrationBackupRetentionIsBounded() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.v1.json")

        for index in 0..<5 {
            try legacyData(legacyConfiguration(marker: "retention-\(index)"), unknownSecret: nil).write(to: file)
            let store = migrationStore(
                file: file,
                retention: 2,
                timestamp: TimeInterval(1_700_000_100 + index)
            )
            _ = try XCTUnwrap(store.load())
            XCTAssertLessThanOrEqual(try migrationBackups(beside: file).count, 2)
        }

        let backups = try migrationBackups(beside: file)
        XCTAssertEqual(backups.count, 2)
        XCTAssertTrue(backups.allSatisfy { (try? JSONDecoder().decode(WorkjetConfiguration.self, from: Data(contentsOf: $0))) != nil })
    }

    private func migrationStore(file: URL, retention: Int, timestamp: TimeInterval) -> JSONConfigurationStore {
        JSONConfigurationStore(
            fileURL: file,
            backupRetentionCount: retention,
            now: { Date(timeIntervalSince1970: timestamp) },
            migrate: { WorkjetBootstrap.normalized($0) }
        )
    }

    private func legacyConfiguration(marker: String) -> WorkjetConfiguration {
        var configuration = WorkjetDefaults.configuration()
        configuration.skillRules += "\n\n- Migration marker: \(marker)"
        configuration.skillLoaderInstructions = nil
        configuration.modelPrompts = nil
        configuration.adHocLearnings = nil
        configuration.technicalRules = nil
        configuration.transparentWorkerPromptsMigrated = nil
        configuration.skillActivation = .skillOnly
        configuration.injectWorkerDeclarations = false
        return configuration
    }

    private func legacyData(_ configuration: WorkjetConfiguration, unknownSecret: String?) throws -> Data {
        let encoded = try JSONEncoder().encode(configuration)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        if let unknownSecret { object["apiKey"] = unknownSecret }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func migrationBackups(beside file: URL) throws -> [URL] {
        let prefix = "\(file.lastPathComponent).backup-v"
        return try FileManager.default.contentsOfDirectory(
            at: file.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workjet-migration-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
