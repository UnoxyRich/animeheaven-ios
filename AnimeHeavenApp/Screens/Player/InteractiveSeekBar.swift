import Observation
import SwiftUI
import AnimeHeavenCore

/// Isolated observable holder updated at 2 Hz so root `PlayerView` never recomposes on ticks.
@MainActor
@Observable
final class PlayerProgressModel {
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0
    var bufferedMs: Int64 = 0
}

struct InteractiveSeekBar: View {
    let progress: PlayerProgressModel
    let accentColor: Color
    let onSeekCommitted: (Int64) -> Void
    let onScrubbingChanged: (Bool) -> Void

    @State private var isDragging = false
    @State private var dragFraction: Double = 0

    var body: some View {
        let dur = max(1, progress.durationMs)
        let playedFraction = isDragging
            ? dragFraction
            : min(1.0, max(0.0, Double(progress.positionMs) / Double(dur)))
        let bufferedFraction = min(1.0, max(0.0, Double(progress.bufferedMs) / Double(dur)))
        let displayPosMs = isDragging ? Int64(dragFraction * Double(dur)) : progress.positionMs

        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = max(1, geo.size.width)
                ZStack {
                    Canvas { ctx, size in
                        let trackHeight: CGFloat = isDragging ? 6 : 4
                        let centerY = size.height / 2
                        let y = centerY - trackHeight / 2
                        let corner = CGSize(width: trackHeight / 2, height: trackHeight / 2)

                        let bgRect = CGRect(x: 0, y: y, width: size.width, height: trackHeight)
                        ctx.fill(Path(roundedRect: bgRect, cornerSize: corner), with: .color(.white.opacity(0.28)))

                        let bufW = size.width * bufferedFraction
                        if bufW > 0 {
                            let bufRect = CGRect(x: 0, y: y, width: bufW, height: trackHeight)
                            ctx.fill(Path(roundedRect: bufRect, cornerSize: corner), with: .color(.white.opacity(0.45)))
                        }

                        let playW = size.width * playedFraction
                        if playW > 0 {
                            let playRect = CGRect(x: 0, y: y, width: playW, height: trackHeight)
                            ctx.fill(Path(roundedRect: playRect, cornerSize: corner), with: .color(accentColor))
                        }

                        let thumbRadius: CGFloat = isDragging ? 9 : 6.5
                        let thumbX = min(max(thumbRadius, playW), size.width - thumbRadius)
                        let thumbRect = CGRect(
                            x: thumbX - thumbRadius,
                            y: centerY - thumbRadius,
                            width: thumbRadius * 2,
                            height: thumbRadius * 2
                        )
                        ctx.fill(Path(ellipseIn: thumbRect), with: .color(.white))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                onScrubbingChanged(true)
                            }
                            dragFraction = min(1.0, max(0.0, value.location.x / width))
                        }
                        .onEnded { value in
                            let finalFrac = min(1.0, max(0.0, value.location.x / width))
                            let targetMs = Int64(finalFrac * Double(progress.durationMs))
                            isDragging = false
                            onScrubbingChanged(false)
                            onSeekCommitted(targetMs)
                        }
                )
            }
            .frame(height: 28)

            HStack {
                Text(DurationFormatter.format(ms: displayPosMs))
                Spacer()
                Text(DurationFormatter.format(ms: progress.durationMs))
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white.opacity(0.88))
        }
    }
}
