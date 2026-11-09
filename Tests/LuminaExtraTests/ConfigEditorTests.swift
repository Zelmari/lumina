#if os(macOS)
import Foundation
import Testing
import LuminaLayout
@testable import Lumina

@MainActor
struct ConfigEditorTests {
    private func temporaryConfig(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("lumina.toml")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func autosavePreservesCommentsAndPartialDefaults() async throws {
        let file = try temporaryConfig("# Keep this comment\nspace-count = 7\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConfigEditorStore(path: file.path)
        #expect(store.config.nativeTabs == Config.bundledDefault.nativeTabs)
        #expect(store.config.bindings == Config.bundledDefault.bindings)
        store.set("inner", table: "gaps", literal: "24")
        try await Task.sleep(for: .milliseconds(600))
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved.contains("# Keep this comment"))
        let config = try parseConfig(text: saved, defaults: .bundledDefault).get()
        #expect(config.gaps.inner == 24)
        #expect(config.spaceCount == 7)
        #expect(store.error == nil)
    }

    @Test func invalidEditsNeverOverwriteFile() async throws {
        let original = "space-count = 7\n"
        let file = try temporaryConfig(original)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConfigEditorStore(path: file.path)
        store.editRaw("space-count = 0\n")
        try await Task.sleep(for: .milliseconds(600))
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        #expect(store.error != nil)
    }

    @Test func skippedInvalidBindingsAreNotAutosaved() async throws {
        let original = "space-count = 7\n"
        let file = try temporaryConfig(original)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConfigEditorStore(path: file.path)
        store.editRaw("[bindings]\nalt-h = \"bogus command\"\n")
        try await Task.sleep(for: .milliseconds(600))
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        #expect(store.error != nil)
    }

    @Test func externalEditStopsPendingAutosave() async throws {
        let file = try temporaryConfig("space-count = 7\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConfigEditorStore(path: file.path)
        store.set("space-count", literal: "6")
        let external = "# External edit\nspace-count = 9\n"
        try external.write(to: file, atomically: true, encoding: .utf8)
        store.refreshFromDisk()
        try await Task.sleep(for: .milliseconds(600))
        #expect(store.conflict)
        #expect(try String(contentsOf: file, encoding: .utf8) == external)
        store.reloadFromDisk()
        #expect(!store.conflict)
        #expect(store.config.spaceCount == 9)
    }

    @Test func externalEditRefreshesCleanForm() throws {
        let file = try temporaryConfig("space-count = 7\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConfigEditorStore(path: file.path)
        try "space-count = 3\n".write(to: file, atomically: true, encoding: .utf8)
        store.refreshFromDisk()
        #expect(store.config.spaceCount == 3)
        #expect(!store.conflict)
    }
}
#endif
