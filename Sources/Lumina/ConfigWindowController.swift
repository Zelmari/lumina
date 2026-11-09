#if os(macOS)
import AppKit
import SwiftUI
import LuminaLayout

/// The menu extra owns the editor; agents consume the resulting TOML file.
@MainActor
final class ConfigWindowController: NSWindowController {
    private let store: ConfigEditorStore

    init(path: String, openFile: @escaping () -> Void) {
        let store = ConfigEditorStore(path: path)
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 670),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Lumina Config"
        window.identifier = NSUserInterfaceItemIdentifier("lumina-config")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 520)
        window.contentViewController = NSHostingController(rootView: ConfigEditorView(store: store, openFile: openFile))
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show() {
        store.refreshFromDisk()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func updateRuntimeStatus(_ text: String) { store.runtimeStatus = text }
    func updateShortcutError(_ text: String?) { store.shortcutError = text }
}

@MainActor
final class ConfigEditorStore: ObservableObject {
    let path: String
    @Published var draft = ""
    @Published var config = Config.bundledDefault
    @Published var shortcut = ""
    @Published var launchApps = ""
    @Published var nativeTabs = ""
    @Published var hiddenApps = ""
    @Published var status = "Loading…"
    @Published var error: String?
    @Published var conflict = false
    @Published var runtimeStatus = "Agents watch this file and reload saved changes automatically."
    @Published var shortcutError: String?
    private var baseline: String?
    private var saveTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var dirty = false

    init(path: String) {
        self.path = path
        reloadFromDisk()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self else { return }
                self.refreshFromDisk()
            }
        }
    }

    deinit { saveTask?.cancel(); watchTask?.cancel() }

    func refreshFromDisk() {
        do {
            let latest = try String(contentsOfFile: path, encoding: .utf8)
            guard latest != baseline else { return }
            if dirty {
                conflict = true
                saveTask?.cancel()
                status = "The file changed outside this window. Your edits have not been saved."
            } else {
                load(latest)
            }
        } catch {
            self.error = "Cannot read config: \(error.localizedDescription)"
        }
    }

    func reloadFromDisk() {
        saveTask?.cancel()
        do { load(try String(contentsOfFile: path, encoding: .utf8)) }
        catch { self.error = "Cannot read config: \(error.localizedDescription)" }
    }

    private func load(_ text: String) {
        baseline = text
        draft = text
        dirty = false
        conflict = false
        status = "Loaded from file"
        validateAndHydrate()
    }

    private func validateAndHydrate() {
        switch parseConfig(text: draft, defaults: .bundledDefault) {
        case .success(let parsed):
            let rejected = parsed.diagnostics.filter { !$0.hasPrefix("unknown key:") }
            guard rejected.isEmpty else {
                error = rejected.joined(separator: "\n")
                return
            }
            config = parsed
            shortcut = parsed.configShortcut
            launchApps = parsed.launchApps.joined(separator: "\n")
            nativeTabs = parsed.nativeTabs.joined(separator: "\n")
            hiddenApps = parsed.hideUntilTiledApps.joined(separator: "\n")
            error = nil
        case .failure(let failure): error = failure.description
        }
    }

    func restoreDefaults() {
        editRaw(Config.bundledDefaultTOML)
    }

    func editRaw(_ text: String) {
        draft = text
        validateAndHydrate()
        scheduleSave()
    }

    func set(_ key: String, table: String? = nil, literal: String) {
        do {
            draft = try ConfigDocument(text: draft).setting(literal, for: ConfigField(key, table: table))
            validateAndHydrate()
            scheduleSave()
        } catch { self.error = String(describing: error) }
    }

    func editShortcut(_ text: String) {
        set("config-shortcut", literal: ConfigDocument.quote(text))
        shortcut = text
    }

    func editApps(_ key: String, table: String? = nil, text: String) {
        let apps = text.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let literal = "[" + apps.map { ConfigDocument.quote($0) }.joined(separator: ", ") + "]"
        set(key, table: table, literal: literal)
        // Preserve the user's in-progress trailing newline while typing.
        if table == "native-tabs" { nativeTabs = text }
        else if key == "launch-apps" { launchApps = text }
        else { hiddenApps = text }
    }

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        guard !conflict else { return }
        guard error == nil else { status = "Fix validation errors to save"; return }
        status = "Unsaved changes…"
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        guard dirty, !conflict, error == nil else { return }
        do {
            let latest = try String(contentsOfFile: path, encoding: .utf8)
            guard latest == baseline else {
                conflict = true
                status = "The file changed outside this window. Your edits have not been saved."
                return
            }
            // Serialized on the main actor; Foundation replaces the complete file atomically.
            try draft.write(toFile: path, atomically: true, encoding: .utf8)
            baseline = draft
            dirty = false
            status = "Saved to file · agent reload pending"
        } catch { self.error = "Cannot save config: \(error.localizedDescription)"; status = "Changes have not been saved" }
    }
}

