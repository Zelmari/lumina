import Foundation
import Testing
@testable import LuminaLayout

struct ConfigTests {
    @Test func defaultBundledTOMLParses() throws {
        let result = parseConfig(text: Config.bundledDefaultTOML)
        let config = try result.get()
        #expect(config.spaceCount == 5)
        #expect(config.focusFollowsMouse == false)
        #expect(config.launchTiling == .zOrder)
        #expect(config.gaps.inner == 8)
        #expect(config.gaps.outer == 8)
        #expect(config.windowRules.contains(where: { $0.appId == "com.apple.systempreferences" && $0.action == .float }))
        #expect(config.windowRules.contains(where: { $0.appId == "com.apple.Preferences" && $0.action == .float }))
        #expect(config.bindings.contains(where: { $0.chord.keyName == "h" && $0.command == .focus(.left) }))
        #expect(config.bindings.contains(where: { $0.chord.keyName == "0" && $0.command == .workspace(10) }))
    }

    @Test func bundledDefaultMatchesResourceFile() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let resource = testsDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Lumina/Resources/lumina.toml")
        let disk = try String(contentsOf: resource, encoding: .utf8)
        #expect(
            disk.trimmingCharacters(in: .whitespacesAndNewlines)
                == Config.bundledDefaultTOML.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @Test func rejectsOutOfRange() {
        let zero = parseConfig(text: """
        space-count = 0
        focus-follows-mouse = false
        launch-tiling = "z-order"
        launch-apps = []
        [gaps]
        inner = 8
        outer = 8
        [bindings]
        """)
        #expect(zero.isFail)
        let neg = parseConfig(text: """
        space-count = 5
        focus-follows-mouse = false
        launch-tiling = "z-order"
        launch-apps = []
        [gaps]
        inner = -1
        outer = 8
        [bindings]
        """)
        #expect(neg.isFail)
    }

    @Test func badRegexSkipsRuleFileStillValid() throws {
        let text = """
        space-count = 5
        focus-follows-mouse = false
        launch-tiling = "z-order"
        launch-apps = []
        [gaps]
        inner = 8
        outer = 8
        [bindings]
        [[window-rule]]
        app-id = "com.example.app"
        title-regex = "("
        action = "float"
        [[window-rule]]
        app-id = "com.apple.systempreferences"
        action = "float"
        """
        let config = try parseConfig(text: text).get()
        #expect(config.windowRules.count == 1)
        #expect(config.windowRules[0].appId == "com.apple.systempreferences")
        #expect(config.diagnostics.contains(where: { $0.contains("title-regex") }))
    }

    @Test func unknownCommandStringRejectsFile() {
        let text = """
        space-count = 5
        focus-follows-mouse = false
        launch-tiling = "z-order"
        launch-apps = []
        [gaps]
        inner = 8
        outer = 8
        [bindings]
        alt-h = "explode everything"
        """
        #expect(parseConfig(text: text).isFail)
    }

    @Test func unknownTopLevelKeyIgnored() throws {
        let text = """
        space-count = 5
        focus-follows-mouse = false
        launch-tiling = "z-order"
        launch-apps = []
        extra-sauce = true
        [gaps]
        inner = 8
        outer = 8
        [bindings]
        """
        let config = try parseConfig(text: text).get()
        #expect(config.unknownTopLevelKeys.contains("extra-sauce"))
        #expect(config.spaceCount == 5)
    }

    @Test func duplicateChordLastWins() throws {
        let text = """
        space-count = 5
        focus-follows-mouse = false
        launch-tiling = "z-order"
        launch-apps = []
        [gaps]
        inner = 8
        outer = 8
        [bindings]
        alt-h = "focus left"
        alt-h = "focus right"
        """
        let config = try parseConfig(text: text).get()
        let h = config.bindings.filter { $0.chord.keyName == "h" && !$0.chord.shift }
        #expect(h.count == 1)
        #expect(h[0].command == .focus(.right))
    }

    @Test func duplicateNormalizedChordLastWinsDeterministically() throws {
        // `alt-cmd-h` drops the unsupported `cmd` modifier, so both raw keys
        // normalize to the same chord. The lexicographically later key wins.
        let text = """
        space-count = 5
        focus-follows-mouse = false
        launch-tiling = "z-order"
        launch-apps = []
        [gaps]
        inner = 8
        outer = 8
        [bindings]
        alt-cmd-h = "focus left"
        alt-h = "focus right"
        """
        let config = try parseConfig(text: text).get()
        let h = config.bindings.filter { $0.chord.keyName == "h" && !$0.chord.shift }
        #expect(h.count == 1)
        #expect(h[0].command == .focus(.right))
        #expect(config.diagnostics.contains(where: { $0.contains("duplicate chord") }))
    }

