import SwiftUI
import StoreKit

/// Paywall view showing the feature comparison and the one-time Bricky Pro
/// unlock ($4.99). There is no subscription.
struct PaywallView: View {
    @ObservedObject private var subscription = SubscriptionManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                    featureComparisonSection
                    pricingSection
                    restoreSection
                    legalSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(AppConfig.appName) Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.legoYellow)

            Text("Unlock Everything")
                .font(.title2)
                .fontWeight(.bold)

            Text("Unlimited scans, full build library, and advanced features.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Feature Comparison

    private var featureComparisonSection: some View {
        VStack(spacing: 0) {
            // Header row
            HStack {
                Text("Feature")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Free")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .frame(width: 60)
                Text("Pro")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.legoBlue)
                    .frame(width: 60)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemGray5))

            Divider()

            featureRow("Daily Scans", free: "\(SubscriptionManager.freeDailyScanLimit)", pro: "Unlimited")
            featureRow("Build Ideas", free: "\(SubscriptionManager.freeBuildVisibleLimit)", pro: "All 200+")
            featureRow("Piece Catalog", free: checkmark, pro: checkmark)
            featureRow("Color Recognition", free: checkmark, pro: checkmark)
            featureRow("AI Build Ideas", free: dash, pro: checkmark)
            featureRow("3D Model Export", free: dash, pro: checkmark)
            featureRow("STL Print Export", free: dash, pro: checkmark)
            featureRow("iCloud Sync", free: dash, pro: checkmark)
            featureRow("CSV/PDF Export", free: dash, pro: checkmark)
            featureRow("Natural Language Search", free: dash, pro: checkmark)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private let checkmark = "checkmark.circle.fill"
    private let dash = "minus.circle"

    private func featureRow(_ title: String, free: String, pro: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Group {
                    if free.contains(".") {
                        Image(systemName: free)
                            .foregroundStyle(free == checkmark ? .green : .secondary)
                    } else {
                        Text(free)
                            .font(.caption)
                    }
                }
                .frame(width: 60)

                Group {
                    if pro.contains(".") {
                        Image(systemName: pro)
                            .foregroundStyle(pro == checkmark ? .green : .secondary)
                    } else {
                        Text(pro)
                            .font(.caption)
                            .foregroundStyle(Color.legoBlue)
                    }
                }
                .frame(width: 60)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
        }
    }

    // MARK: - Pricing

    private var pricingSection: some View {
        VStack(spacing: 12) {
            switch subscription.productsLoadState {
            case .loading:
                ProgressView("Loading plans...")
            case .unavailable:
                VStack(spacing: 8) {
                    Text("Plans are unavailable right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Check your connection and try again in a moment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await subscription.reloadProducts() }
                    } label: {
                        Text("Try Again")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.legoBlue)
                    }
                }
                .padding(.vertical, 8)
            case .loaded:
                EmptyView()
            }

            if let error = subscription.purchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if let pro = subscription.proProduct {
                productButton(pro)
            }
        }
    }

    private func productButton(_ product: Product) -> some View {
        Button {
            Task { await subscription.purchase(product) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlock \(AppConfig.appName) Pro")
                        .fontWeight(.semibold)
                    Text(product.displayPrice + " · one-time purchase")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                if subscription.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.legoBlue)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(subscription.isLoading)
    }

    // MARK: - Restore

    private var restoreSection: some View {
        Button {
            Task { await subscription.restorePurchases() }
        } label: {
            Text("Restore Purchases")
                .font(.subheadline)
                .foregroundStyle(Color.legoBlue)
        }
        .disabled(subscription.isLoading)
    }

    // MARK: - Legal

    private var legalSection: some View {
        VStack(spacing: 4) {
            Text("One-time purchase. No subscription.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Payment will be charged to your Apple ID account at confirmation of purchase. \(AppConfig.appName) Pro unlocks permanently and can be restored on your other devices.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 16)
    }
}

#if DEBUG
#Preview {
    PaywallView()
}
#endif
