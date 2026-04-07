import SwiftUI

// Helper for window controls
func getAppWindow() -> NSWindow? {
    NSApplication.shared.windows.first(where: { $0.titleVisibility == .hidden }) 
        ?? NSApplication.shared.keyWindow 
        ?? NSApplication.shared.windows.first
}

// Galaxy Icon - clean port of the React reference
struct GalaxyIcon: View {
    let color: Color
    var body: some View {
        ZStack {
            // Two tiny stardust dots
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 2, height: 2)
                .offset(x: -7, y: -7)
            Circle()
                .fill(color.opacity(0.25))
                .frame(width: 1.5, height: 1.5)
                .offset(x: 8, y: 5)

            // Central planet body (stroked circle)
            Circle()
                .stroke(color, lineWidth: 1.5)
                .frame(width: 10, height: 10)

            // Ring (stroked ellipse, rotated -20°)
            Ellipse()
                .stroke(color.opacity(0.85), lineWidth: 1.5)
                .frame(width: 20, height: 6)
                .rotationEffect(.degrees(-20))
        }
        .frame(width: 22, height: 22)
    }
}

// Project Icon - clean 'stacked tray' design
struct ProjectIcon: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let r: CGFloat = 3.5
            let lw: CGFloat = 1.5

            // Outer rounded rect
            let outerRect = CGRect(x: 2, y: 4, width: w - 4, height: h - 6)
            ctx.stroke(
                Path(roundedRect: outerRect, cornerRadius: r),
                with: .color(color),
                lineWidth: lw
            )

            // Inner shelf — a strong horizontal line 1/3 down from top
            let shelfY = outerRect.minY + outerRect.height * 0.38
            var shelf = Path()
            shelf.move(to: CGPoint(x: outerRect.minX, y: shelfY))
            shelf.addLine(to: CGPoint(x: outerRect.maxX, y: shelfY))
            ctx.stroke(shelf, with: .color(color), lineWidth: lw)
        }
        .frame(width: 22, height: 22)
    }
}

struct NavIconButton<Icon: View>: View {
    let icon: Icon
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(AppColor.colaDarkText.opacity(0.04))
                    .frame(width: 44, height: 44)
                    .overlay(icon)
                
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
    }
}

struct MacOSTrafficLights: View {
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Close
            trafficLightButton(
                color: Color(red: 255/255, green: 95/255, blue: 86/255),
                icon: "xmark",
                iconSize: 7,
                action: { 
                    getAppWindow()?.close() 
                    // Safely exit app if it's the only window
                    NSApplication.shared.terminate(nil)
                }
            )
            
            // Minimize
            trafficLightButton(
                color: Color(red: 255/255, green: 189/255, blue: 46/255),
                icon: "minus",
                iconSize: 8,
                action: { getAppWindow()?.miniaturize(nil) }
            )
            
            // Zoom/Fullscreen
            trafficLightButton(
                color: Color(red: 39/255, green: 201/255, blue: 63/255),
                icon: "arrow.up.left.and.arrow.down.right",
                iconSize: 6,
                action: { getAppWindow()?.toggleFullScreen(nil) }
            )
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    @ViewBuilder
    func trafficLightButton(color: Color, icon: String, iconSize: CGFloat, action: @escaping () -> Void) -> some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundColor(.black.opacity(0.5))
                    .opacity(isHovered ? 1 : 0)
            )
            .onTapGesture {
                action()
            }
    }
}

struct LeftSidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            
            MacOSTrafficLights()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 24)
                .padding(.bottom, 30)


            // Top Nav: 星系网 & 项目 (并排)
            HStack(spacing: 12) {
                NavIconButton(
                    icon: GalaxyIcon(color: AppColor.colaDarkText.opacity(0.8)),
                    label: "Galaxy",
                    action: {}
                )
                
                NavIconButton(
                    icon: ProjectIcon(color: AppColor.colaDarkText.opacity(0.8)),
                    label: "Project",
                    action: {}
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 24)
            
            // 分割线
            Rectangle()
                .fill(AppColor.colaDarkText.opacity(0.1))
                .frame(width: 80, height: 1) // Smaller centered divider
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 24)
            
            // Recents / Favorities List
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    // Favorites Section
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 4) {
                            Text("Favorites")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .opacity(0.5)
                        }
                        .foregroundColor(AppColor.colaDarkText.opacity(0.6))
                        
                        ChatRecentItem(emoji: "🤠", title: "Austin攻略")
                        ChatRecentItem(emoji: "📘", title: "ESL10语法")
                    }
                    
                    // Recents Section
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Recents")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(AppColor.colaDarkText.opacity(0.6))
                        
                        ChatRecentItem(emoji: "🥦", title: "品牌理念")
                        ChatRecentItem(emoji: "🚀", title: "Doing Things")
                        ChatRecentItem(emoji: "💡", title: "产品定义")
                    }
                }
                .padding(.leading, 20)
                .padding(.trailing, 8)
            }
            
            Spacer()
            
            // 底部横向头像
            HStack(spacing: 12) {
                Circle()
                    .fill(AppColor.colaOrange.opacity(0.15))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Text("A")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(AppColor.colaOrange)
                    )
                
                Text("ALEX")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                
                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
            .padding(.bottom, 30)
        }
        .frame(width: 130)
        .background(Color.white.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

// 修改为横向布局的聊天记录项
struct ChatRecentItem: View {
    let emoji: String
    let title: String
    
    var body: some View {
        Button(action: {}) {
            HStack(spacing: 10) {
                Text(emoji)
                    .font(.system(size: 16))
                
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