@MainActor
private struct ConfigEditorView: View {
    @ObservedObject var store: ConfigEditorStore
    let openFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TabView {
                general.tabItem { Text("General") }
                applications.tabItem { Text("Applications") }
                VStack(alignment: .leading) {
                    Text("Edit bindings, window rules, and advanced options here. Valid changes save automatically; comments and unknown keys remain in the file.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: SwiftUI.Binding(get: { store.draft }, set: { store.editRaw($0) }))
                        .font(.system(.body, design: .monospaced))
                        .border(Color.secondary.opacity(0.3))
                }.padding().tabItem { Text("Advanced TOML") }
            }
            if let error = store.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let error = store.shortcutError { Text(error).foregroundStyle(.orange) }
            if store.conflict {
                HStack {
                    Text("Reload the file to discard unsaved edits, or copy your TOML first.").font(.callout)
                    Spacer()
                    Button("Reload File", action: { store.reloadFromDisk() })
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.status).font(.callout)
                    Text(store.runtimeStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Defaults", action: { store.restoreDefaults() })
                Button("Open Config File…", action: openFile)
            }
            Text(store.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(16)
    }

    private var general: some View {
        Form {
            Stepper("Workspaces: \(store.config.spaceCount)", value: SwiftUI.Binding(get: { store.config.spaceCount }, set: { store.set("space-count", literal: String($0)) }), in: 1...10)
            Text("Reducing the workspace count moves windows from removed workspaces into the final remaining workspace.")
                .font(.caption).foregroundStyle(.secondary)
            toggle("Focus follows mouse", key: "focus-follows-mouse", value: store.config.focusFollowsMouse)
            toggle("Park new windows before tiling", key: "pre-park-new-windows", value: store.config.preParkNewWindows)
            toggle("Predict new window tiles", key: "speculative-tile", value: store.config.speculativeTile)
            Picker("Existing windows at launch", selection: SwiftUI.Binding(get: { store.config.launchTiling.rawValue }, set: { store.set("launch-tiling", literal: ConfigDocument.quote($0)) })) {
                Text("Tile in stacking order").tag("z-order")
                Text("Float existing windows").tag("float-existing")
                Text("Only tile new windows").tag("new-only")
            }
            Stepper("Inner gap: \(store.config.gaps.inner)", value: SwiftUI.Binding(get: { Int(store.config.gaps.inner) }, set: { store.set("inner", table: "gaps", literal: String($0)) }), in: 0...128)
            Stepper("Outer gap: \(store.config.gaps.outer)", value: SwiftUI.Binding(get: { Int(store.config.gaps.outer) }, set: { store.set("outer", table: "gaps", literal: String($0)) }), in: 0...128)
            TextField("Open Config shortcut", text: SwiftUI.Binding(get: { store.shortcut }, set: { store.editShortcut($0) }))
            Text("Use chord names such as ctrl-alt-space. Changes save after 300 ms. Layout and binding changes reload automatically; launch options affect the next launch.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }

    private func toggle(_ title: String, key: String, value: Bool) -> some View {
        Toggle(title, isOn: SwiftUI.Binding(get: { value }, set: { store.set(key, literal: $0 ? "true" : "false") }))
    }

    private var applications: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter one application bundle ID per line, for example com.apple.Terminal.").font(.callout).foregroundStyle(.secondary)
                appList("Launch at startup", text: SwiftUI.Binding(get: { store.launchApps }, set: { store.editApps("launch-apps", text: $0) }))
                appList("Native tab applications", text: SwiftUI.Binding(get: { store.nativeTabs }, set: { store.editApps("apps", table: "native-tabs", text: $0) }))
                appList("Hide until first window is tiled", text: SwiftUI.Binding(get: { store.hiddenApps }, set: { store.editApps("hide-until-tiled-apps", text: $0) }))
            }.padding()
        }
    }

    private func appList(_ title: String, text: SwiftUI.Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            TextEditor(text: text).font(.system(.body, design: .monospaced)).frame(height: 90).border(Color.secondary.opacity(0.3))
        }
    }
}
#endif
