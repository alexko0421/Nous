import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Make window fully transparent so each component casts its own shaped shadow
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            // Keep .titled so window can become key (required for text input).
            // fullSizeContentView makes content extend under the invisible titlebar.
            window.styleMask.insert(.fullSizeContentView)

            // Nuke every layer background up the hierarchy
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.backgroundColor = NSColor.clear.cgColor
                contentView.layer?.masksToBounds = false

                var current: NSView? = contentView
                while let v = current {
                    v.wantsLayer = true
                    v.layer?.backgroundColor = NSColor.clear.cgColor
                    
                    // Nuke any titlebar container or separator subviews to fix the 1px top line
                    let className = String(describing: type(of: v))
                    if className.contains("Titlebar") || className.contains("Separator") {
                        v.isHidden = true
                    }
                    for sub in v.subviews {
                        let subClassName = String(describing: type(of: sub))
                        if subClassName.contains("Titlebar") || subClassName.contains("Separator") {
                            sub.isHidden = true
                        }
                    }
                    
                    current = v.superview
                }
            }

            // Ensure window is key for text input
            window.makeKey()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
