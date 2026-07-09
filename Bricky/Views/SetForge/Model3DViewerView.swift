import SwiftUI

/// Full-screen interactive 3D viewer for a forged brick model. Because it isn't
/// inside a `ScrollView`, SceneKit's camera control gets every touch, so drag to
/// rotate, pinch to zoom, and two-finger pan all work cleanly.
struct Model3DViewerView: View {
    let bricks: [PlacedBrick]
    var title: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGroupedBackground), Color(.secondarySystemGroupedBackground)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            BrickModelSceneView(bricks: bricks)
                .ignoresSafeArea(edges: .bottom)

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .padding(12)
                            .background(.thinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                .padding()
                Spacer()
                Label("Drag to rotate · pinch to zoom · two fingers to pan", systemImage: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 20)
            }
        }
        .navigationTitle(title)
    }
}

/// Full-screen, zoomable viewer for the captured source images. Swipe between
/// the angle photos / video-sweep frames; pinch to zoom, drag to pan.
struct ImageViewerView: View {
    let images: [UIImage]
    var startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(images: [UIImage], startIndex: Int) {
        self.images = images
        self.startIndex = startIndex
        _selection = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    ZoomableImage(image: image)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                .padding()
                Spacer()
                if images.count > 1 {
                    Text("\(selection + 1) of \(images.count)")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 28)
                }
            }
        }
        .statusBarHidden()
    }
}

/// A single pinch-to-zoom / drag-to-pan image, with double-tap to reset.
private struct ZoomableImage: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(5, max(1, lastScale * value))
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1 { withAnimation { resetPan() } }
                        },
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in lastOffset = offset }
                )
            )
            .onTapGesture(count: 2) {
                withAnimation {
                    if scale > 1 {
                        scale = 1; lastScale = 1; resetPan()
                    } else {
                        scale = 2.5; lastScale = 2.5
                    }
                }
            }
    }

    private func resetPan() {
        offset = .zero
        lastOffset = .zero
    }
}
