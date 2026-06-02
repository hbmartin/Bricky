import Foundation

/// Centralized localized string access for Bricky.
/// Uses the String Catalog (Localizable.xcstrings) with keys for EN, ES, FR, DE, JA.
enum L10n {

    // MARK: - App
    static let appName = String(localized: "app.name")
    static let appTagline = String(localized: "app.tagline")
    static let appDescription = String(localized: "app.description")

    // MARK: - Home
    static let scanPieces = String(localized: "home.scanPieces")
    static let scanPiecesDescription = String(localized: "home.scanPieces.description")
    static let tryDemoMode = String(localized: "home.tryDemoMode")
    static let tryDemoModeDescription = String(localized: "home.tryDemoMode.description")
    static let currentSession = String(localized: "home.currentSession")
    static let savedInventories = String(localized: "home.savedInventories")
    static let howItWorks = String(localized: "home.howItWorks")

    // MARK: - Common
    static let continueAction = String(localized: "common.continue")
    static let done = String(localized: "common.done")
    static let cancel = String(localized: "common.cancel")
    static let save = String(localized: "common.save")
    static let delete = String(localized: "common.delete")
    static let share = String(localized: "common.share")
    static let settings = String(localized: "common.settings")

    // MARK: - Scanning
    static let scanTitle = String(localized: "scan.title")
    static let pointCamera = String(localized: "scan.pointCamera")
    static let analyzing = String(localized: "scan.analyzing")
    static let lightingWarning = String(localized: "scan.lightingWarning")

    static func piecesFound(_ count: Int) -> String {
        String(localized: "scan.piecesFound", defaultValue: "\(count) pieces found")
    }

    // MARK: - Catalog
    static let catalogTitle = String(localized: "catalog.title")
    static let catalogSearch = String(localized: "catalog.search")
    static let totalPieces = String(localized: "catalog.totalPieces")
    static let uniqueTypes = String(localized: "catalog.uniqueTypes")

    // MARK: - Builds
    static let buildsTitle = String(localized: "builds.title")
    static let overview = String(localized: "builds.overview")
    static let pieces = String(localized: "builds.pieces")
    static let instructions = String(localized: "builds.instructions")
    static let difficulty = String(localized: "builds.difficulty")
    static let time = String(localized: "builds.time")
    static let match = String(localized: "builds.match")
    static let about = String(localized: "builds.about")
    static let allPieces = String(localized: "builds.allPieces")
    static let missingPieces = String(localized: "builds.missingPieces")
    static let requiredPieces = String(localized: "builds.requiredPieces")
    static let buildComplete = String(localized: "builds.buildComplete")
    static let stepByStep3D = String(localized: "builds.3dStepByStep")
    static let viewIn3D = String(localized: "builds.viewIn3d")
    static let findInPile = String(localized: "builds.findInPile")
    static let favorites = String(localized: "builds.favorites")

    // MARK: - 3D Model
    static let preview3D = String(localized: "model.3dPreview")
    static let instructions3D = String(localized: "model.3dInstructions")
    static let exportSTL = String(localized: "model.exportSTL")

    // MARK: - Onboarding
    static let welcome = String(localized: "onboarding.welcome")
    static let getStarted = String(localized: "onboarding.getStarted")

    // MARK: - Results
    static let scanResults = String(localized: "results.scanResults")
    static let viewCatalog = String(localized: "results.viewCatalog")
    static let viewBuilds = String(localized: "results.viewBuilds")
    static let saveInventory = String(localized: "results.saveInventory")

    // MARK: - Accessibility
    static let addToFavorites = String(localized: "accessibility.addToFavorites")
    static let removeFromFavorites = String(localized: "accessibility.removeFromFavorites")
    static let shareBuild = String(localized: "accessibility.shareBuild")
}

// MARK: - LEGO Mosaic Generator

extension L10n {

