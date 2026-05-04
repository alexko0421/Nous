import SwiftUI
import AppKit

final class WindowConfigurationCoordinator {
    private weak var configuredWindow: NSWindow?

    func shouldConfigure(_ window: NSWindow) -> Bool {
        configuredWindow !== window
    }

    func markConfigured(_ window: NSWindow) {
        configuredWindow = window
    }
}

enum AppAppearanceMode {
    static func preferredColorScheme(for rawValue: String) -> ColorScheme? {
        switch rawValue {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    static func nsAppearanceName(for rawValue: String) -> NSAppearance.Name? {
        switch rawValue {
        case "light": return .aqua
        case "dark": return .darkAqua
        default: return nil
        }
    }

    @MainActor
    static func apply(_ rawValue: String, to window: NSWindow) {
        window.appearance = nsAppearanceName(for: rawValue).flatMap(NSAppearance.init(named:))
    }
}

struct WindowAppearanceBridge: NSViewRepresentable {
    let appearanceMode: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        applyAppearance(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyAppearance(from: nsView)
    }

    private func applyAppearance(from view: NSView) {
        let appearanceMode = appearanceMode
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            AppAppearanceMode.apply(appearanceMode, to: window)
        }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> WindowConfigurationCoordinator {
        WindowConfigurationCoordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindowIfNeeded(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindowIfNeeded(from: nsView, coordinator: context.coordinator)
    }

    private func configureWindowIfNeeded(
        from view: NSView,
        coordinator: WindowConfigurationCoordinator
    ) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            guard coordinator.shouldConfigure(window) else { return }

            // Make window fully transparent so each component casts its own shaped shadow.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            // Keep .titled so window can become key (required for text input).
            // fullSizeContentView makes content extend under the invisible titlebar.
            window.styleMask.insert(.fullSizeContentView)

            // Nuke every layer background up the hierarchy.
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.backgroundColor = NSColor.clear.cgColor
                contentView.layer?.masksToBounds = false

                var current: NSView? = contentView
                while let v = current {
                    v.wantsLayer = true
                    v.layer?.backgroundColor = NSColor.clear.cgColor
                    current = v.superview
                }
            }

            // Ensure window is key for text input.
            window.makeKey()
            coordinator.markConfigured(window)
            NotificationCenter.default.post(name: .nousMainWindowConfigured, object: window)
        }
    }
}
