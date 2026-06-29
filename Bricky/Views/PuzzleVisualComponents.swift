import SwiftUI

// MARK: - Silhouette Reveal

/// A mystery build shown as a progressively de-blurring silhouette.
/// At the first clue it's a dark, heavily blurred shape; with each revealed
/// clue it sharpens, and when solved it snaps into full color.
struct PuzzleSilhouetteView: View {
    let systemImage: String
    /// 0 = first clue (most hidden) … 1 = all clues revealed.
    let revealFraction: Double
    let isSolved: Bool

    /// Blur shrinks from heavy to none as clues are revealed.
    private var blurRadius: CGFloat {
        if isSolved { return 0 }
        return CGFloat(24 * (1 - revealFraction))
    }

    /// The shape fades from a near-black silhouette toward its real color.
    private var symbolColor: Color {
        if isSolved { return .legoRed }
        let darkness = 0.85 - revealFraction * 0.35
        return Color.primary.opacity(darkness)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [Color(.systemGray6), Color(.systemGray5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .padding(40)
                .foregroundStyle(symbolColor)
                .blur(radius: blurRadius)
                .scaleEffect(isSolved ? 1.0 : 0.92)
                .animation(.easeInOut(duration: 0.5), value: revealFraction)
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: isSolved)

            // "?" watermark only while it's still a deep mystery.
            if !isSolved && revealFraction < 0.25 {
                Image(systemName: "questionmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .shadow(radius: 2)
            }
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityLabel(isSolved ? "Revealed build" : "Mystery build silhouette")
    }
}

// MARK: - Mosaic Reveal

/// A mystery build shown as a mosaic: the full image is masked by an NxN grid of
/// opaque tiles, and each hint uncovers random squares. Fully revealed/solved
/// shows the build cleanly.
struct PuzzleMosaicRevealView: View {
    let systemImage: String
    let gridSize: Int
    let revealedCells: Set<Int>
    let isSolved: Bool
    var palette: [LegoColor] = []
    var category: ProjectCategory = .vehicle
    var seed: Int = 0

    private var colors: [Color] {
        let p = palette.map { Color.legoColor($0) }
        return p.isEmpty ? [Color.legoRed, Color.legoBlue, Color.legoYellow, Color.legoGreen] : p
    }

    var body: some View {
        // Square board so every cell is a true square regardless of grid size.
        ZStack {
            // Brick-style build: palette gradient + category motif + studs.
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(StudTexture(colors: colors).opacity(0.45))
                .overlay(CategoryMotif(category: category, colors: colors, seed: seed).opacity(0.8))
            Image(systemName: systemImage)
                .resizable().scaledToFit().padding(36)
                .fontWeight(.black)
                .foregroundStyle(.white.opacity(isSolved ? 0.95 : 0.82))
                .shadow(color: .black.opacity(0.3), radius: 2)
            if !isSolved {
                Canvas { ctx, size in
                    let n = max(1, gridSize)
                    let cell = min(size.width, size.height) / CGFloat(n)
                    for index in 0..<(n * n) where !revealedCells.contains(index) {
                        let r = index / n, c = index % n
                        ctx.fill(
                            Path(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell)),
                            with: .color(Color(.systemGray3))
                        )
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityLabel(isSolved ? "Revealed build" : "Mystery build, partially revealed")
    }
}

/// A subtle 12×12 LEGO stud pattern using the build's palette, giving the
/// mystery image a real brick-mosaic feel instead of a flat icon.
private struct StudTexture: View {
    let colors: [Color]
    var body: some View {
        Canvas { ctx, size in
            let n = 12
            let s = min(size.width, size.height) / CGFloat(n)
            for r in 0..<n {
                for c in 0..<n {
                    let color = colors[(r * 7 + c * 3) % colors.count]
                    let d = s * 0.55
                    let rect = CGRect(x: CGFloat(c) * s + (s - d) / 2, y: CGFloat(r) * s + (s - d) / 2, width: d, height: d)
                    ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.6)))
                }
            }
        }
    }
}

/// Distinct per-category motif so puzzles look different by build type: wheels
/// for vehicles, a window grid for buildings, diagonal hull for spaceships, etc.
private struct CategoryMotif: View {
    let category: ProjectCategory
    let colors: [Color]
    let seed: Int
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let c = colors.first ?? .white
            switch category {
            case .vehicle:
                ctx.fill(Path(ellipseIn: CGRect(x: w*0.18, y: h*0.62, width: w*0.18, height: w*0.18)), with: .color(.black.opacity(0.5)))
                ctx.fill(Path(ellipseIn: CGRect(x: w*0.64, y: h*0.62, width: w*0.18, height: w*0.18)), with: .color(.black.opacity(0.5)))
            case .building:
                for r in 0..<4 { for cc in 0..<3 {
                    ctx.fill(Path(CGRect(x: w*(0.2+Double(cc)*0.22), y: h*(0.18+Double(r)*0.18), width: w*0.12, height: h*0.1)), with: .color(.white.opacity(0.45)))
                }}
            case .spaceship, .robot:
                ctx.fill(Path(CGRect(x: w*0.2, y: h*0.45, width: w*0.6, height: h*0.1)), with: .color(.white.opacity(0.4)))
            case .nature, .animal:
                ctx.fill(Path(ellipseIn: CGRect(x: w*0.3, y: h*0.3, width: w*0.4, height: h*0.4)), with: .color(c.opacity(0.4)))
            default:
                for i in 0..<5 {
                    let x = w * (0.1 + Double((seed + i) % 8) * 0.1)
                    ctx.fill(Path(CGRect(x: x, y: h*0.1*Double(i)+h*0.1, width: w*0.12, height: h*0.06)), with: .color(.white.opacity(0.3)))
                }
            }
        }
    }
}