    // UI strings
    static let mosaicTitle = String(
        localized: "mosaic.title",
        defaultValue: "Mosaic Studio"
    )
    static let mosaicHeadline = String(
        localized: "mosaic.headline",
        defaultValue: "Turn a Photo Into a LEGO Mosaic"
    )
    static let mosaicSubheadline = String(
        localized: "mosaic.subheadline",
        defaultValue: "Pick a photo and \(AppConfig.appName) builds a brick-by-brick mosaic with a parts list and printable instructions."
    )
    static let mosaicChoosePhoto = String(
        localized: "mosaic.choosePhoto",
        defaultValue: "Choose Photo"
    )
    static let mosaicChangePhoto = String(
        localized: "mosaic.changePhoto",
        defaultValue: "Change Photo"
    )
    static let mosaicTakePhoto = String(
        localized: "mosaic.takePhoto",
        defaultValue: "Take Photo"
    )
    static let mosaicMosaicSize = String(
        localized: "mosaic.mosaicSize",
        defaultValue: "Mosaic Size"
    )
    static let mosaicGenerate = String(
        localized: "mosaic.generate",
        defaultValue: "Generate Mosaic"
    )
    static let mosaicGenerating = String(
        localized: "mosaic.generating",
        defaultValue: "Generating Mosaic…"
    )
    static let mosaicSubmitting = String(
        localized: "mosaic.submitting",
        defaultValue: "Uploading Photo…"
    )
    static let mosaicResultTitle = String(
        localized: "mosaic.resultTitle",
        defaultValue: "Your Mosaic"
    )
    static let mosaicPartsList = String(
        localized: "mosaic.partsList",
        defaultValue: "Parts List"
    )
    static let mosaicTotalParts = String(
        localized: "mosaic.totalParts",
        defaultValue: "Total Parts"
    )
    static let mosaicDownloadModel = String(
        localized: "mosaic.downloadModel",
        defaultValue: "Share LDraw Model"
    )
    static let mosaicDownloadInstructions = String(
        localized: "mosaic.downloadInstructions",
        defaultValue: "Share Instructions PDF"
    )
    static let mosaicRegenerate = String(
        localized: "mosaic.regenerate",
        defaultValue: "Regenerate Mosaic"
    )
    static let mosaicPreview = String(
        localized: "mosaic.preview",
        defaultValue: "Preview"
    )
    static let mosaicViewMosaic = String(
        localized: "mosaic.viewMosaic",
        defaultValue: "Mosaic"
    )
    static let mosaicViewOriginal = String(
        localized: "mosaic.viewOriginal",
        defaultValue: "Original Photo"
    )
    static let mosaicOriginalUnavailable = String(
        localized: "mosaic.originalUnavailable",
        defaultValue: "Original photo unavailable"
    )

    // MARK: - AI Subject Recognition (Pro)

    static let recognitionTitle = String(
        localized: "recognition.title",
        defaultValue: "Who or What Is This?"
    )
    static let recognitionSubtitle = String(
        localized: "recognition.subtitle",
        defaultValue: "Identify celebrities, characters, famous places, landmarks, and musicians in a photo."
    )
    static let recognitionChoosePhoto = String(
        localized: "recognition.choosePhoto",
        defaultValue: "Choose Photo"
    )
    static let recognitionChangePhoto = String(
        localized: "recognition.changePhoto",
        defaultValue: "Change Photo"
    )
    static let recognitionTakePhoto = String(
        localized: "recognition.takePhoto",
        defaultValue: "Take Photo"
    )
    static let recognitionIdentify = String(
        localized: "recognition.identify",
        defaultValue: "Identify"
    )
    static let recognitionWorking = String(
        localized: "recognition.working",
        defaultValue: "Identifying…"
    )
    static let recognitionResultsTitle = String(
        localized: "recognition.resultsTitle",
        defaultValue: "Best Guesses"
    )
    static let recognitionConfidenceLabel = String(
        localized: "recognition.confidenceLabel",
        defaultValue: "Confidence"
    )
    static let recognitionEmptyTitle = String(
        localized: "recognition.emptyTitle",
        defaultValue: "Nothing Recognized"
    )
    static let recognitionEmptyMessage = String(
        localized: "recognition.emptyMessage",
        defaultValue: "We couldn't confidently identify a famous subject in this photo. Try a clearer shot."
    )
    static let recognitionUpsellTitle = String(
        localized: "recognition.upsellTitle",
        defaultValue: "A Bricky Pro Feature"
    )
    static let recognitionUpsellMessage = String(
        localized: "recognition.upsellMessage",
        defaultValue: "AI subject recognition is included with Bricky Pro. Upgrade to identify people, characters, and famous places."
    )
    static let recognitionUpgrade = String(
        localized: "recognition.upgrade",
        defaultValue: "Upgrade to Pro"
    )
    static let recognitionPrivacyNote = String(
        localized: "recognition.privacyNote",
        defaultValue: "Photos are sent securely for analysis and not stored. Identifications are AI best-guesses, not facts — especially for real people."
    )
    static func recognitionRemaining(_ count: Int) -> String {
        String(
            localized: "recognition.remaining",
            defaultValue: "\(count) left this month"
        )
    }
    static let recognitionErrorNotConfigured = String(
        localized: "recognition.error.notConfigured",
        defaultValue: "AI recognition isn't available right now. Please try again later."
    )
    static let recognitionErrorOffline = String(
        localized: "recognition.error.offline",
        defaultValue: "AI recognition needs an internet connection. Reconnect and try again."
    )
    static let recognitionErrorNotEntitled = String(
        localized: "recognition.error.notEntitled",
        defaultValue: "We couldn't verify your Bricky Pro subscription. Restore purchases in Settings and try again."
    )
    static let recognitionErrorQuotaExceeded = String(
        localized: "recognition.error.quota",
        defaultValue: "You've used all your AI recognitions for this month. Your allowance resets next month."
    )
    static let recognitionErrorImageEncoding = String(
        localized: "recognition.error.imageEncoding",
        defaultValue: "We couldn't process that photo. Try a different image."
    )
    static let recognitionErrorServer = String(
        localized: "recognition.error.server",
        defaultValue: "Recognition failed. Please try again in a moment."
    )

