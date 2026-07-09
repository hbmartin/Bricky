import SwiftUI

/// **Describe a Set** — the verbal/text Set Forge flow. The user types or
/// dictates a subject, picks a size, and Bricky generates a buildable brick set
/// entirely on-device.
struct DescribeSetView: View {
    @StateObject private var viewModel = ForgeTextViewModel()
    @StateObject private var dictation = SpeechDictationService()
    @ObservedObject private var subscription = SubscriptionManager.shared

    @State private var showPaywall = false
    @State private var navigateToResult = false
    @FocusState private var descriptionFocused: Bool

    private let contentMaxWidth: CGFloat = 480

    private let examples = ["A red house", "A green tree", "A blue robot",
                            "A yellow duck", "A rocket ship", "A heart", "A castle"]

    private let accentSwatches: [LegoColor] = [.red, .orange, .yellow, .green,
                                               .blue, .purple, .pink, .white, .black]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                promptField
                examplesRow
                sizeSection
                colorSection
                generateButton
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }
            }
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Describe a Set")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { descriptionFocused = false }
            }
        }
        .overlay { if viewModel.isBusy { progressOverlay } }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .navigationDestination(isPresented: $navigateToResult) {
            if let result = viewModel.result {
                GeneratedSetView(set: result)
            }
        }
        .onChange(of: dictation.transcript) { _, newValue in
            if !newValue.isEmpty { viewModel.description = newValue }
        }
        .onChange(of: viewModel.phase) { _, phase in
            if phase == .completed {
                descriptionFocused = false
                navigateToResult = true
            }
        }
        .onDisappear {
            descriptionFocused = false
            dictation.stop()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.legoBlue.opacity(0.15)).frame(width: 80, height: 80)
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.legoBlue)
            }
            Text("Describe what you want to build and Bricky forges a brick model you can build for real — with a parts list and instructions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Prompt

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if viewModel.description.isEmpty {
                    Text("e.g. a small red dragon")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                TextEditor(text: $viewModel.description)
                    .frame(minHeight: 90)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                    .focused($descriptionFocused)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.08)))

            HStack {
                Button {
                    toggleDictation()
                } label: {
                    Label(dictation.isRecording ? "Stop" : "Dictate",
                          systemImage: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(dictation.isRecording ? Color.red.opacity(0.15) : Color.legoBlue.opacity(0.12)))
                        .foregroundStyle(dictation.isRecording ? .red : Color.legoBlue)
                }
                if dictation.isRecording {
                    Text("Listening…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !viewModel.description.isEmpty {
                    Button {
                        viewModel.description = ""
                        dictation.reset()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel("Clear description")
                }
            }
            if let dictationError = dictation.errorMessage {
                Text(dictationError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var examplesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button {
                        viewModel.description = example
                        descriptionFocused = false
                    } label: {
                        Text(example)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Size

    private var sizeSection: some View {
        ForgeSizePicker(
            selected: $viewModel.selectedSize,
            isUnlocked: { _ in true },
            onLocked: { showPaywall = true }
        )
    }

    // MARK: - Color

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Primary Color")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    autoSwatch
                    ForEach(accentSwatches, id: \.self) { color in
                        swatch(color)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    private var autoSwatch: some View {
        Button {
            viewModel.accentColor = nil
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(Color(.tertiarySystemGroupedBackground)).frame(width: 34, height: 34)
                    Image(systemName: "wand.and.stars").font(.caption).foregroundStyle(.secondary)
                }
                .overlay(Circle().stroke(viewModel.accentColor == nil ? Color.legoBlue : .clear, lineWidth: 2))
                Text("Auto").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func swatch(_ color: LegoColor) -> some View {
        Button {
            viewModel.accentColor = color
        } label: {
            Circle()
                .fill(Color(hex: color.hexColor))
                .frame(width: 34, height: 34)
                .overlay(Circle().stroke(.black.opacity(0.15)))
                .overlay(Circle().stroke(viewModel.accentColor == color ? Color.legoBlue : .clear, lineWidth: 3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.rawValue)
    }

    // MARK: - Generate

    private var generateButton: some View {
        Button {
            descriptionFocused = false
            if viewModel.isProUser {
                viewModel.generate()
            } else {
                showPaywall = true
            }
        } label: {
            Label(viewModel.isProUser ? "Forge My Set" : "Forge My Set · Pro",
                  systemImage: viewModel.isProUser ? "hammer.fill" : "lock.fill")
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

    // MARK: - Dictation

    private func toggleDictation() {
        if dictation.isRecording {
            dictation.stop()
        } else {
            descriptionFocused = false
            dictation.reset()
            dictation.start()
        }
    }
}
