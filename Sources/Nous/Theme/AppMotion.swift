import SwiftUI

struct AppSpringMotion: Equatable {
    let response: Double
    let dampingFraction: Double
    let blendDuration: Double

    var animation: Animation {
        .spring(
            response: response,
            dampingFraction: dampingFraction,
            blendDuration: blendDuration
        )
    }
}

enum AppMotion {
    static let sidePanelSpring = AppSpringMotion(
        response: 0.4,
        dampingFraction: 0.8,
        blendDuration: 0
    )

    static let sidebarPanelSpring = sidePanelSpring
    static let markdownPanelSpring = sidePanelSpring
}
