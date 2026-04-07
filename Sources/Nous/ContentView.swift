import SwiftUI

struct ContentView: View {
    @State private var isSidebarVisible = true
    
    var body: some View {
        HStack(spacing: 20) {
            if isSidebarVisible {
                LeftSidebar()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            
            ChatArea(isSidebarVisible: $isSidebarVisible)
        }
        .frame(width: 800, height: 600)
        .background(.clear)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSidebarVisible)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
