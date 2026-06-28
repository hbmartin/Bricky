import SwiftUI
import PhotosUI

/// AI Subject Recognition — identify celebrities, cartoon characters, famous
/// places/landmarks, and musicians in a photo.
///
/// This is an explicitly **cloud, developer-only** feature, hidden from normal
/// users: it's reachable only when the in-app developer override is on. Any
/// failure (offline, quota, server) renders a real message — never a fabricated
/// identification. The longest-edge-capped layout keeps controls from
/// stretching edge-to-edge on iPad.
struct ImageRecognitionView: View {
    @StateObject private var viewModel = ImageRecognitionViewModel()
    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageLoadError: String?
    @State private var showPaywall = false
    @State private var showCamera = false

    /// Caps form-control width so inputs never stretch edge-to-edge on iPad.
    private let contentMaxWidth: CGFloat = 640

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                photoSection

                if viewModel.sourceImage != nil {
                    actionSection
                }

                resultsSection
                privacyFootnote
            }
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.recognitionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { _, newItem in
            Task { await loadPickedImage(newItem) }
        }
        .onChange(of: subscriptions.developerProOverride) { _, _ in
            viewModel.refreshQuota()
        }
        .alert(
            L10n.recognitionErrorImageEncoding,
            isPresented: Binding(
                get: { imageLoadError != nil },
                set: { if !$0 { imageLoadError = nil } }
            )
        ) {
            Button(L10n.done, role: .cancel) {}
        } message: {
            Text(imageLoadError ?? "")
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraImagePicker { image in
                viewModel.setImage(image)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
            Text(L10n.recognitionSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if subscriptions.isPro {
                Text(L10n.recognitionRemaining(viewModel.remainingThisMonth))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.remainingThisMonth > 0 ? Color.secondary : Color.red)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Photo Section

    private var photoSection: some View {
        VStack(spacing: 16) {
            if let image = viewModel.sourceImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            HStack(spacing: 12) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(
                        viewModel.sourceImage == nil
                            ? L10n.recognitionChoosePhoto
                            : L10n.recognitionChangePhoto,
                        systemImage: "photo.on.rectangle"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue.opacity(0.12))
                    .foregroundStyle(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    showCamera = true
                } label: {
                    Label(L10n.recognitionTakePhoto, systemImage: "camera")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Action Section

    @ViewBuilder
    private var actionSection: some View {
        if viewModel.requiresUpgrade {
            upsellCard
        } else {
            identifyButton
        }
    }

    private var identifyButton: some View {
        Button {
            Task { await viewModel.recognize() }
        } label: {
            HStack {
                if case .recognizing = viewModel.phase {
                    ProgressView()
                        .tint(.white)
                    Text(L10n.recognitionWorking)
                } else {
                    Image(systemName: "sparkles")
                    Text(L10n.recognitionIdentify)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(viewModel.canRecognize ? Color.blue : Color.gray)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!viewModel.canRecognize)
    }

    private var upsellCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            Text(L10n.recognitionUpsellTitle)
                .font(.headline)
            Text(L10n.recognitionUpsellMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showPaywall = true
            } label: {
                Text(L10n.recognitionUpgrade)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Results Section

    @ViewBuilder
    private var resultsSection: some View {
        switch viewModel.phase {
        case .results(let subjects):
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.recognitionResultsTitle)
                    .font(.headline)
                ForEach(subjects) { subject in
                    RecognizedSubjectCard(subject: subject)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .empty:
            emptyStateCard
        case .failed(let message):
            failureCard(message)
        default:
            EmptyView()
        }
    }

    private var emptyStateCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(L10n.recognitionEmptyTitle)
                .font(.headline)
            Text(L10n.recognitionEmptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func failureCard(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Privacy Footnote

    private var privacyFootnote: some View {
        Text(L10n.recognitionPrivacyNote)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Photo Loading

    @MainActor
    private func loadPickedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                viewModel.setImage(image)
            } else {
                imageLoadError = L10n.recognitionErrorImageEncoding
            }
        } catch {
            imageLoadError = error.localizedDescription
        }
    }
}

/// A single identified subject, with category icon, name, optional location,
/// confidence, and a factual summary.
private struct RecognizedSubjectCard: View {
    let subject: RecognizedSubject

    private var confidencePercent: Int {
        Int((subject.confidence * 100).rounded())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: subject.category.systemImage)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(subject.name)
                    .font(.headline)
                if let location = subject.location, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !subject.summary.isEmpty {
                    Text(subject.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("\(L10n.recognitionConfidenceLabel): \(confidencePercent)%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
