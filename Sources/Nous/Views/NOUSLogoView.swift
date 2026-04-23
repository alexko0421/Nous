import SwiftUI

struct NOUSLogoView: View {
    var logoColor: Color = AppColor.colaOrange

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let sx = w / 1400.0
            let sy = h / 900.0

            ZStack {
                // N
                Path { path in
                    path.move(to: CGPoint(x: 352 * sx, y: 460 * sy))
                    path.addLine(to: CGPoint(x: 352 * sx, y: 635 * sy))
                    path.addLine(to: CGPoint(x: 484 * sx, y: 635 * sy))
                    path.addLine(to: CGPoint(x: 484 * sx, y: 460 * sy))
                    path.addLine(to: CGPoint(x: 434 * sx, y: 460 * sy))
                    path.addLine(to: CGPoint(x: 434 * sx, y: 562 * sy))
                    path.addLine(to: CGPoint(x: 404 * sx, y: 528 * sy))
                    path.addLine(to: CGPoint(x: 352 * sx, y: 460 * sy))
                    path.closeSubpath()
                }
                .fill(logoColor)

                Circle()
                    .fill(logoColor)
                    .frame(width: 48 * sx, height: 48 * sy)
                    .position(x: 402 * sx, y: 592 * sy)

                // O (Drawn as a stroke to guarantee a perfect transparent hole)
                Circle()
                    .stroke(logoColor, lineWidth: 58 * min(sx, sy))
                    .frame(width: 182 * min(sx, sy), height: 182 * min(sx, sy))
                    .position(x: 742 * sx, y: 517 * sy)

                // U
                Path { path in
                    path.move(to: CGPoint(x: 938 * sx, y: 397 * sy))
                    path.addLine(to: CGPoint(x: 938 * sx, y: 553 * sy))

                    path.addCurve(
                        to: CGPoint(x: 1033 * sx, y: 648 * sy),
                        control1: CGPoint(x: 938 * sx, y: 605.467 * sy),
                        control2: CGPoint(x: 980.533 * sx, y: 648 * sy)
                    )

                    path.addCurve(
                        to: CGPoint(x: 1128 * sx, y: 553 * sy),
                        control1: CGPoint(x: 1085.47 * sx, y: 648 * sy),
                        control2: CGPoint(x: 1128 * sx, y: 605.467 * sy)
                    )

                    path.addLine(to: CGPoint(x: 1128 * sx, y: 397 * sy))
                    path.addLine(to: CGPoint(x: 1074 * sx, y: 397 * sy))
                    path.addLine(to: CGPoint(x: 1074 * sx, y: 553 * sy))

                    path.addCurve(
                        to: CGPoint(x: 1033 * sx, y: 594 * sy),
                        control1: CGPoint(x: 1074 * sx, y: 575.899 * sy),
                        control2: CGPoint(x: 1055.9 * sx, y: 594 * sy)
                    )

                    path.addCurve(
                        to: CGPoint(x: 992 * sx, y: 553 * sy),
                        control1: CGPoint(x: 1010.1 * sx, y: 594 * sy),
                        control2: CGPoint(x: 992 * sx, y: 575.899 * sy)
                    )

                    path.addLine(to: CGPoint(x: 992 * sx, y: 397 * sy))
                    path.addLine(to: CGPoint(x: 938 * sx, y: 397 * sy))
                    path.closeSubpath()
                }
                .fill(logoColor)

                // U Hole Cutout (erases the U shape)
                Circle()
                    .fill(Color.black)
                    .frame(width: 96 * sx, height: 96 * sy)
                    .position(x: 1033 * sx, y: 567 * sy)
                    .blendMode(.destinationOut)

                // U Inner Dot
                Circle()
                    .fill(logoColor)
                    .frame(width: 48 * sx, height: 48 * sy)
                    .position(x: 1033 * sx, y: 567 * sy)

                // S
                Path { path in
                    path.move(to: CGPoint(x: 1337 * sx, y: 397 * sy))
                    path.addLine(to: CGPoint(x: 1252 * sx, y: 397 * sy))

                    path.addCurve(
                        to: CGPoint(x: 1222 * sx, y: 427 * sy),
                        control1: CGPoint(x: 1235.43 * sx, y: 397 * sy),
                        control2: CGPoint(x: 1222 * sx, y: 410.431 * sy)
                    )

                    path.addLine(to: CGPoint(x: 1222 * sx, y: 481 * sy))

                    path.addCurve(
                        to: CGPoint(x: 1270 * sx, y: 529 * sy),
                        control1: CGPoint(x: 1222 * sx, y: 507.51 * sy),
                        control2: CGPoint(x: 1243.49 * sx, y: 529 * sy)
                    )

                    path.addLine(to: CGPoint(x: 1320 * sx, y: 529 * sy))

                    path.addCurve(
                        to: CGPoint(x: 1336 * sx, y: 545 * sy),
                        control1: CGPoint(x: 1328.84 * sx, y: 529 * sy),
                        control2: CGPoint(x: 1336 * sx, y: 536.163 * sy)
                    )

                    path.addLine(to: CGPoint(x: 1336 * sx, y: 573 * sy))

                    path.addCurve(
                        to: CGPoint(x: 1320 * sx, y: 589 * sy),
                        control1: CGPoint(x: 1336 * sx, y: 581.837 * sy),
                        control2: CGPoint(x: 1328.84 * sx, y: 589 * sy)
                    )

                    path.addLine(to: CGPoint(x: 1228 * sx, y: 589 * sy))
                    path.addLine(to: CGPoint(x: 1228 * sx, y: 647 * sy))
                    path.addLine(to: CGPoint(x: 1337 * sx, y: 647 * sy))

                    path.addCurve(
                        to: CGPoint(x: 1377 * sx, y: 607 * sy),
                        control1: CGPoint(x: 1359.09 * sx, y: 647 * sy),
                        control2: CGPoint(x: 1377 * sx, y: 629.091 * sy)
                    )

                    path.addLine(to: CGPoint(x: 1377 * sx, y: 577 * sy))

                    path.addCurve(
                        to: CGPoint(x: 1310 * sx, y: 510 * sy),
                        control1: CGPoint(x: 1377 * sx, y: 540 * sy),
                        control2: CGPoint(x: 1347 * sx, y: 510 * sy)
                    )

                    path.addLine(to: CGPoint(x: 1268 * sx, y: 510 * sy))

                    path.addCurve(
                        to: CGPoint(x: 1256 * sx, y: 498 * sy),
                        control1: CGPoint(x: 1261.37 * sx, y: 510 * sy),
                        control2: CGPoint(x: 1256 * sx, y: 504.627 * sy)
                    )

                    path.addLine(to: CGPoint(x: 1256 * sx, y: 467 * sy))

                    path.addCurve(
                        to: CGPoint(x: 1268 * sx, y: 455 * sy),
                        control1: CGPoint(x: 1256 * sx, y: 460.373 * sy),
                        control2: CGPoint(x: 1261.37 * sx, y: 455 * sy)
                    )

                    path.addLine(to: CGPoint(x: 1337 * sx, y: 455 * sy))
                    path.closeSubpath()
                }
                .fill(logoColor)
            }
            .compositingGroup() // Ensure destinationOut only applies within this logo
        }
        .aspectRatio(1400/900, contentMode: .fit)
    }
}
