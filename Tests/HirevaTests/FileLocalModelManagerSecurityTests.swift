import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct FileLocalModelManagerSecurityTests {
    @Test
    func parakeetManifestPinsCanonicalIdentityArchiveAndEveryPayloadFile() throws {
        let model = LocalModelDescriptor.defaultParakeetASR
        #expect(model.id == "parakeet-tdt-0.6b-v3-int8")
        #expect(model.version == "asr-models-5793d0fd397c5778")
        #expect(model.storageRelativePath == "asr/\(model.canonicalIdentifier)")
        #expect(model.storageRelativePath == model.canonicalStorageRelativePath)
        #expect(model.sizeBytes == 487_170_055)
        #expect(model.checksum == "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf")
        #expect(model.downloadURL?.scheme == "https")
        #expect(model.downloadURL?.host == "github.com")
        #expect(Set(model.trustedDownloadHosts) == ["github.com", "release-assets.githubusercontent.com"])
        #expect(model.archiveRootDirectory == "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
        #expect(model.legacyStorageRelativePaths == ["asr/parakeet-tdt-0.6b-v3-int8"])

        let expected: [String: (Int64, String)] = [
            "encoder.int8.onnx": (652_184_281, "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247"),
            "decoder.int8.onnx": (11_845_275, "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e"),
            "joiner.int8.onnx": (6_355_277, "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3"),
            "tokens.txt": (93_939, "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"),
            "test_wavs/de.wav": (121_388, "36d3c4845b9808a1656a2a2e92d884590e2db94389e6fe559643291ae0cd3710"),
            "test_wavs/en.wav": (184_608, "148b936b43ce7c546a866e64da059f0458aee2d65e617f16e9d94f06e8d99ed6"),
            "test_wavs/es.wav": (235_052, "49fd2cfa4b62db7068143c582b35de9d31ec2733495ece3611105131d21de06c"),
            "test_wavs/fr.wav": (219_180, "b59be4349b92d344fb903677165eaf4694025d1ab119c608726ecbcb3164b528")
        ]
        #expect(model.requiredFiles.count == expected.count)
        for requirement in model.requiredFiles {
            let pinned = try #require(expected[requirement.relativePath])
            #expect(requirement.exactBytes == pinned.0)
            #expect(requirement.sha256 == pinned.1)
        }
    }

    @Test
    func checksumFailureLeavesPreviouslyInstalledModelUntouched() async throws {
        let fixture = try makeArchiveFixture(id: "checksum-model", payload: Data("verified".utf8))
        let manager = FileLocalModelManager(rootDirectory: fixture.root.appendingPathComponent("models"))
        try await consume(manager.downloadModel(fixture.descriptor))

        let invalidFixture = try makeArchiveFixture(id: "checksum-model-bad", payload: Data("tampered".utf8))
        let invalidDescriptor = descriptor(
            id: fixture.descriptor.id,
            archiveURL: invalidFixture.archive,
            archiveHash: fixture.descriptor.checksum!,
            archiveSize: try fileSize(invalidFixture.archive),
            payload: Data("verified".utf8)
        )
        do {
            try await consume(manager.repairModel(invalidDescriptor))
            Issue.record("Expected the archive checksum to be rejected")
        } catch let error as LocalModelManagerError {
            guard case .checksumMismatch = error else {
                Issue.record("Unexpected installer error: \(error)")
                return
            }
        }

        let installed = manager.fileURL(for: fixture.descriptor).appendingPathComponent("model.bin")
        #expect(try Data(contentsOf: installed) == Data("verified".utf8))
        #expect(await manager.modelStatus(fixture.descriptor) == .installed)
    }

    @Test
    func archivePreflightRejectsTraversalAndSymlinkEntries() async throws {
        let root = temporaryDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: source.appendingPathComponent("safe"))

        let traversalArchive = root.appendingPathComponent("traversal.tar.bz2")
        try runProcess(
            "/usr/bin/tar",
            ["-cjf", traversalArchive.path, "-s", ",safe,../escape,", "-C", source.path, "safe"]
        )
        let traversalModel = descriptorForUntrustedArchive(id: "traversal", archiveURL: traversalArchive)
        let traversalManager = FileLocalModelManager(rootDirectory: root.appendingPathComponent("traversal-models"))
        do {
            try await consume(traversalManager.downloadModel(traversalModel))
            Issue.record("Expected traversal archive rejection")
        } catch let error as LocalModelManagerError {
            #expect(error == .unsafeArchiveEntry("../escape"))
        }
        #expect(FileManager.default.fileExists(atPath: traversalManager.fileURL(for: traversalModel).path) == false)

        let link = source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.appendingPathComponent("safe"))
        let symlinkArchive = root.appendingPathComponent("symlink.tar.bz2")
        try runProcess("/usr/bin/tar", ["-cjf", symlinkArchive.path, "-C", source.path, "link"])
        let symlinkModel = descriptorForUntrustedArchive(id: "symlink", archiveURL: symlinkArchive)
        let symlinkManager = FileLocalModelManager(rootDirectory: root.appendingPathComponent("symlink-models"))
        do {
            try await consume(symlinkManager.downloadModel(symlinkModel))
            Issue.record("Expected symlink archive rejection")
        } catch let error as LocalModelManagerError {
            guard case .unsafeArchiveEntry = error else {
                Issue.record("Unexpected installer error: \(error)")
                return
            }
        }
        #expect(FileManager.default.fileExists(atPath: symlinkManager.fileURL(for: symlinkModel).path) == false)
    }

    @Test
    func repairCreatesVerifiedRollbackAndDeleteRemovesManagedCopies() async throws {
        let fixture = try makeArchiveFixture(id: "rollback-model", payload: Data("stable".utf8))
        let manager = FileLocalModelManager(rootDirectory: fixture.root.appendingPathComponent("models"))
        try await consume(manager.downloadModel(fixture.descriptor))
        try await consume(manager.repairModel(fixture.descriptor))

        let installedFile = manager.fileURL(for: fixture.descriptor).appendingPathComponent("model.bin")
        try Data("broken".utf8).write(to: installedFile)
        #expect(try await manager.verifyModel(fixture.descriptor) == false)

        try await manager.rollbackModel(fixture.descriptor)
        #expect(try await manager.verifyModel(fixture.descriptor))
        #expect(try Data(contentsOf: installedFile) == Data("stable".utf8))

        try await manager.deleteModel(fixture.descriptor)
        #expect(await manager.modelStatus(fixture.descriptor) == .notInstalled)
    }

    @Test
    func legacyMigrationCopiesVerifiedModelAndKeepsLegacySource() async throws {
        let root = temporaryDirectory().appendingPathComponent("models")
        let payload = Data("legacy".utf8)
        let model = LocalModelDescriptor(
            id: "legacy-model",
            version: "v1",
            displayName: "Legacy Model",
            kind: .transcription,
            sizeBytes: nil,
            downloadURL: nil,
            checksum: nil,
            storageRelativePath: "legacy-model/v1",
            requiredFiles: [
                LocalModelFileRequirement(
                    relativePath: "model.bin",
                    exactBytes: Int64(payload.count),
                    sha256: sha256(payload)
                )
            ],
            legacyStorageRelativePaths: ["old/legacy-model"]
        )
        let legacyURL = root.appendingPathComponent("old/legacy-model", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        try payload.write(to: legacyURL.appendingPathComponent("model.bin"))
        let manager = FileLocalModelManager(rootDirectory: root)

        #expect(await manager.modelStatus(model) == .installed)
        #expect(FileManager.default.fileExists(atPath: legacyURL.appendingPathComponent("model.bin").path))
        #expect(FileManager.default.fileExists(atPath: manager.fileURL(for: model).appendingPathComponent("model.bin").path))

        try await manager.deleteModel(model)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)
        #expect(await manager.modelStatus(model) == .notInstalled)
    }

    @Test
    func invalidLegacyMigrationLeavesSourceUntouched() async throws {
        let root = temporaryDirectory().appendingPathComponent("models")
        let expectedPayload = Data("verified legacy".utf8)
        let model = LocalModelDescriptor(
            id: "invalid-legacy-model",
            version: "v1",
            displayName: "Invalid Legacy Model",
            kind: .transcription,
            sizeBytes: nil,
            downloadURL: nil,
            checksum: nil,
            storageRelativePath: "invalid-legacy-model/v1",
            requiredFiles: [
                LocalModelFileRequirement(
                    relativePath: "model.bin",
                    exactBytes: Int64(expectedPayload.count),
                    sha256: sha256(expectedPayload)
                )
            ],
            legacyStorageRelativePaths: ["old/invalid-legacy-model"]
        )
        let legacyURL = root.appendingPathComponent("old/invalid-legacy-model", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: legacyURL.appendingPathComponent("model.bin"))
        let manager = FileLocalModelManager(rootDirectory: root)

        #expect(try await manager.verifyModel(model) == false)
        #expect(FileManager.default.fileExists(atPath: legacyURL.appendingPathComponent("model.bin").path))
        #expect(FileManager.default.fileExists(atPath: manager.fileURL(for: model).path) == false)
    }

    @Test
    func nestedLegacyMigrationMovesWithoutDuplicatingPayload() async throws {
        let root = temporaryDirectory().appendingPathComponent("models")
        let payload = Data("verified nested legacy".utf8)
        let model = LocalModelDescriptor(
            id: "nested-legacy-model",
            version: "v1",
            displayName: "Nested Legacy Model",
            kind: .transcription,
            sizeBytes: nil,
            downloadURL: nil,
            checksum: nil,
            storageRelativePath: "asr/nested-legacy-model/v1",
            requiredFiles: [
                LocalModelFileRequirement(
                    relativePath: "model.bin",
                    exactBytes: Int64(payload.count),
                    sha256: sha256(payload)
                )
            ],
            legacyStorageRelativePaths: ["asr/nested-legacy-model"],
            storageNamespace: "asr"
        )
        let legacyURL = root.appendingPathComponent("asr/nested-legacy-model", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        try payload.write(to: legacyURL.appendingPathComponent("model.bin"))
        let manager = FileLocalModelManager(rootDirectory: root)

        #expect(await manager.modelStatus(model) == .installed)
        #expect(FileManager.default.fileExists(atPath: legacyURL.appendingPathComponent("model.bin").path) == false)
        #expect(FileManager.default.fileExists(atPath: manager.fileURL(for: model).appendingPathComponent("model.bin").path))
        #expect(FileManager.default.fileExists(atPath: legacyURL.appendingPathComponent(".legacy-migration.json").path))

        let nextVersionURL = legacyURL.appendingPathComponent("v2", isDirectory: true)
        try FileManager.default.createDirectory(at: nextVersionURL, withIntermediateDirectories: true)
        try Data("next version".utf8).write(to: nextVersionURL.appendingPathComponent("model.bin"))
        try await manager.deleteModel(model)
        #expect(FileManager.default.fileExists(atPath: legacyURL.appendingPathComponent("model.bin").path) == false)
        #expect(FileManager.default.fileExists(atPath: nextVersionURL.appendingPathComponent("model.bin").path))
        #expect(FileManager.default.fileExists(atPath: legacyURL.appendingPathComponent(".legacy-migration.json").path) == false)
    }

    @Test
    func failedSmokeCheckDoesNotReplaceKnownGoodModel() async throws {
        let fixture = try makeArchiveFixture(id: "smoke-model", payload: Data("known good".utf8))
        let root = fixture.root.appendingPathComponent("models")
        let initialManager = FileLocalModelManager(rootDirectory: root)
        try await consume(initialManager.downloadModel(fixture.descriptor))

        let rejectingManager = FileLocalModelManager(
            rootDirectory: root,
            modelSmokeValidator: { _, _ in
                throw LocalModelManagerError.downloadFailed("smoke rejected")
            }
        )
        do {
            try await consume(rejectingManager.repairModel(fixture.descriptor))
            Issue.record("Expected smoke validation to reject the candidate model")
        } catch {
            #expect(error.localizedDescription.contains("smoke rejected"))
        }

        let installed = initialManager.fileURL(for: fixture.descriptor).appendingPathComponent("model.bin")
        #expect(try Data(contentsOf: installed) == Data("known good".utf8))
    }

    @Test
    func activeRuntimeLockPreventsModelDeletion() async throws {
        let fixture = try makeArchiveFixture(id: "locked-model", payload: Data("active".utf8))
        let root = fixture.root.appendingPathComponent("models")
        let manager = FileLocalModelManager(rootDirectory: root)
        try await consume(manager.downloadModel(fixture.descriptor))

        let lockURL = root.appendingPathComponent(".\(fixture.descriptor.id).use.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(descriptor >= 0)
        #expect(flock(descriptor, LOCK_SH) == 0)
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        await #expect(throws: LocalModelManagerError.modelInUse(fixture.descriptor.displayName)) {
            try await manager.deleteModel(fixture.descriptor)
        }
        #expect(await manager.modelStatus(fixture.descriptor) == .installed)
    }

    @Test
    func concurrentDownloadsAcrossManagersForSameCanonicalModelAreSerialized() async throws {
        let fixture = try makeArchiveFixture(id: "serialized-model", payload: Data(repeating: 9, count: 512 * 1024))
        let root = fixture.root.appendingPathComponent("models")
        let firstManager = FileLocalModelManager(rootDirectory: root)
        let secondManager = FileLocalModelManager(rootDirectory: root)

        async let first: Void = consume(firstManager.downloadModel(fixture.descriptor))
        async let second: Void = consume(secondManager.downloadModel(fixture.descriptor))
        _ = try await (first, second)

        #expect(await firstManager.modelStatus(fixture.descriptor) == .installed)
        #expect(try await secondManager.verifyModel(fixture.descriptor))
    }
}

