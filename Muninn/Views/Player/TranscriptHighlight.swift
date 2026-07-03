import SwiftUI

/// Apple Podcasts–style word highlight: whole word fades from dim to bright over its spoken duration.
enum TranscriptHighlight {
    /// Fade-in progress (0→1) across the word's timed window, eased with smoothstep.
    static func fadeProgress(playbackTime: TimeInterval, start: TimeInterval, end: TimeInterval) -> CGFloat {
        let duration = max(end - start, 0.08)
        let linear = min(max((playbackTime - start) / duration, 0), 1)
        // Smoothstep — soft attack, no harsh snap at word boundaries.
        return CGFloat(linear * linear * (3 - 2 * linear))
    }

    static func color(playbackTime: TimeInterval, segment: TranscriptSegment) -> Color {
        if segment.endTime < playbackTime {
            return Color(UIColor.label)
        }
        if playbackTime < segment.startTime {
            return Color(UIColor.tertiaryLabel)
        }
        let progress = fadeProgress(
            playbackTime: playbackTime,
            start: segment.startTime,
            end: segment.endTime
        )
        return Color(uiColor: fadeUpUIColor(progress: progress))
    }

    private static func fadeUpUIColor(progress: CGFloat) -> UIColor {
        UIColor { traits in
            let from = UIColor.tertiaryLabel.resolvedColor(with: traits)
            let to = UIColor.label.resolvedColor(with: traits)
            return blend(from, to, progress)
        }
    }

    private static func blend(_ from: UIColor, _ to: UIColor, _ progress: CGFloat) -> UIColor {
        let t = min(max(progress, 0), 1)
        guard let fromRGB = rgba(from), let toRGB = rgba(to) else {
            return t < 0.5 ? from : to
        }
        return UIColor(
            red: fromRGB.r + (toRGB.r - fromRGB.r) * t,
            green: fromRGB.g + (toRGB.g - fromRGB.g) * t,
            blue: fromRGB.b + (toRGB.b - fromRGB.b) * t,
            alpha: fromRGB.a + (toRGB.a - fromRGB.a) * t
        )
    }

    private static func rgba(_ color: UIColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        guard let components = color.cgColor.converted(
            to: CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        )?.components, components.count >= 3 else { return nil }
        let a = components.count > 3 ? components[3] : 1
        return (components[0], components[1], components[2], a)
    }
}
