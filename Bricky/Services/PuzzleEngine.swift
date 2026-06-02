import Foundation

/// Engine that generates build puzzles and daily challenges from the project catalog
final class PuzzleEngine: ObservableObject {
    static let shared = PuzzleEngine()

    @Published var currentPuzzle: BuildPuzzle?
    @Published var puzzleHistory: [PuzzleResult] = []
    @Published var totalScore: Int = 0
    /// Consecutive correct guesses (resets when the player gives up).
    @Published var currentStreak: Int = 0
    /// Best streak ever achieved.
    @Published var bestStreak: Int = 0
    /// Streak bonus awarded for the most recently solved puzzle (for display).
    @Published var lastStreakBonus: Int = 0

    private let defaults = UserDefaults.standard
    private let scoreKey = "puzzle_totalScore"
    private let historyKey = "puzzle_history"
    private let streakKey = "puzzle_currentStreak"
    private let bestStreakKey = "puzzle_bestStreak"

    struct PuzzleResult: Codable, Identifiable {
        let id: String
        let projectName: String
        let score: Int
        let cluesUsed: Int
        let date: Date
    }

    private init() {
        totalScore = defaults.integer(forKey: scoreKey)
        currentStreak = defaults.integer(forKey: streakKey)
        bestStreak = defaults.integer(forKey: bestStreakKey)
        if let data = defaults.data(forKey: historyKey),
           let history = try? JSONDecoder().decode([PuzzleResult].self, from: data) {
            puzzleHistory = history
        }
    }

    /// Generate a new puzzle from a random project.
    ///
    /// When `poolLimit` is supplied the puzzle is drawn from the deterministic
    /// starter/Pro pack (the first `poolLimit` projects ordered by name) so free
    /// and Pro players see a stable, well-defined set of puzzles. Passing `nil`
    /// (the default) draws from the entire catalog.
    func generatePuzzle(poolLimit: Int? = nil) {
        let pool = puzzlePool(limit: poolLimit)
        guard let project = pool.randomElement() else { return }
        let clues = generateClues(for: project)
        currentPuzzle = BuildPuzzle(project: project, clues: clues)
    }

    /// The deterministic puzzle pack for a given pack size. Projects are ordered
    /// by name so the free pack is always a strict subset of the Pro pack and
    /// progress counts stay stable across launches. `nil` returns the full
    /// catalog.
    func puzzlePool(limit: Int?) -> [LegoProject] {
        let all = BuildSuggestionEngine.shared.allProjects
        guard let limit else { return all }
        return Array(all.sorted { $0.name < $1.name }.prefix(limit))
    }

    /// How many distinct puzzles in the given pack the player has already solved.
    func solvedCount(inPackOf limit: Int) -> Int {
        let packNames = Set(puzzlePool(limit: limit).map(\.name))
        let solvedNames = Set(puzzleHistory.map(\.projectName))
        return packNames.intersection(solvedNames).count
    }

    /// Reveal the next clue
    func revealNextClue() {
        guard var puzzle = currentPuzzle, puzzle.canRevealMore else { return }
        puzzle.revealedClues += 1
        currentPuzzle = puzzle
    }

    /// Submit a guess
    func submitGuess(_ guess: String) -> Bool {
        guard var puzzle = currentPuzzle else { return false }
        puzzle.attempts += 1

        let normalizedGuess = guess.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAnswer = puzzle.project.name.lowercased()

        if normalizedGuess == normalizedAnswer || normalizedAnswer.contains(normalizedGuess) {
            puzzle.isGuessed = true
            currentPuzzle = puzzle
            recordResult(puzzle)
            return true
        }

        currentPuzzle = puzzle
        return false
    }

    /// Give up and reveal the answer
    func giveUp() {
        guard var puzzle = currentPuzzle else { return }
        puzzle.isGuessed = true
        puzzle.revealedClues = puzzle.clues.count
        currentPuzzle = puzzle
        // Giving up breaks the win streak and earns no score.
        currentStreak = 0
        lastStreakBonus = 0
        defaults.set(currentStreak, forKey: streakKey)
    }

