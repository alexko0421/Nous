import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)

            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            // Clear content view background only
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.backgroundColor = NSColor.clear.cgColor
            }

            // Remove the entire titlebar container — kills the 1px ghost line permanently
            if let titlebarContainer = window.standardWindowButton(.closeButton)?.superview?.superview {
                titlebarContainer.removeFromSuperview()
            }

            window.makeKey()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