    @Test func applySpaceCountPoursOntoSpace1() {
        var session = Session.empty(spaceCount: 7)
        session.focusedSpace = SpaceId.require(7)
        session = session.insertSpiral(
            space: SpaceId.require(4),
            newLeaf: WindowRef(cgWindowId: 41, pid: 41),
            usableIsWide: true
        )
        session = session.insertSpiral(
            space: SpaceId.require(7),
            newLeaf: WindowRef(cgWindowId: 71, pid: 71),
            usableIsWide: true
        )
        session = session.applySpaceCount(3)
        #expect(session.spaceCount == 3)
        #expect(session.focusedSpace.raw == 1)
        let s1 = session[SpaceId.require(1)]!
        let ids = Set(s1.tiledLeaves().compactMap { $0.leaf?.cgWindowId } + s1.floating.map(\.cgWindowId))
        #expect(ids.contains(41))
        #expect(ids.contains(71))
        #expect(session.spaces[SpaceId.require(4)] == nil)
        #expect(session.spaces[SpaceId.require(7)] == nil)
    }

    @Test func applySpaceCountUnstashesMovedFloaters() {
        var session = Session.empty(spaceCount: 3)
        var dropped = session[SpaceId.require(3)]!
        dropped.floating.append(WindowRef(cgWindowId: 31, pid: 31, role: .floating))
        session[SpaceId.require(3)] = dropped
        // Leaving a space stashes its windows, floaters included.
        session = session.markStashed(space: SpaceId.require(3), ids: [31])
        #expect(session[SpaceId.require(3)]!.floating.first?.role == .stashed)

        session = session.applySpaceCount(1)
        let dest = session[SpaceId.require(1)]!
        #expect(dest.floating.count == 1)
        #expect(dest.floating.first?.cgWindowId == 31)
        #expect(dest.floating.first?.role == .floating)
    }

    @Test func resolveWorkspaceNilIfGreaterThanCount() {
        #expect(resolveWorkspace(id: 3, count: 5)?.raw == 3)
        #expect(resolveWorkspace(id: 99, count: 5) == nil)
        #expect(resolveWorkspace(id: 0, count: 5) == nil)
        #expect(resolveWorkspace(id: 0, count: 10)?.raw == 10)
        #expect(resolveWorkspace(id: 10, count: 5) == nil)
    }

    @Test func invalidTomlKeepsDefaultAndReportsError() {
        let (config, error) = loadOrDefault(text: "space-count = 0\n")
        #expect(error != nil)
        #expect(config.spaceCount == 5)
        let (missing, missingError) = loadOrDefault(text: nil)
        #expect(missingError == nil)
        #expect(missing.spaceCount == 5)
    }

    @Test func applyReloadKeepsLastGood() {
        let current = try! parseConfig(text: Config.bundledDefaultTOML).get()
        let (config, error) = applyReload(current: current, newText: "space-count = 0\n")
        #expect(error != nil)
        #expect(config.spaceCount == 5)
    }

    @Test func applyReloadBlankTextKeepsCurrent() throws {
        var current = try parseConfig(text: Config.bundledDefaultTOML).get()
        current.spaceCount = 7
        let (config, error) = applyReload(current: current, newText: "   \n\n")
        #expect(error == nil)
        #expect(config.spaceCount == 7)
        #expect(config == current)
    }

    @Test func keycodesMatchDesignTable() {
        #expect(VirtualKey.table["h"] == 0x04)
        #expect(VirtualKey.table["j"] == 0x26)
        #expect(VirtualKey.table["k"] == 0x28)
        #expect(VirtualKey.table["l"] == 0x25)
        #expect(VirtualKey.table["minus"] == 0x1B)
        #expect(VirtualKey.table["equal"] == 0x18)
        #expect(VirtualKey.table["1"] == 0x12)
        #expect(VirtualKey.table["0"] == 0x1D)
        #expect(VirtualKey.table["leftSquareBracket"] == 0x21)
        #expect(VirtualKey.table["rightSquareBracket"] == 0x1E)
        #expect(VirtualKey.table["b"] == 0x0B)
        #expect(VirtualKey.table["f"] == 0x03)
        #expect(VirtualKey.table["q"] == 0x0C)
        #expect(VirtualKey.table["space"] == 0x31)
        #expect(parseChord("alt-h")?.keyCode == 0x04)
        #expect(parseChord("alt-shift-1")?.shift == true)
        #expect(parseChord("alt-shift-1")?.keyCode == 0x12)
    }
}

extension Result {
    var isFail: Bool {
        if case .failure = self { return true }
        return false
    }
}
