import Foundation

public struct WindowRule: Equatable, Sendable, Codable {
    public var appId: String
    public var titleRegex: String?
    public var action: WindowRuleAction
    public var titleRegexError: String?

    public init(appId: String, titleRegex: String? = nil, action: WindowRuleAction, titleRegexError: String? = nil) {
        self.appId = appId
        self.titleRegex = titleRegex
        self.action = action
        self.titleRegexError = titleRegexError
    }

    public func matches(bundleId: String?, title: String?) -> Bool {
        guard let bundleId, bundleId == appId else { return false }
        guard let pattern = titleRegex, !pattern.isEmpty else { return true }
        guard let title else { return false }
        return title.range(of: pattern, options: .regularExpression) != nil
    }
}

public enum WindowRuleAction: String, Equatable, Sendable, Codable {
    case tile
    case float
    case ignore
}

public struct ClassifyInput: Equatable, Sendable {
    public var bundleId: String?
    public var title: String?
    public var role: String?
    public var subrole: String?
    public var hasZoomButton: Bool
    public var width: Double
    public var height: Double
    public var isOnScreen: Bool
    public var isMinimized: Bool
    public var pidAlreadyHasOnScreenWindow: Bool
    public var layerOrIsHUD: Bool
    public var isPiP: Bool
    public var isVisualIntelligenceOrSiriHUD: Bool
    public var centerOnBoundDisplay: Bool

    public init(
        bundleId: String? = nil,
        title: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        hasZoomButton: Bool = true,
        width: Double = 800,
        height: Double = 600,
        isOnScreen: Bool = true,
        isMinimized: Bool = false,
        pidAlreadyHasOnScreenWindow: Bool = false,
        layerOrIsHUD: Bool = false,
        isPiP: Bool = false,
        isVisualIntelligenceOrSiriHUD: Bool = false,
        centerOnBoundDisplay: Bool = true
    ) {
        self.bundleId = bundleId
        self.title = title
        self.role = role
        self.subrole = subrole
        self.hasZoomButton = hasZoomButton
        self.width = width
        self.height = height
        self.isOnScreen = isOnScreen
        self.isMinimized = isMinimized
        self.pidAlreadyHasOnScreenWindow = pidAlreadyHasOnScreenWindow
        self.layerOrIsHUD = layerOrIsHUD
        self.isPiP = isPiP
        self.isVisualIntelligenceOrSiriHUD = isVisualIntelligenceOrSiriHUD
        self.centerOnBoundDisplay = centerOnBoundDisplay
    }
}

public enum ClassifyResult: Equatable, Sendable {
    case unmanaged
    case ignored
    case floating
    case tiled
}

public enum AXRoleName {
    public static let sheet = "AXSheet"
    public static let drawer = "AXDrawer"
    public static let popover = "AXPopover"
    public static let helpTag = "AXHelpTag"
    public static let dialog = "AXDialog"
    public static let systemDialog = "AXSystemDialog"
    public static let standardWindow = "AXStandardWindow"
    public static let floatingWindow = "AXFloatingWindow"
    public static let systemFloatingWindow = "AXSystemFloatingWindow"
}

public enum Classify {
    public static let hardFloatBundleIds: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.loginwindow",
        "com.apple.ScreenSharing",
        "com.apple.screencaptureui",
        "com.apple.UserNotificationCenter",
    ]

    public static let terminalBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "org.alacritty",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    public static let hardRoles: Set<String> = [
        AXRoleName.sheet,
        AXRoleName.drawer,
        AXRoleName.popover,
        AXRoleName.helpTag,
    ]

    /// Subrole, not role. AppKit reports dialogs and sheets as `AXWindow` plus one of these.
    /// A `tile` rule cannot override them, same as utility and panel.
    public static let hardSubroles: Set<String> = [
        AXRoleName.floatingWindow,
        AXRoleName.systemFloatingWindow,
        AXRoleName.dialog,
        AXRoleName.systemDialog,
        AXRoleName.sheet,
    ]

    /// Filled in as Visual Intelligence / Siri HUD bundle ids are confirmed.
    /// `docs/compat.md` is the record. Empty means the live path stays off.
    public static let visualIntelligenceBundleIds: Set<String> = []

    public static let dialogRoles: Set<String> = [
        AXRoleName.dialog,
        AXRoleName.systemDialog,
    ]

    /// AXWindowsAttribute sometimes includes chrome (Finder desktop scroll area, web views).
    public static let nonWindowRoles: Set<String> = [
        "AXScrollArea",
        "AXWebArea",
        "AXGroup",
        "AXToolbar",
        "AXMenuBar",
        "AXSplitGroup",
        "AXList",
        "AXOutline",
        "AXImage",
        "AXStaticText",
    ]
}

public func classify(_ input: ClassifyInput, rules: [WindowRule]) -> ClassifyResult {
    if !input.centerOnBoundDisplay {
        return .unmanaged
    }
    if let role = input.role, Classify.nonWindowRoles.contains(role) {
        return .unmanaged
    }
    // An off-screen window that is not minimized is a hidden tab, a twin on
    // another native Space, or a stale AX entry. Adopting it tiles a window
    // nobody can see and leaves a hole where a real window should be. The
    // agent unhides hidden apps and re-checks before adopting, so nothing
    // visible is lost here.
    if !input.isOnScreen && !input.isMinimized {
        return .ignored
    }

    var allowTiled = false
    for rule in rules {
        guard rule.matches(bundleId: input.bundleId, title: input.title) else { continue }
        switch rule.action {
        case .ignore:
            return .ignored
        case .float:
            return .floating
        case .tile:
            allowTiled = true
        }
    }

    if isHardFloat(input) {
        return .floating
    }

    let dialogRole = input.role.map(Classify.dialogRoles.contains) == true
    let dialogSubrole = input.subrole.map(Classify.dialogRoles.contains) == true
    if dialogRole || dialogSubrole {
        if !allowTiled { return .floating }
    }

    let isStandardWindow = input.subrole == AXRoleName.standardWindow
    if !allowTiled && !isTerminal(input.bundleId) {
        if !input.hasZoomButton && !isStandardWindow { return .floating }
        if input.width < 400 || input.height < 300 { return .floating }
    }

    return .tiled
}

private func isHardFloat(_ input: ClassifyInput) -> Bool {
    if let role = input.role, Classify.hardRoles.contains(role) { return true }
    if let sub = input.subrole, Classify.hardSubroles.contains(sub) { return true }
    if let bid = input.bundleId, Classify.hardFloatBundleIds.contains(bid) { return true }
    if input.isPiP || input.layerOrIsHUD || input.isVisualIntelligenceOrSiriHUD { return true }
    return false
}

private func isTerminal(_ bundleId: String?) -> Bool {
    guard let bundleId else { return false }
    return Classify.terminalBundleIds.contains(bundleId)
}

/// Center of `rect` inside the bound display's full AX frame (not usable).
public func centerOnDisplay(rect: Rect, displayFrame: Rect) -> Bool {
    displayFrame.contains(point: rect.center)
}

/// True when the window's center is on some other screen, not the bound display.
public func centerOnOtherDisplay(rect: Rect, bound: Rect, screens: [Rect]) -> Bool {
    if bound.contains(point: rect.center) { return false }
    return screens.contains { $0.contains(point: rect.center) }
}

/// Manage unless the window is clearly on a different display. Off-display leftovers stay eligible.
public func shouldManageOnBoundDisplay(rect: Rect, bound: Rect, screens: [Rect]) -> Bool {
    if bound.contains(point: rect.center) { return true }
    return !centerOnOtherDisplay(rect: rect, bound: bound, screens: screens)
}
