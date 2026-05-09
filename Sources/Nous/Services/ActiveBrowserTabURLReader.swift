import AppKit

protocol ActiveBrowserTabURLReading {
    func currentActiveBrowserURL() -> String?
}

struct ActiveBrowserTabURLReader: ActiveBrowserTabURLReading {
    var frontmostBundleIdentifier: () -> String?
    var runScript: (String) -> String?

    init(
        frontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        runScript: @escaping (String) -> String? = ActiveBrowserTabURLReader.runAppleScript(_:)
    ) {
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.runScript = runScript
    }

    func currentActiveBrowserURL() -> String? {
        guard let bundleIdentifier = frontmostBundleIdentifier(),
              let script = ActiveBrowserTabURLScript.script(for: bundleIdentifier),
              let output = runScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }

        return output
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return output?.stringValue
    }
}

enum ActiveBrowserTabURLScript {
    private static let safariBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview"
    ]

    private static let chromiumBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi"
    ]

    static func script(for bundleIdentifier: String) -> String? {
        if safariBundleIdentifiers.contains(bundleIdentifier) {
            return """
            tell application id "\(bundleIdentifier)"
                return URL of current tab of front window
            end tell
            """
        }

        if chromiumBundleIdentifiers.contains(bundleIdentifier) {
            return """
            tell application id "\(bundleIdentifier)"
                return URL of active tab of front window
            end tell
            """
        }

        return nil
    }
}
