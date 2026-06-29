import SwiftUI

/// Build puzzle game view — guess the build from progressive clues
struct PuzzleView: View {
    @ObservedObject private var engine = PuzzleEngine.shared
    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @State private var guessText = ""
    @State private var showWrongGuess = false
    @State private var answerChoices: [String] = []
    @State private var showConfetti = false
    @State private var showPaywall = false
    @State private var showShareSheet = false
    @State private var shareText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                DailyChallengeCard()

                FeatureTipView(
                    tip: .firstPuzzle,
                    icon: "puzzlepiece.fill",
                    title: "How Puzzles Work",
                    message: "Watch the mystery build come into focus as you reveal clues, then guess what it is. Fewer clues = higher score, and a win streak earns bonus points!",
                    color: .purple
                )

                headerSection

                if let puzzle = engine.currentPuzzle {
                    if puzzle.isGuessed {
                        revealedSection(puzzle)
                    } else {
                        puzzleSection(puzzle)
                    }
                } else {
                    startSection
                }

                packProgressSection

                if !engine.puzzleHistory.isEmpty {
                    historySection
                }
            }
            .padding()
        }
        .overlay {
            if showConfetti {
                PuzzleConfettiView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [shareText])
        }
        .navigationTitle("Build Puzzles")
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "puzzlepiece.fill")
                    .font(.title2)
                    .foregroundStyle(Color.legoRed)
                Text("Total Score: \(engine.totalScore)")
                    .font(.title3)
                    .fontWeight(.bold)
                Spacer()
                if engine.currentStreak >= 2 {
                    streakChip
                } else {
                    Text("\(engine.puzzleHistory.count) puzzles")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var streakChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.caption)
            Text("\(engine.currentStreak) streak")
                .font(.caption)
                .fontWeight(.bold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(
                LinearGradient(
                    colors: [.orange, .legoRed],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        )
    }

    /// Shows how many puzzles in the current pack the player has unlocked, and
    /// — for free players — an honest upsell to the full Pro puzzle pack.
    private var packProgressSection: some View {
        let limit = subscriptions.puzzlePoolLimit
        let solved = engine.solvedCount(inPackOf: limit)
        return VStack(spacing: 12) {
            HStack {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundStyle(Color.legoBlue)
                Text(subscriptions.isPro ? "Pro Puzzle Pack" : "Starter Puzzle Pack")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(solved)/\(limit) solved")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(min(solved, limit)), total: Double(limit))
                .tint(Color.legoBlue)

            if !subscriptions.isPro {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.open.fill")
                        Text("Unlock \(SubscriptionManager.proPuzzleLimit - SubscriptionManager.freePuzzleLimit) more puzzles with Pro")
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var startSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 60))
                .foregroundStyle(Color.legoRed.opacity(0.5))

            Text("Can you guess the build?")
                .font(.title3)
                .fontWeight(.semibold)

            Text("You'll get clues one at a time. Fewer clues = higher score!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                engine.generatePuzzle(poolLimit: subscriptions.puzzlePoolLimit)
                if let puzzle = engine.currentPuzzle {
                    answerChoices = engine.getAnswerChoices(for: puzzle)
                }
            } label: {
                Label("Start Puzzle", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.vertical, 20)
    }

    private func puzzleSection(_ puzzle: BuildPuzzle) -> some View {
        VStack(spacing: 16) {
            // Mosaic reveal — random squares uncovered with each hint.
            PuzzleMosaicRevealView(
                systemImage: puzzle.project.imageSystemName,
                gridSize: puzzle.gridSize,
                revealedCells: puzzle.revealedCells,
                isSolved: false,
                palette: engine.paletteColors(for: puzzle.project),
                category: puzzle.project.category,
                seed: abs(puzzle.project.name.hashValue)
            )

            // Color-palette hint derived from the build's required pieces.
            PuzzlePaletteHint(colors: engine.paletteColors(for: puzzle.project))

            // Clues revealed so far
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(puzzle.allRevealedClues.enumerated()), id: \.offset) { index, clue in
                    HStack(alignment: .top, spacing: 8) {
                        Text("Clue \(index + 1):")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.legoRed)
                            .frame(width: 55, alignment: .leading)
                        Text(clue)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Multiple choice answers
            VStack(spacing: 8) {
                ForEach(answerChoices, id: \.self) { choice in
                    Button {
                        submitChoice(choice)
                    } label: {
                        Text(choice)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue.opacity(0.1))
                            .foregroundStyle(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }

            if showWrongGuess {
                Text("Not quite! Try again or reveal another clue.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Action buttons
            HStack(spacing: 12) {
                if puzzle.canRevealMore {
                    Button {
                        engine.revealNextClue()
                        if let updated = engine.currentPuzzle {
                            answerChoices = engine.getAnswerChoices(for: updated)
                        }
                        showWrongGuess = false
                    } label: {
                        Label("Next Clue", systemImage: "lightbulb")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                }

                Button {
                    engine.giveUp()
                } label: {
                    Text("Give Up")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func revealedSection(_ puzzle: BuildPuzzle) -> some View {
        VStack(spacing: 16) {
            PuzzleMosaicRevealView(
                systemImage: puzzle.project.imageSystemName,
                gridSize: puzzle.gridSize,
                revealedCells: puzzle.revealedCells,
                isSolved: true,
                palette: engine.paletteColors(for: puzzle.project),
                category: puzzle.project.category,
                seed: abs(puzzle.project.name.hashValue)
            )

            Text(puzzle.project.name)
                .font(.title2)
                .fontWeight(.bold)

            // Real "built from these pieces" preview — rendered from the build's
            // actual required pieces, shown only after solving so it can't leak.
            PuzzlePiecesStrip(pieces: engine.featuredPieces(for: puzzle.project))

            if puzzle.score > 0 {
                VStack(spacing: 6) {
                    HStack {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text("+\(puzzle.score) points")
                            .font(.headline)
                            .foregroundStyle(Color.legoRed)
                    }
                    if engine.lastStreakBonus > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "flame.fill")
                                .foregroundStyle(.orange)
                            Text("+\(engine.lastStreakBonus) streak bonus (\(engine.currentStreak) in a row!)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } else {
                Text("Better luck next time!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(puzzle.project.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if puzzle.score > 0 {
                Button {
                    shareText = engine.shareText(for: puzzle)
                    showShareSheet = true
                } label: {
                    Label("Share Result", systemImage: "square.and.arrow.up")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            Button {
                engine.generatePuzzle(poolLimit: subscriptions.puzzlePoolLimit)
                if let newPuzzle = engine.currentPuzzle {
                    answerChoices = engine.getAnswerChoices(for: newPuzzle)
                }
                showWrongGuess = false
            } label: {
                Label("Next Puzzle", systemImage: "arrow.forward")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.vertical, 20)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Puzzles")
                .font(.headline)

            ForEach(engine.puzzleHistory.prefix(5)) { result in
                HStack {
                    Text(result.projectName)
                        .font(.subheadline)
                    Spacer()
                    Text("\(result.cluesUsed) clues")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("+\(result.score)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.legoRed)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func submitChoice(_ choice: String) {
        if engine.submitGuess(choice) {
            showWrongGuess = false
            HapticManager.notification(.success)
            triggerConfetti()
        } else {
            showWrongGuess = true
            HapticManager.notification(.error)
        }
    }

    private func triggerConfetti() {
        withAnimation { showConfetti = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            withAnimation { showConfetti = false }
        }
    }
}
