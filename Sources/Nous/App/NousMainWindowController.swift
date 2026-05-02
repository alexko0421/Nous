import AppKit
import SwiftUI

@MainActor
final class NousMainWindowController {
    static let defaultSize = NSSize(width: 790, height: 650)
    static let minimumSize = NSSize(width: 760, height: 600)

    private let window: NSWindow
    private var didCenterWindow = false

    convenience init(environment: AppEnvironment) {
        self.init(
            rootView: ContentView(env: environment)
                .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        )
    }

    convenience init<Root: View>(rootView: Root) {
        self.init(rootView: rootView, window: Self.makeWindow())
    }

    init<Root: View>(rootView: Root, window: NSWindow) {
        self.window = window
        install(rootView: rootView, in: window)
    }

    static func makeWindow() -> NSWindow {
        let window = NousMainWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        configure(window)
        return window
    }

    func show() {
        if !didCenterWindow {
            window.center()
            didCenterWindow = true
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .nousMainWindowConfigured, object: window)
    }

    private static func configure(_ window: NSWindow) {
        window.title = "Nous"
        window.minSize = minimumSize
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isRestorable = false
        window.restorationClass = nil
        window.identifier = nil
        window.isMovableByWindowBackground = true
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    private func install<Root: View>(rootView: Root, in window: NSWindow) {
        let hostingView = NousMainHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        window.contentView = container
    }
}

final class NousMainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class NousMainHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { .init() }
}