    static let mosaicStartOver = String(
        localized: "mosaic.startOver",
        defaultValue: "Start Over"
    )
    static let mosaicGenerateCaption = String(
        localized: "mosaic.generateCaption",
        defaultValue: "Generate Caption & Description"
    )
    static let mosaicRegenerateCaption = String(
        localized: "mosaic.regenerateCaption",
        defaultValue: "Regenerate"
    )
    static let mosaicCaptionLabel = String(
        localized: "mosaic.captionLabel",
        defaultValue: "Caption"
    )
    static let mosaicDescriptionLabel = String(
        localized: "mosaic.descriptionLabel",
        defaultValue: "Description"
    )
    static let mosaicCaptionSectionTitle = String(
        localized: "mosaic.captionSectionTitle",
        defaultValue: "Caption & Description"
    )
    static let mosaicTryAgain = String(
        localized: "mosaic.tryAgain",
        defaultValue: "Try Again"
    )
    static let mosaicProTitle = String(
        localized: "mosaic.proTitle",
        defaultValue: "Mosaic Studio Is a Pro Feature"
    )
    static let mosaicProMessage = String(
        localized: "mosaic.proMessage",
        defaultValue: "Upgrade to \(AppConfig.appName) Pro to turn your photos into buildable LEGO mosaics."
    )
    static let mosaicProBadge = String(
        localized: "mosaic.proBadge",
        defaultValue: "Pro"
    )
    static let mosaicColumnPart = String(
        localized: "mosaic.columnPart",
        defaultValue: "Part"
    )
    static let mosaicColumnColor = String(
        localized: "mosaic.columnColor",
        defaultValue: "Color"
    )
    static let mosaicColumnQty = String(
        localized: "mosaic.columnQty",
        defaultValue: "Qty"
    )

    static func mosaicGridSummary(_ width: Int, _ height: Int) -> String {
        String(
            localized: "mosaic.gridSummary",
            defaultValue: "\(width) × \(height) studs"
        )
    }

    // Error strings (surfaced by MosaicGenerationService.ServiceError)
    static let mosaicErrorImageEncoding = String(
        localized: "mosaic.error.imageEncoding",
        defaultValue: "Couldn't prepare that photo. Try a different image."
    )
    static let mosaicErrorUnreachable = String(
        localized: "mosaic.error.unreachable",
        defaultValue: "Can't reach the mosaic service. Check your connection and try again."
    )
    static let mosaicErrorNotReady = String(
        localized: "mosaic.error.notReady",
        defaultValue: "The mosaic isn't ready yet. Please wait a moment."
    )
    static let mosaicErrorDecoding = String(
        localized: "mosaic.error.decoding",
        defaultValue: "The mosaic service returned an unexpected response."
    )
    static let mosaicErrorArtifactURL = String(
        localized: "mosaic.error.artifactURL",
        defaultValue: "That mosaic file link is invalid."
    )
    static let mosaicErrorServerGeneric = String(
        localized: "mosaic.error.serverGeneric",
        defaultValue: "The mosaic service couldn't complete your request."
    )

    static func mosaicErrorServer(_ status: Int) -> String {
        String(
            localized: "mosaic.error.server",
            defaultValue: "The mosaic service returned an error (\(status))."
        )
    }
}
