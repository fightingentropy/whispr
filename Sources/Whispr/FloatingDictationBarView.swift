import SwiftUI

struct FloatingDictationBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            glowingMicDot
            SpectrumBars(level: CGFloat(appState.liveInputLevel))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.93))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
        }
        .padding(1)
    }

    private var glowingMicDot: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.9 + (sin(time * 3.2) * 0.1)

            ZStack {
                Circle()
                    .fill(Color(red: 0.23, green: 0.67, blue: 1.0).opacity(0.35))
                    .frame(width: 22 * pulse, height: 22 * pulse)
                    .blur(radius: 2)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.55, green: 0.82, blue: 1.0),
                                Color(red: 0.23, green: 0.67, blue: 1.0)
                            ],
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: 14
                        )
                    )
                    .frame(width: 19, height: 19)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                    }
            }
            .frame(width: 24, height: 24)
        }
    }
}

private struct SpectrumBars: View {
    let level: CGFloat
    private let barCount = 11
    @State private var renderedLevel: CGFloat = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0.72),
                                    Color.white.opacity(0.35)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 3, height: barHeight(index: index, time: time))
                }
            }
            .frame(width: 108, height: 24, alignment: .center)
            .animation(.linear(duration: 1.0 / 30.0), value: renderedLevel)
        }
        .onAppear {
            renderedLevel = max(0, min(1, level))
        }
        .onChange(of: level) { _, newValue in
            let clamped = max(0, min(1, newValue))
            let boosted = pow(clamped, 0.58)
            let rise: CGFloat = 0.5
            let fall: CGFloat = 0.2
            let smoothing = boosted > renderedLevel ? rise : fall
            renderedLevel += (boosted - renderedLevel) * smoothing
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center)
        let centerWeight = max(0.2, 1.0 - (distance / center))

        let reactiveLevel = Double(max(0, min(1, renderedLevel)))
        let slowWave = sin(time * 2.6 + Double(index) * 0.4) * 0.5 + 0.5
        let fastWave = sin(time * 12.0 + Double(index) * 1.9 + 0.4) * 0.5 + 0.5

        let baseline = 2.6 + (2.2 * centerWeight)
        if reactiveLevel < 0.03 {
            let idleHeight = baseline + (slowWave * 1.6 * centerWeight)
            return CGFloat(min(22, max(2.4, idleHeight)))
        }

        let dynamicWave = (fastWave * 0.72) + (slowWave * 0.28)
        let amplitude = (5.0 + (16.0 * reactiveLevel)) * centerWeight
        let height = baseline + (amplitude * (0.48 + dynamicWave))
        return CGFloat(min(22, max(2.4, height)))
    }
}
