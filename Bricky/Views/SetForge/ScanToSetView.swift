import PhotosUI
import SwiftUI

/// **Scan to Set** — the visual Set Forge flow. The user picks or takes a photo
/// of a real-world subject, chooses a size, and Bricky forges a buildable brick
/// model from it, entirely on-device.
struct ScanToSetView: View {
    @StateObject private var viewModel = ForgeVisionViewModel()
    @ObservedObject private var subscription = SubscriptionManager.shared

    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showPaywall = false
    @State private var navigateToResult = false
    @State private var loadError: String?
    @FocusState private var nameFocused: Bool

    private let contentMaxWidth: CGFloat = 480

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                imageArea
                sourceButtons
                nameField
                ForgeSizePicker(
                    selected: $viewModel.selectedSize,
                    isUnlocked: { viewModel.isSizeUnlocked($0) },
                    onLocked: { showPaywall = true }
                )
                generateButton
                if let error = viewModel.errorMessage ?? loadError {
                    errorBanner(error)
                }
            }
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Scan to Set")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { nameFocused = false }
            }
        }
        .overlay { if viewModel.isBusy { progressOverlay } }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .fullScreenCover(isPresented: $showCamera) {
            CameraImagePicker { image in
                viewModel.sourceImage = image
                showCamera = false
            }
            .ignoresSafeArea()
        }
        .navigationDestination(isPresented: $navigateToResult) {
            if let result = viewModel.result {
                GeneratedSetView(set: result)
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            loadError = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    viewModel.sourceImage = image
                } else {
                    loadError = "That image couldn't be loaded. Try another."
                }
            }
        }
        .onChange(of: viewModel.phase) { _, phase in
            if phase == .completed {
                nameFocused = false
                navigateToResult = true
            }
        }
        .onDisappear { nameFocused = false }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.legoBlue.opacity(0.15)).frame(width: 80, height: 80)
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.legoBlue)
            }
            Text("Take or pick a photo of a real object and Bricky forges a brick model of it — with a parts list and instructions. Works best with a single subject on a plain background.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Image

    private var imageArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(height: 240)
            if let image = viewModel.sourceImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No photo selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sourceButtons: some View {
        HStack(spacing: 12) {
            if cameraAvailable {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
                }
                .buttonStyle(.plain)
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose Photo", systemImage: "photo")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name (optional)")
                .font(.subheadline.weight(.medium))
            TextField("e.g. My Toy Car", text: $viewModel.subjectName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { nameFocused = false }
        }
    }

    // MARK: - Generate

    private var generateButton: some View {
        Button {
            nameFocused = false
            if viewModel.isSizeUnlocked(viewModel.selectedSize) {
                viewModel.generate()
            } else {
                showPaywall = true
            }
        } label: {
            Label("Forge My Set", systemImage: "hammer.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(viewModel.canGenerate ? Color.legoBlue : Color.gray.opacity(0.4))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!viewModel.canGenerate)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.1)))
    }

    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: viewModel.progressFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                Text("Forging your set…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial))
        }
    }
}
