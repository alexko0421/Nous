import SwiftUI
import AppKit

@main
struct NousApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Make window fully transparent so each component casts its own shaped shadow
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false  // Each SwiftUI component has .shadow() following its own clipShape
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            
            // Remove all window chrome
            window.styleMask.remove(.titled)
            window.styleMask.insert(.fullSizeContentView)
            
            // Nuke every layer background up the hierarchy
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.backgroundColor = NSColor.clear.cgColor
                contentView.layer?.masksToBounds = false
                
                var view: NSView? = contentView
                while let v = view {
                    v.wantsLayer = true
                    v.layer?.backgroundColor = NSColor.clear.cgColor
                    view = v.superview
                }
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}