    /// Distinct LEGO colors used by a project's required pieces — drives the
    /// visual color-palette hint shown during a puzzle. Returns up to `limit`
    /// colors, most-used first.
    func paletteColors(for project: LegoProject, limit: Int = 5) -> [LegoColor] {
        var counts: [LegoColor: Int] = [:]
        for piece in project.requiredPieces {
            guard !piece.flexible, let color = piece.colorPreference else { continue }
            counts[color, default: 0] += piece.quantity
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// The most-used distinct pieces of a build, for rendering a real "built
    /// from these pieces" preview after the puzzle is solved. Returns up to
    /// `limit` pieces ordered by quantity (most-used first), de-duplicated by
    /// category + color + dimensions so the strip shows variety rather than the
    /// same brick repeated.
    func featuredPieces(for project: LegoProject, limit: Int = 6) -> [RequiredPiece] {
        var seen = Set<String>()
        var unique: [RequiredPiece] = []
        for piece in project.requiredPieces.sorted(by: { $0.quantity > $1.quantity }) {
            let key = "\(piece.category.rawValue)-\(piece.colorPreference?.rawValue ?? "any")-\(piece.dimensions.studsWide)x\(piece.dimensions.studsLong)"
            if seen.insert(key).inserted {
                unique.append(piece)
            }
            if unique.count >= limit { break }
        }
        return unique
    }

    /// Get available answer choices for multiple-choice mode
    func getAnswerChoices(for puzzle: BuildPuzzle, count: Int = 4) -> [String] {
        let projects = BuildSuggestionEngine.shared.allProjects
        var choices = [puzzle.project.name]

        let sameCategory = projects.filter {
            $0.category == puzzle.project.category && $0.name != puzzle.project.name
        }.shuffled()

        for project in sameCategory where choices.count < count {
            choices.append(project.name)
        }

        // Fill remaining with random projects
        let others = projects.filter { !choices.contains($0.name) }.shuffled()
        for project in others where choices.count < count {
            choices.append(project.name)
        }

        return choices.shuffled()
    }

    private func generateClues(for project: LegoProject) -> [String] {
        var clues: [String] = []

        // Clue 1: Category
        clues.append("Category: \(project.category.rawValue)")

        // Clue 2: Difficulty
        clues.append("Difficulty: \(project.difficulty.rawValue)")

        // Clue 3: Piece count
        let totalPieces = project.requiredPieces.reduce(0) { $0 + $1.quantity }
        clues.append("Total pieces needed: \(totalPieces)")

        // Clue 4: Estimated time
        clues.append("Estimated build time: \(project.estimatedTime)")

        // Clue 5: First letter
        clues.append("Starts with the letter '\(project.name.prefix(1).uppercased())'")

        return clues
    }

    private func recordResult(_ puzzle: BuildPuzzle) {
        // Advance the win streak and award a bonus that scales with it.
        currentStreak += 1
        bestStreak = max(bestStreak, currentStreak)
        let streakBonus = streakBonus(for: currentStreak)
        lastStreakBonus = streakBonus

        let result = PuzzleResult(
            id: UUID().uuidString,
            projectName: puzzle.project.name,
            score: puzzle.score + streakBonus,
            cluesUsed: puzzle.revealedClues,
            date: Date()
        )
        puzzleHistory.insert(result, at: 0)
        totalScore += result.score

        // Persist
        defaults.set(totalScore, forKey: scoreKey)
        defaults.set(currentStreak, forKey: streakKey)
        defaults.set(bestStreak, forKey: bestStreakKey)
        if let data = try? JSONEncoder().encode(puzzleHistory) {
            defaults.set(data, forKey: historyKey)
        }

        // Record streak activity
        StreakTracker.shared.recordActivity()
    }

    /// Bonus points for an active win streak: +10 per consecutive solve beyond
    /// the first (capped), so a hot streak is rewarded without dominating score.
    func streakBonus(for streak: Int) -> Int {
        guard streak >= 2 else { return 0 }
        return min((streak - 1) * 10, 50)
    }

    /// Wordle-style shareable result for a solved puzzle. Builds a compact grid
    /// where each revealed clue is a filled square and each unused clue is an
    /// empty square — fewer filled squares means a sharper guess.
    func shareText(for puzzle: BuildPuzzle) -> String {
        let total = max(puzzle.clues.count, 1)
        let used = min(max(puzzle.revealedClues, 1), total)
        let grid = (1...total)
            .map { $0 <= used ? "🟩" : "⬜️" }
            .joined()
        var lines = [
            "Bricky Build Puzzle",
            "Solved with \(used)/\(total) clue\(used == 1 ? "" : "s")",
            grid
        ]
        if currentStreak >= 2 {
            lines.append("Win streak: \(currentStreak)")
        }
        lines.append("Score +\(puzzle.score + lastStreakBonus)")
        return lines.joined(separator: "\n")
    }
}
