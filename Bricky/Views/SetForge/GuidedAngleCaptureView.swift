import AVFoundation
import SwiftUI

/// Guided still capture of a subject from four sides (front → left → back →
/// right). The user frames each side and taps the shutter; the four photos are
/// handed back for the multiview (all-angles) 3D model path.
///
/// Reuses `VideoSweepCapture`'s live session and grabs the newest frame on each
/// shutter tap. Device-only — the camera does not run in the simulator.
struct GuidedAngleCaptureView: View {
    var onComplete: ([UIImage]) -> Void

    @StateObject private var capture = VideoSweepCapture()
    @Environment(\.dismiss) private var dismiss
    @State private var captured: [UIImage] = []
    @State private var permissionDenied = false

    private let angles = ["Front", "Left side", "Back", "Right side"]

    private var currentAngle: String {
        captured.count < angles.count ? angles[captured.count] : "Done"
    }

    var body: some View {
        ZStack {
            CameraPreview(session: capture.session)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                if permissionDenied {
                    permissionMessage
                } else {
                    coaching
                    thumbnails
                    shutter
                }
            }
            .padding()
        }
        .statusBarHidden()
        .onAppear { requestAndStart() }
        .onDisappear { capture.stop() }
    }

    // MARK: - Sections

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .padding(12)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Cancel")
            Spacer()
            Text("Photograph 4 Angles")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(.black.opacity(0.55)))
                .foregroundStyle(.white)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private var coaching: some View {
        VStack(spacing: 6) {
            Text("Photo \(min(captured.count + 1, angles.count)) of \(angles.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Frame the \(currentAngle.lowercased()) of the subject")
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.4)))
    }

    private var thumbnails: some View {
        HStack(spacing: 8) {
            ForEach(Array(angles.enumerated()), id: \.offset) { index, label in
                VStack(spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.black.opacity(0.4))
                            .frame(width: 56, height: 56)
                        if index < captured.count {
                            Image(uiImage: captured[index])
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: index == captured.count ? "camera.fill" : "circle.dashed")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var shutter: some View {
        VStack(spacing: 14) {
            Button {
                captureShot()
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 5).frame(width: 78, height: 78)
                    Circle().fill(.white).frame(width: 62, height: 62)
                }
            }
            .disabled(capture.latestFrame == nil)
            .accessibilityLabel("Capture \(currentAngle)")

            if !captured.isEmpty {
                Button("Retake last") {
                    if !captured.isEmpty { captured.removeLast() }
                }
                .font(.subheadline)
                .foregroundStyle(.white)
            }
        }
        .padding(.bottom, 12)
    }

    private var permissionMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill")
                .font(.largeTitle)
                .foregroundStyle(.white)
            Text("Camera access is needed to photograph the subject. Enable it in Settings.")
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.5)))
    }

    // MARK: - Capture

    private func captureShot() {
        guard let frame = capture.latestFrame else { return }
        captured.append(frame)
        if captured.count >= angles.count {
            let shots = captured
            capture.stop()
            onComplete(shots)
            dismiss()
        }
    }

    // MARK: - Permission + start

    private func requestAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            capture.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { capture.start() } else { permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }
}
