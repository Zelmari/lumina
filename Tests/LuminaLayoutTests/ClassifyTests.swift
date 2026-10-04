import Foundation
import Testing
@testable import LuminaLayout

struct ClassifyTests {
    @Test func sheetPlusTileRuleStillFloats() {
        let rules = [WindowRule(appId: "com.example.app", action: .tile)]
        let input = ClassifyInput(bundleId: "com.example.app", role: AXRoleName.sheet)
        #expect(classify(input, rules: rules) == .floating)
        let subroleSheet = ClassifyInput(
            bundleId: "com.example.app",
            role: AXRoleName.standardWindow,
            subrole: AXRoleName.sheet
        )
        #expect(classify(subroleSheet, rules: rules) == .floating)
        let subroleDialog = ClassifyInput(
            bundleId: "com.example.app",
            role: "AXWindow",
            subrole: AXRoleName.dialog
        )
        #expect(classify(subroleDialog, rules: rules) == .floating)
    }

    @Test func terminalNoZoomTiles() {
        let input = ClassifyInput(
            bundleId: "com.apple.Terminal",
            role: AXRoleName.standardWindow,
            hasZoomButton: false,
            width: 800,
            height: 600
        )
        #expect(classify(input, rules: []) == .tiled)
    }

    @Test func standardWindowWithoutZoomButtonTiles() {
        let input = ClassifyInput(
            bundleId: "com.microsoft.VSCode",
            role: "AXWindow",
            subrole: AXRoleName.standardWindow,
            hasZoomButton: false,
            width: 1000,
            height: 800
        )
        #expect(classify(input, rules: []) == .tiled)
    }

    @Test func sizeFloor399Floats400Tiles() {
        let small = ClassifyInput(width: 399, height: 299)
        #expect(classify(small, rules: []) == .floating)
        let ok = ClassifyInput(width: 400, height: 300)
        #expect(classify(ok, rules: []) == .tiled)
    }

    @Test func systemSettingsDefaultFloatRule() {
        let rules = [
            WindowRule(appId: "com.apple.systempreferences", action: .float),
            WindowRule(appId: "com.apple.Preferences", action: .float),
        ]
        #expect(classify(ClassifyInput(bundleId: "com.apple.systempreferences"), rules: rules) == .floating)
        #expect(classify(ClassifyInput(bundleId: "com.apple.Preferences"), rules: rules) == .floating)
    }

    @Test func spotlightHardFloatEvenWithTileRule() {
        let rules = [WindowRule(appId: "com.apple.Spotlight", action: .tile)]
        #expect(classify(ClassifyInput(bundleId: "com.apple.Spotlight"), rules: rules) == .floating)
    }

    @Test func titleRegexMissThenHit() {
        let rules = [WindowRule(appId: "com.example.app", titleRegex: "Prefs", action: .float)]
        let miss = ClassifyInput(bundleId: "com.example.app", title: nil, width: 800, height: 600)
        #expect(classify(miss, rules: rules) == .tiled)
        let hit = ClassifyInput(bundleId: "com.example.app", title: "Prefs", width: 800, height: 600)
        #expect(classify(hit, rules: rules) == .floating)
    }

    @Test func centerOnOtherDisplayUnmanaged() {
        let input = ClassifyInput(centerOnBoundDisplay: false)
        #expect(classify(input, rules: []) == .unmanaged)
        #expect(!centerOnDisplay(rect: Rect(x: 2000, y: 0, w: 100, h: 100), displayFrame: Rect(x: 0, y: 0, w: 1000, h: 800)))
        #expect(centerOnDisplay(rect: Rect(x: 0, y: 0, w: 100, h: 100), displayFrame: Rect(x: 0, y: 0, w: 1000, h: 800)))
        let bound = Rect(x: 0, y: 0, w: 1000, h: 800)
        let screens = [bound, Rect(x: 2000, y: 0, w: 1000, h: 800)]
        #expect(centerOnOtherDisplay(rect: Rect(x: 2100, y: 10, w: 100, h: 100), bound: bound, screens: screens))
        #expect(shouldManageOnBoundDisplay(rect: Rect(x: 900, y: 0, w: 400, h: 600), bound: bound, screens: screens))
        #expect(!shouldManageOnBoundDisplay(rect: Rect(x: 2100, y: 10, w: 100, h: 100), bound: bound, screens: screens))
    }

    @Test func hiddenTabHeuristicIgnored() {
        let input = ClassifyInput(isOnScreen: false, pidAlreadyHasOnScreenWindow: true)
        #expect(classify(input, rules: []) == .ignored)
    }

    @Test func siriAppTilesUnlessDialog() {
        let siri = ClassifyInput(bundleId: "com.apple.siri", role: AXRoleName.standardWindow)
        #expect(classify(siri, rules: []) == .tiled)
        let dialog = ClassifyInput(bundleId: "com.apple.siri", role: AXRoleName.dialog)
        #expect(classify(dialog, rules: []) == .floating)
    }

    @Test func pipFlagFloats() {
        #expect(classify(ClassifyInput(isPiP: true), rules: []) == .floating)
        #expect(classify(ClassifyInput(layerOrIsHUD: true), rules: []) == .floating)
        #expect(classify(ClassifyInput(isVisualIntelligenceOrSiriHUD: true), rules: []) == .floating)
    }

    @Test func scrollAreaNotAWindow() {
        let input = ClassifyInput(bundleId: "com.apple.finder", role: "AXScrollArea", width: 1470, height: 956)
        #expect(classify(input, rules: []) == .unmanaged)
    }

    @Test func ignoreAlwaysWins() {
        let rules = [WindowRule(appId: "com.example.app", action: .ignore)]
        #expect(classify(ClassifyInput(bundleId: "com.example.app"), rules: rules) == .ignored)
    }
}
