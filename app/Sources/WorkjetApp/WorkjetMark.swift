import SwiftUI

/// A front-facing turbofan silhouette for the menu bar.
struct WorkjetMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 256
        let offsetX = rect.midX - 128 * scale
        let offsetY = rect.midY - 128 * scale

        func sourcePoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offsetX + x * scale, y: offsetY + y * scale)
        }

        var result = Path()

        // Even-odd filling turns these concentric circles into the intake lip.
        result.addEllipse(in: CGRect(x: offsetX + 10 * scale, y: offsetY + 10 * scale, width: 236 * scale, height: 236 * scale))
        result.addEllipse(in: CGRect(x: offsetX + 38 * scale, y: offsetY + 38 * scale, width: 180 * scale, height: 180 * scale))

        // One swept compressor blade, repeated around the central shaft.
        var blade = Path()
        blade.move(to: sourcePoint(128, 108))
        blade.addCurve(
            to: sourcePoint(111, 49),
            control1: sourcePoint(101, 83),
            control2: sourcePoint(98, 59)
        )
        blade.addCurve(
            to: sourcePoint(143, 108),
            control1: sourcePoint(135, 61),
            control2: sourcePoint(145, 84)
        )
        blade.closeSubpath()

        for step in 0..<8 {
            let angle = CGFloat(step) * .pi / 4
            let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: angle)
                .translatedBy(x: -rect.midX, y: -rect.midY)
            result.addPath(blade, transform: transform)
        }

        result.addEllipse(in: CGRect(
            x: offsetX + 106 * scale,
            y: offsetY + 106 * scale,
            width: 44 * scale,
            height: 44 * scale
        ))

        return result
    }
}
