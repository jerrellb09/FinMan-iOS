import SwiftUI

/// Animated circular progress ring. Turns orange past `warning` and red past 100%.
struct RingGauge<Center: View>: View {
    let progress: Double
    var warning: Double = 0.8
    var lineWidth: CGFloat = 10
    var tint: Color?
    @ViewBuilder var center: () -> Center

    @State private var animated: Double = 0

    private var color: Color {
        if let tint { return tint }
        if progress >= 1 { return Theme.expense }
        if progress >= warning { return Theme.warning }
        return Theme.income
    }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(animated, 1))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
        .onAppear { withAnimation(.spring(duration: 1.0, bounce: 0.25).delay(0.1)) { animated = progress } }
        .onChange(of: progress) { _, new in withAnimation(.spring(duration: 0.8)) { animated = new } }
    }
}

extension RingGauge where Center == EmptyView {
    init(progress: Double, warning: Double = 0.8, lineWidth: CGFloat = 10, tint: Color? = nil) {
        self.init(progress: progress, warning: warning, lineWidth: lineWidth, tint: tint) { EmptyView() }
    }
}

/// Horizontal progress capsule with the same colour semantics as `RingGauge`.
struct ProgressCapsule: View {
    let progress: Double
    var warning: Double = 0.8
    var height: CGFloat = 10

    @State private var animated: Double = 0

    private var color: Color {
        if progress >= 1 { return Theme.expense }
        if progress >= warning { return Theme.warning }
        return Theme.income
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule().fill(color.gradient).frame(width: max(height, geo.size.width * min(animated, 1)))
            }
        }
        .frame(height: height)
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.2).delay(0.05)) { animated = progress } }
        .onChange(of: progress) { _, new in withAnimation(.spring) { animated = new } }
    }
}

/// Lightweight confetti burst driven by a trigger value.
struct ConfettiView: View {
    let trigger: Int

    @State private var pieces: [Piece] = []

    struct Piece: Identifiable {
        let id = UUID()
        let x: CGFloat
        let color: Color
        let rotation: Double
        let delay: Double
        let size: CGFloat
        let drift: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { piece in
                    ConfettiPiece(piece: piece, height: geo.size.height)
                        .position(x: piece.x * geo.size.width, y: -20)
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onChange(of: trigger) {
            let colors: [Color] = [.pink, .purple, .orange, .yellow, .mint, .blue, Theme.income]
            pieces = (0..<70).map { _ in
                Piece(x: .random(in: 0...1), color: colors.randomElement()!, rotation: .random(in: 0...360),
                      delay: .random(in: 0...0.35), size: .random(in: 6...12), drift: .random(in: -80...80))
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                pieces = []
            }
        }
    }
}

private struct ConfettiPiece: View {
    let piece: ConfettiView.Piece
    let height: CGFloat
    @State private var fallen = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(piece.color)
            .frame(width: piece.size, height: piece.size * 1.6)
            .rotationEffect(.degrees(fallen ? piece.rotation + 540 : piece.rotation))
            .rotation3DEffect(.degrees(fallen ? 720 : 0), axis: (x: 1, y: 0, z: 0))
            .offset(x: fallen ? piece.drift : 0, y: fallen ? height + 60 : 0)
            .onAppear {
                withAnimation(.easeIn(duration: .random(in: 1.8...2.6)).delay(piece.delay)) { fallen = true }
            }
    }
}
