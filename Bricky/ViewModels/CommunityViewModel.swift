import Foundation
import SwiftUI

/// View model for the community feed, managing post display and filtering
@MainActor
final class CommunityViewModel: ObservableObject {
    @Published var selectedFilter: FeedFilter = .recent
    @Published var searchText: String = ""
    /// Optional category refinement applied on top of the feed filter.
    @Published var categoryFilter: ProjectCategory?
    /// Optional difficulty refinement applied on top of the feed filter.
    @Published var difficultyFilter: Difficulty?

    enum FeedFilter: String, CaseIterable {
        case recent = "Recent"
        case popular = "Popular"
        case myPosts = "My Posts"
    }

    /// Whether any of the refinement filters (category / difficulty) are active.
    var hasActiveRefinements: Bool {
        categoryFilter != nil || difficultyFilter != nil
    }

    /// Number of active refinement filters, for badging the filter control.
    var activeRefinementCount: Int {
        (categoryFilter != nil ? 1 : 0) + (difficultyFilter != nil ? 1 : 0)
    }

    func clearRefinements() {
        categoryFilter = nil
        difficultyFilter = nil
    }

    var filteredPosts: [CommunityPost] {
        let service = CloudKitCommunityService.shared
        var result = service.posts

        // Apply filter
        switch selectedFilter {
        case .recent:
            result.sort { $0.createdAt > $1.createdAt }
        case .popular:
            result.sort { $0.likeCount > $1.likeCount }
        case .myPosts:
            let userId = AuthenticationService.shared.userIdentifier
            result = result.filter { $0.authorId == userId }
            result.sort { $0.createdAt > $1.createdAt }
        }

        // Apply category refinement
        if let categoryFilter {
            result = result.filter { $0.category == categoryFilter }
        }

        // Apply difficulty refinement
        if let difficultyFilter {
            result = result.filter { $0.difficulty == difficultyFilter }
        }

        // Apply search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.projectName.lowercased().contains(query) ||
                $0.authorName.lowercased().contains(query) ||
                $0.caption.lowercased().contains(query)
            }
        }

        return result
    }

    func refresh() async {
        await CloudKitCommunityService.shared.fetchPosts()
        // "My Posts" filters the locally-fetched feed by author. The general
        // feed may be capped or eventually-consistent, so also pull the user's
        // own posts directly and merge them in.
        if selectedFilter == .myPosts {
            await CloudKitCommunityService.shared.mergeCurrentUserPosts()
        }
    }

    func toggleLike(postId: String) {
        Task {
            await CloudKitCommunityService.shared.toggleLike(postId: postId)
        }
    }
}