// MARK: - Color Palette Hint
/// A row of real LEGO brick-color swatches the build uses — a visual clue.
struct PuzzlePaletteHint: View {
    let colors: [LegoColor]

    var body: some View {
        if !colors.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Colors in this build", systemImage: "paintpalette.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(colors, id: \.self) { color in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.legoColor(color))
                            .frame(width: 30, height: 30)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                            // Stud detail to read as a brick, not a plain swatch.
                            .overlay(
                                Circle()
                                    .fill(Color.white.opacity(0.25))
                                    .frame(width: 10, height: 10)
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Pieces Strip

/// A real "built from these pieces" preview shown after a puzzle is solved.
/// Each thumbnail is rendered from the build's actual required pieces (true
/// category, color, and dimensions) via `PieceImageGenerator` — not an invented
/// model — so it faithfully shows what the build is made of.
struct PuzzlePiecesStrip: View {
    let pieces: [RequiredPiece]

    var body: some View {
        if !pieces.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Built from these pieces", systemImage: "shippingbox.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(pieces) { piece in
                            VStack(spacing: 4) {
                                Image(uiImage: PieceImageGenerator.shared.image(
                                    category: piece.category,
                                    color: piece.flexible ? .gray : (piece.colorPreference ?? .gray),
                                    size: 56
                                ))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)

                                Text("×\(piece.quantity)")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Confetti Celebration

/// A lightweight burst of falling LEGO-colored bricks, played once on a win.
struct PuzzleConfettiView: View {    @State private var animate = false

    private let pieces: [ConfettiPiece] = (0..<28).map { _ in ConfettiPiece.random() }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { piece in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(piece.color)
                        .frame(width: piece.size, height: piece.size * 0.6)
                        .rotationEffect(.degrees(animate ? piece.rotation : 0))
                        .position(
                            x: geo.size.width * piece.startX,
                            y: animate ? geo.size.height * 1.1 : -40
                        )
                        .opacity(animate ? 0 : 1)
                        .animation(
                            .easeIn(duration: piece.duration).delay(piece.delay),
                            value: animate
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { animate = true }
    }

    struct ConfettiPiece: Identifiable {
        let id = UUID()
        let color: Color
        let size: CGFloat
        let startX: CGFloat
        let rotation: Double
        let duration: Double
        let delay: Double

        static func random() -> ConfettiPiece {
            let palette: [Color] = [.legoRed, .legoBlue, .legoYellow, .legoGreen, .legoOrange]
            return ConfettiPiece(
                color: palette.randomElement()!,
                size: CGFloat.random(in: 10...18),
                startX: CGFloat.random(in: 0.05...0.95),
                rotation: Double.random(in: 180...720),
                duration: Double.random(in: 1.4...2.4),
                delay: Double.random(in: 0...0.4)
            )
        }
    }
}
