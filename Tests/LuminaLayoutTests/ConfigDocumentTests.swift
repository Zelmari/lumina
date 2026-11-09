import Foundation
import Foundation
import Testing
@testable import LuminaLayout

struct ConfigDocumentTests {
    @Test func preservesUneditedTextAndInlineComments() throws {
        let original = "# user settings\nspace-count = 8  # desk count\nunknown = 'keep'\n[gaps] # layout\ninner = 8 # tiles\nouter = 12\n"
        let changed = try ConfigDocument(text: original).setting("4", for: ConfigField("inner", table: "gaps"))
        #expect(changed == original.replacingOccurrences(of: "inner = 8", with: "inner = 4"))
        #expect(try ConfigDocument(text: changed).value(for: ConfigField("inner", table: "gaps")) == "4")
    }

    @Test func insertsInCorrectScope() throws {
        let original = "space-count = 8\n[gaps]\ninner = 6\n[[window-rule]]\napp-id = 'com.test'\naction = 'float'\n"
        let withTop = try ConfigDocument(text: original).setting("true", for: ConfigField("focus-follows-mouse"))
        #expect(withTop.hasPrefix("focus-follows-mouse = true\nspace-count"))
        let withGap = try ConfigDocument(text: original).setting("15", for: ConfigField("outer", table: "gaps"))
        let config = try parseConfig(text: withGap).get()
        #expect(config.gaps.outer == 15)
        #expect(config.windowRules.count == 1)
        let withNew = try ConfigDocument(text: original).setting("[]", for: ConfigField("apps", table: "native-tabs"))
        #expect(withNew.hasSuffix("[native-tabs]\napps = []\n"))
    }

    @Test func replacesMultilineArrayWithoutTouchingNextTable() throws {
        let original = "launch-apps = [\n  'com.one', # first app\n  'com.two',\n] # launch list\n[gaps]\ninner = 7\n"
        let changed = try ConfigDocument(text: original).setting("[\"com.new\"]", for: ConfigField("launch-apps"))
        #expect(changed == "launch-apps = [\"com.new\"] # launch list\n[gaps]\ninner = 7\n")
    }

    @Test func rejectsAmbiguousSpellingsAndInvalidValues() {
        for text in ["'space-count' = 5\n", "space-count = 5\nspace-count = 6\n"] {
            #expect(throws: ConfigError.self) { try ConfigDocument(text: text).setting("8", for: ConfigField("space-count")) }
        }
        for text in ["gaps.inner = 8\n", "gaps = { inner = 8 }\n", "['gaps']\ninner = 8\n"] {
            #expect(throws: ConfigError.self) { try ConfigDocument(text: text).setting("4", for: ConfigField("inner", table: "gaps")) }
        }
        #expect(throws: ConfigError.self) { try ConfigDocument(text: "").setting("0", for: ConfigField("space-count")) }
    }

    @Test func quoteRoundTripsSpecialCharacters() throws {
        let value = "com.\\test\"\n\t\u{01}"
        let text = "launch-apps = [\(ConfigDocument.quote(value))]"
        #expect(try parseConfig(text: text).get().launchApps == [value])
    }

    @Test func quotedHashAndEqualsAreNotSyntax() throws {
        let text = "launch-apps = ['com.#equals=app'] # keep\nspace-count = 8\n"
        let doc = ConfigDocument(text: text)
        #expect(try doc.value(for: ConfigField("launch-apps")) == "['com.#equals=app']")
        #expect(try doc.setting("5", for: ConfigField("space-count")).contains("['com.#equals=app'] # keep"))
    }

    @Test func leavesUnrelatedMultilineStringsAlone() throws {
        let text = "unknown = \"\"\"a\n[gaps]\nspace-count = 1\n\"\"\"\nspace-count = 8\n"
        #expect(try ConfigDocument(text: text).setting("4", for: ConfigField("space-count")) == text.replacingOccurrences(of: "space-count = 8", with: "space-count = 4"))
    }

    @Test func preservesCRLFOnExistingValues() throws {
        let text = "space-count = 8\r\n[gaps]\r\ninner = 4 # keep\r\n"
        #expect(try ConfigDocument(text: text).setting("6", for: ConfigField("inner", table: "gaps")) == text.replacingOccurrences(of: "inner = 4", with: "inner = 6"))
    }

    @Test func rejectsQuotedTableInsteadOfAddingDuplicate() {
        let text = "['gaps'] # layout\ninner = 8\n"
        #expect(throws: ConfigError.self) { try ConfigDocument(text: text).setting("4", for: ConfigField("inner", table: "gaps")) }
    }

    @Test func tracksExternalFieldChanges() throws {
        let field = ConfigField("inner", table: "gaps")
        let baseline = ConfigDocument(text: "[gaps]\ninner = 8\nouter = 4\n")
        let unrelated = ConfigDocument(text: "[gaps]\ninner = 8\nouter = 5\n")
        let conflict = ConfigDocument(text: "[gaps]\ninner = 9\nouter = 4\n")
        #expect(try baseline.value(for: field) == unrelated.value(for: field))
        #expect(try baseline.value(for: field) != conflict.value(for: field))
    }
}
