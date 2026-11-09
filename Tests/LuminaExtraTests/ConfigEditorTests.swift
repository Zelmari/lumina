#if os(macOS)
import Foundation
import AppKit
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

    @Test func configWindowCanBeReopenedWithoutLosingItsInstance() throws {
        _ = NSApplication.shared
        let file = try temporaryConfig("space-count = 7\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let controller = ConfigWindowController(path: file.path, openFile: {})
        let originalWindow = try #require(controller.window)
        #expect(originalWindow.title == "Lumina Config")
        controller.show()
        #expect(originalWindow.isVisible)
        originalWindow.close()
        controller.show()
        #expect(controller.window === originalWindow)
        #expect(originalWindow.isVisible)
        originalWindow.close()
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

    @Test func formResetPreservesRulesBindingsAndUnknownSettings() async throws {
        let original = """
        # My settings
        space-count = 3
        custom-setting = 'keep'
        [bindings]
        alt-h = "focus right"
        [[window-rule]]
        app-id = "com.example.test"
        action = "float"
        """
        let file = try temporaryConfig(original)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ConfigEditorStore(path: file.path)
        store.restoreDefaults()
        try await Task.sleep(for: .milliseconds(600))
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(store.error == nil)
        #expect(saved.contains("# My settings"))
        #expect(saved.contains("custom-setting = 'keep'"))
        let config = try parseConfig(text: saved, defaults: .bundledDefault).get()
        #expect(config.spaceCount == Config.bundledDefault.spaceCount)
        #expect(config.bindings.count == 1)
        #expect(config.bindings.first?.command == .focus(.right))
        #expect(config.windowRules.first?.appId == "com.example.test")
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
