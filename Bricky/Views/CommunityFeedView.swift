import SwiftUI

/// Community feed showing shared builds from all users
struct CommunityFeedView: View {
    @StateObject private var viewModel = CommunityViewModel()
    @ObservedObject private var communityService = CloudKitCommunityService.shared
    @ObservedObject private var auth = AuthenticationService.shared
    @State private var showShareCreation = false
    @State private var showProfile = false
    @State private var selectedPost: CommunityPost?
    /// Post being edited via the context menu / detail modal.
    @State private var postToEdit: CommunityPost?
    /// Post pending deletion, awaiting confirmation.
    @State private var postPendingDelete: CommunityPost?
    /// Post to scroll to after switching to My Posts (from the profile screen).
    @State private var scrollTarget: CommunityPost.ID?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        Group {
            if auth.isSignedIn {
                signedInContent
            } else {
                signInPrompt
            }
        }
        .navigationTitle("Community")
        .toolbar {
            if auth.isSignedIn {
                ToolbarItem(placement: .navigationBarLeading) {
                    filterMenu
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showProfile = true
                    } label: {
                        Image(systemName: communityService.userProfile?.avatarSystemName ?? "person.crop.circle")
                    }
                    .accessibilityLabel("View profile")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showShareCreation = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .foregroundStyle(Color.legoBlue)
                    .accessibilityLabel("Share a build")
                }
            }
        }
        .sheet(isPresented: $showShareCreation) {
            NavigationStack {
                ShareCreationView()
            }
        }
        .sheet(isPresented: $showProfile) {
            NavigationStack {
                UserProfileView { post in
                    viewModel.selectedFilter = .myPosts
                    scrollTarget = post.id
                }
            }
        }
        .sheet(item: $selectedPost) { post in
            NavigationStack {
                CommunityPostDetailView(post: post)
            }
        }
        .sheet(item: $postToEdit) { post in
            NavigationStack {
                EditPostView(post: post)
            }
        }
        .confirmationDialog(
            "Delete this post?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible,
            presenting: postPendingDelete
        ) { post in
            Button("Delete Post", role: .destructive) {
                deletePost(post)
            }
            Button("Cancel", role: .cancel) {}
        } message: { post in
            Text("\"\(post.projectName)\" will be permanently removed. This can't be undone.")
        }
    }

    /// Bridges the optional `postPendingDelete` to the boolean the
    /// confirmation dialog expects, clearing it when dismissed.
    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { postPendingDelete != nil },
            set: { if !$0 { postPendingDelete = nil } }
        )
    }

    private func deletePost(_ post: CommunityPost) {
        Task {
            try? await communityService.deletePost(post.id)
            await MainActor.run { HapticManager.notification(.success) }
        }
    }

    // MARK: - Filter Controls

    /// Toolbar menu offering category and difficulty refinements.
    private var filterMenu: some View {
        Menu {
            Menu("Category") {
                Button {
                    viewModel.categoryFilter = nil
                } label: {
                    Label("All Categories", systemImage: viewModel.categoryFilter == nil ? "checkmark" : "")
                }
                Divider()
                ForEach(ProjectCategory.allCases, id: \.self) { category in
                    Button {
                        viewModel.categoryFilter = category
                    } label: {
                        Label(
                            category.rawValue,
                            systemImage: viewModel.categoryFilter == category ? "checkmark" : category.systemImage
                        )
                    }
                }
            }

            Menu("Difficulty") {
                Button {
                    viewModel.difficultyFilter = nil
                } label: {
                    Label("All Difficulties", systemImage: viewModel.difficultyFilter == nil ? "checkmark" : "")
                }
                Divider()
                ForEach(Difficulty.allCases, id: \.self) { difficulty in
                    Button {
                        viewModel.difficultyFilter = difficulty
                    } label: {
                        Label(
                            difficulty.rawValue,
                            systemImage: viewModel.difficultyFilter == difficulty ? "checkmark" : ""
                        )
                    }
                }
            }

            if viewModel.hasActiveRefinements {
                Divider()
                Button(role: .destructive) {
                    viewModel.clearRefinements()
                } label: {
                    Label("Clear Filters", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: viewModel.hasActiveRefinements
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter posts")
    }

    /// Horizontal row of removable chips for the active category / difficulty.
    private var activeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let category = viewModel.categoryFilter {
                    filterChip(label: category.rawValue, systemImage: category.systemImage) {
                        viewModel.categoryFilter = nil
                    }
                }
                if let difficulty = viewModel.difficultyFilter {
                    filterChip(label: difficulty.rawValue, systemImage: "chart.bar.fill") {
                        viewModel.difficultyFilter = nil
                    }
                }
                Button {
                    viewModel.clearRefinements()
                } label: {
                    Text("Clear All")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.legoRed)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private func filterChip(label: String, systemImage: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(label) filter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.legoBlue.opacity(0.15)))
        .foregroundStyle(Color.legoBlue)
    }

    // MARK: - Signed In Content

    private var signedInContent: some View {
        VStack(spacing: 0) {

            // First-use tip
            FeatureTipView(
                tip: .firstCommunityVisit,
                icon: "person.3.fill",
                title: "Welcome to the Community",
                message: "Share your builds, like and comment on others' creations, and follow builders you enjoy. Your builds inspire others!",
                color: Color.legoOrange
            )
            .padding(.horizontal)
            .padding(.top, 8)

            // Filter picker
            Picker("Filter", selection: $viewModel.selectedFilter) {
                ForEach(CommunityViewModel.FeedFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Active refinement chips
            if viewModel.hasActiveRefinements {
                activeFilterChips
            }

            if communityService.isLoading && communityService.posts.isEmpty {
                Spacer()
                ProgressView("Loading community builds...")
                Spacer()
            } else {
                feedContent
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search posts...")
        .task {
            await communityService.loadCurrentProfile()
            await viewModel.refresh()
        }
        .onChange(of: viewModel.selectedFilter) { _, _ in
            Task { await viewModel.refresh() }
        }
    }

    // MARK: - Feed Content

    /// Scrollable feed area (grid or empty state) with pull-to-refresh.
    /// Wrapping the empty state in the same `ScrollView` lets users pull to
    /// refresh even when no posts are currently shown.
    private var feedContent: some View {
        ScrollView {
            if viewModel.filteredPosts.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                ScrollViewReader { proxy in
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(viewModel.filteredPosts) { post in
                            CommunityPostCard(post: post) {
                                viewModel.toggleLike(postId: post.id)
                            }
                            .id(post.id)
                            .onTapGesture {
                                selectedPost = post
                            }
                        .contextMenu {
                            if post.isOwned(by: auth.userIdentifier) {
                                Button {
                                    postToEdit = post
                                } label: {
                                    Label("Edit Post", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    postPendingDelete = post
                                } label: {
                                    Label("Delete Post", systemImage: "trash")
                                }
                            }
                        }
                    }                    }                    .padding()
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .top) }
                        scrollTarget = nil
                    }
                }
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                emptyStateTitle,
                systemImage: emptyStateIcon
            )
        } description: {
            if viewModel.hasActiveRefinements {
                Text("No posts match the current filters.")
            } else if viewModel.selectedFilter == .myPosts {
                Text("Share your first build with the community!")
            } else if !viewModel.searchText.isEmpty {
                Text("Try a different search term.")
            } else {
                Text("Be the first to share a build!")
            }
        } actions: {
            if viewModel.hasActiveRefinements {
                Button("Clear Filters") {
                    viewModel.clearRefinements()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.legoBlue)
            } else if viewModel.selectedFilter == .myPosts {
                Button("Share a Build") {
                    showShareCreation = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.legoBlue)
            }
        }
    }

    private var emptyStateTitle: String {
        if viewModel.hasActiveRefinements { return "No Matches" }
        return viewModel.selectedFilter == .myPosts ? "No Posts Yet" : "No Builds Found"
    }

    private var emptyStateIcon: String {
        if viewModel.hasActiveRefinements { return "line.3.horizontal.decrease.circle" }
        return viewModel.selectedFilter == .myPosts ? "photo.on.rectangle.angled" : "magnifyingglass"
    }

    // MARK: - Sign In Prompt

    private var signInPrompt: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.3.fill")
                .font(.system(size: 60))
                .foregroundStyle(Color.legoBlue)

            Text("Join the Community")
                .font(.title2)
                .fontWeight(.bold)

            Text("Sign in to share your builds, discover creations from other builders, and save your favorites.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { _ in }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .frame(maxWidth: 280)
            .onAppear {
                // Use our AuthenticationService instead
            }

            Button("Sign In with Apple") {
                auth.signIn()
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
            .controlSize(.large)

            if auth.isLoading {
                ProgressView()
            }

            if let error = auth.authError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding()
    }
}

// MARK: - Post Card

struct CommunityPostCard: View {
    let post: CommunityPost
    let onLike: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Image or placeholder
            ZStack {
                if let imageData = post.imageData, let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color.legoBlue.opacity(0.3), Color.legoBlue.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: post.category?.systemImage ?? "cube.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.legoBlue)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Title
            Text(post.projectName)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)

            // Author
            HStack(spacing: 4) {
                Image(systemName: post.authorAvatar)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(post.authorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Difficulty + Likes
            HStack {
                if let difficulty = post.difficulty {
                    Text(difficulty.rawValue.capitalized)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(difficultyColor(difficulty).opacity(0.15))
                        )
                        .foregroundStyle(difficultyColor(difficulty))
                }

                Spacer()

                HStack(spacing: 8) {
                    // Comment count
                    HStack(spacing: 2) {
                        Image(systemName: "bubble.right")
                            .foregroundStyle(.secondary)
                        Text("\(post.commentCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Like button
                    Button {
                        onLike()
                        HapticManager.selection()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: post.isLikedByCurrentUser ? "heart.fill" : "heart")
                                .foregroundStyle(post.isLikedByCurrentUser ? Color.legoRed : .secondary)
                            Text("\(post.likeCount)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(post.projectName) by \(post.authorName), \(post.likeCount) likes")
    }

    private func difficultyColor(_ difficulty: Difficulty) -> Color {
        switch difficulty {
        case .beginner: return Color.legoGreen
        case .easy: return Color.legoBlue
        case .medium: return Color.legoYellow
        case .hard: return Color.legoOrange
        case .expert: return Color.legoRed
        }
    }
}

// MARK: - Post Detail View

struct CommunityPostDetailView: View {
    let post: CommunityPost
    @ObservedObject private var communityService = CloudKitCommunityService.shared
    @ObservedObject private var auth = AuthenticationService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var showDeleteConfirmation = false

    private var isOwner: Bool {
        post.isOwned(by: auth.userIdentifier)
    }

    /// The latest version of the post from the service (so edits made in the
    /// edit sheet are reflected here), falling back to the passed-in copy.
    private var currentPost: CommunityPost {
        communityService.posts.first(where: { $0.id == post.id }) ?? post
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Image
                if let imageData = post.imageData, let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [Color.legoBlue, Color.legoBlue.opacity(0.6)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(height: 200)
                        Image(systemName: post.category?.systemImage ?? "cube.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.white)
                    }
                }

                // Author info
                HStack(spacing: 10) {
                    Image(systemName: post.authorAvatar)
                        .font(.title2)
                        .foregroundStyle(Color.legoBlue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.authorName)
                            .font(.headline)
                        Text(post.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // Project info
                HStack(spacing: 8) {
                    if let category = post.category {
                        Label(category.rawValue.capitalized, systemImage: category.systemImage)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.legoBlue.opacity(0.1)))
                            .foregroundStyle(Color.legoBlue)
                    }
                    if let difficulty = post.difficulty {
                        Text(difficulty.rawValue.capitalized)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.legoOrange.opacity(0.1)))
                            .foregroundStyle(Color.legoOrange)
                    }
                }

                // Caption
                if !post.caption.isEmpty {
                    Text(post.caption)
                        .font(.body)
                }

                // Comments
                CommentsView(postId: post.id)

                // Like button
                HStack {
                    Button {
                        Task {
                            await communityService.toggleLike(postId: post.id)
                        }
                        HapticManager.impact(.medium)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: post.isLikedByCurrentUser ? "heart.fill" : "heart")
                            Text("\(post.likeCount)")
                        }
                        .font(.headline)
                        .foregroundStyle(post.isLikedByCurrentUser ? Color.legoRed : .secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    ShareLink(
                        item: "Check out \"\(post.projectName)\" on \(AppConfig.appName)! \(AppConfig.hashtag) #LEGO",
                        subject: Text(post.projectName),
                        message: Text(post.caption)
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                    }
                }
                .padding(.top, 8)

                // Owner actions — edit and delete the post.
                if isOwner {
                    HStack(spacing: 12) {
                        Button {
                            showEdit = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.legoBlue)

                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.legoRed)
                    }
                    .padding(.top, 4)
                }
            }
            .padding()
        }
        .navigationTitle(post.projectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showEdit) {
            NavigationStack {
                EditPostView(post: currentPost)
            }
        }
        .confirmationDialog(
            "Delete this post?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Post", role: .destructive) {
                deletePost()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(post.projectName)\" will be permanently removed. This can't be undone.")
        }
    }

    private func deletePost() {
        Task {
            try? await communityService.deletePost(post.id)
            await MainActor.run {
                HapticManager.notification(.success)
                dismiss()
            }
        }
    }
}

import AuthenticationServices