private struct ArchiveFixture {
    let root: URL
    let archive: URL
    let descriptor: LocalModelDescriptor
}

private func makeArchiveFixture(id: String, payload: Data) throws -> ArchiveFixture {
    let root = temporaryDirectory()
    let bundle = root.appendingPathComponent("bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try payload.write(to: bundle.appendingPathComponent("model.bin"))
    let archive = root.appendingPathComponent("\(id).tar.bz2")
    try runProcess("/usr/bin/tar", ["-cjf", archive.path, "-C", root.path, "bundle"])
    let model = descriptor(
        id: id,
        archiveURL: archive,
        archiveHash: try sha256(archive),
        archiveSize: try fileSize(archive),
        payload: payload
    )
    return ArchiveFixture(root: root, archive: archive, descriptor: model)
}

private func descriptor(
    id: String,
    archiveURL: URL,
    archiveHash: String,
    archiveSize: Int64,
    payload: Data
) -> LocalModelDescriptor {
    LocalModelDescriptor(
        id: id,
        version: "v1",
        displayName: id,
        kind: .transcription,
        sizeBytes: archiveSize,
        downloadURL: archiveURL,
        checksum: archiveHash,
        storageRelativePath: "\(id)/v1",
        requiredFiles: [
            LocalModelFileRequirement(
                relativePath: "model.bin",
                exactBytes: Int64(payload.count),
                sha256: sha256(payload)
            )
        ],
        archiveRootDirectory: "bundle"
    )
}

private func descriptorForUntrustedArchive(id: String, archiveURL: URL) -> LocalModelDescriptor {
    LocalModelDescriptor(
        id: id,
        version: "v1",
        displayName: id,
        kind: .transcription,
        sizeBytes: try? fileSize(archiveURL),
        downloadURL: archiveURL,
        checksum: try? sha256(archiveURL),
        storageRelativePath: "\(id)/v1",
        requiredFiles: [LocalModelFileRequirement(relativePath: "model.bin", minimumBytes: 1)]
    )
}

private func consume(_ stream: AsyncThrowingStream<ModelDownloadProgress, Error>) async throws {
    for try await _ in stream {}
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("HirevaModelInstallerTests-\(UUID().uuidString)", isDirectory: true)
}

private func runProcess(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "FileLocalModelManagerSecurityTests",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "process failed"]
        )
    }
}

private func fileSize(_ url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sha256(_ url: URL) throws -> String {
    try sha256(Data(contentsOf: url))
}
