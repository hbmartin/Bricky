import Foundation
#if canImport(Metal)
import Metal
#endif

// Telemetry and variant types shared by the app, the MLX runtime, and the
// bricky-harness CLI. They live in the evidence kit, not in RecoveryMLX, so
// trace and benchmark rows can carry them without linking MLX. All fields
// are optional additions to the interchange format (no version bump), with
// snake_case keys spelled out.

/// Which tokens reach the model after a sampled token commits.
///
/// The pinned upstream loop feeds only the grammar's fast-forward tokens when
/// there are any, so the sampled token that preceded a multi-token forced
/// span (the opening quote of a key, the first letter of an enum value)
/// never enters the KV cache. `legacy` reproduces that exactly, so evidence
/// recorded on device replays byte-for-byte; `feedAll` feeds the sampled
/// token and then every forced token, one pass each. Which one ships is a
/// measured A/B decision (ADR 0010 amendment), not this file's.
public enum DecodeFeeding: String, Codable, CaseIterable, Sendable {
    case legacy
    case feedAll = "feed_all"
}

/// The decoding engine for one call. `upstream` runs the pinned
/// `GuidedGenerationLoop` itself — kept selectable so a pin bump can prove
/// the fork has not drifted (`RecoveryDecoderParityTests`).
public enum DecodeMode: String, Codable, CaseIterable, Sendable {
    case upstream
    case legacy
    case feedAll = "feed_all"

    public var feeding: DecodeFeeding? {
        switch self {
        case .upstream: nil
        case .legacy: .legacy
        case .feedAll: .feedAll
        }
    }
}

/// The pure feeding decision, isolated so it is testable without a model.
public enum FeedingPlan {
    public static func tokensToFeed(sampled: Int32, forced: [Int32], policy: DecodeFeeding) -> [Int32] {
        switch policy {
        case .legacy: forced.isEmpty ? [sampled] : forced
        case .feedAll: [sampled] + forced
        }
    }
}

/// What one guided call cost and how its cache was fed. Every count is
/// exact; the timings are wall-clock milliseconds.
public struct DecodeTelemetry: Codable, Sendable, Equatable {
    public var mode: DecodeMode
    /// Prompt length in tokens, image placeholders included.
    public var promptTokens: Int
    /// `<|image_pad|>` tokens in the prompt: what the image cost.
    public var imageTokens: Int?
    /// Image load, resize, and prompt templating before the model runs.
    public var preprocessMilliseconds: Int?
    public var prefillMilliseconds: Int
    public var decodeMilliseconds: Int
    /// Tokens the model chose.
    public var sampledTokens: Int
    /// Tokens the grammar forced (fast-forward).
    public var forcedTokens: Int
    /// Tokens run through the model after prefill, one forward pass each.
    public var fedTokens: Int
    /// Sampled tokens that were emitted but never entered the KV cache.
    public var droppedSampledTokens: Int
    /// The KV cache length when decoding ended.
    public var cacheOffset: Int?
    /// Fast-forward strings the host tokenizer re-encoded differently from
    /// the grammar's own tokens (xgrammar bridge counter).
    public var fastForwardDisagreements: Int
    /// Whether, at every sampling step, the KV cache held the prompt plus
    /// every token emitted so far. `feed_all` keeps this; `legacy` breaks it
    /// at the first forced span.
    public var cacheHeldEveryEmittedToken: Bool?
    /// Slot letters the unique-slots variant masked out (0 when off).
    public var maskedRepeatSlots: Int?

    /// What the cache would hold had every emitted token been fed: the
    /// invariant `feedAll` keeps and `legacy` breaks.
    public var emittedTokens: Int { sampledTokens + forcedTokens }

    public init(
        mode: DecodeMode, promptTokens: Int, imageTokens: Int?, preprocessMilliseconds: Int? = nil,
        prefillMilliseconds: Int, decodeMilliseconds: Int, sampledTokens: Int, forcedTokens: Int,
        fedTokens: Int, droppedSampledTokens: Int, cacheOffset: Int?, fastForwardDisagreements: Int,
        cacheHeldEveryEmittedToken: Bool? = nil, maskedRepeatSlots: Int? = nil
    ) {
        self.mode = mode
        self.promptTokens = promptTokens
        self.imageTokens = imageTokens
        self.preprocessMilliseconds = preprocessMilliseconds
        self.prefillMilliseconds = prefillMilliseconds
        self.decodeMilliseconds = decodeMilliseconds
        self.sampledTokens = sampledTokens
        self.forcedTokens = forcedTokens
        self.fedTokens = fedTokens
        self.droppedSampledTokens = droppedSampledTokens
        self.cacheOffset = cacheOffset
        self.fastForwardDisagreements = fastForwardDisagreements
        self.cacheHeldEveryEmittedToken = cacheHeldEveryEmittedToken
        self.maskedRepeatSlots = maskedRepeatSlots
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case promptTokens = "prompt_tokens"
        case imageTokens = "image_tokens"
        case preprocessMilliseconds = "preprocess_ms"
        case prefillMilliseconds = "prefill_ms"
        case decodeMilliseconds = "decode_ms"
        case sampledTokens = "sampled_tokens"
        case forcedTokens = "forced_tokens"
        case fedTokens = "fed_tokens"
        case droppedSampledTokens = "dropped_sampled_tokens"
        case cacheOffset = "cache_offset"
        case fastForwardDisagreements = "fast_forward_disagreements"
        case cacheHeldEveryEmittedToken = "cache_held_every_emitted_token"
        case maskedRepeatSlots = "masked_repeat_slots"
    }
}

/// The model's distribution over the grammar-legal tokens at one decision:
/// masked softmax over the legal set, recorded only where that set is small
/// (an enum value, a slot letter) so traces stay light. Sampling is greedy
/// and unchanged; the readout only records what the argmax chose between.
public struct DecisionReadout: Codable, Sendable, Equatable {
    public struct Candidate: Codable, Sendable, Equatable {
        public let token: Int
        public let text: String
        public let probability: Double

        public init(token: Int, text: String, probability: Double) {
            self.token = token
            self.text = text
            self.probability = probability
        }
    }

    /// Index of the generated token this decision produced.
    public let position: Int
    public let chosenToken: Int
    /// Legal candidates, most probable first.
    public let candidates: [Candidate]

    public init(position: Int, chosenToken: Int, candidates: [Candidate]) {
        self.position = position
        self.chosenToken = chosenToken
        self.candidates = candidates
    }

    enum CodingKeys: String, CodingKey {
        case position
        case chosenToken = "chosen_token"
        case candidates
    }

    /// Softmax over the given logits in double precision.
    public static func normalize(_ logits: [Float]) -> [Double] {
        guard let maximum = logits.max() else { return [] }
        let exponentials = logits.map { exp(Double($0) - Double(maximum)) }
        let total = exponentials.reduce(0, +)
        return exponentials.map { $0 / total }
    }

    /// The token ids a packed LSB-first bitmask allows, or nil when more than
    /// `limit` are legal (a structural position, not a decision worth
    /// recording).
    public static func legalTokens(mask: [Int32], vocabSize: Int, limit: Int) -> [Int]? {
        var ids: [Int] = []
        for (wordIndex, word) in mask.enumerated() {
            var bits = UInt32(bitPattern: word)
            while bits != 0 {
                let id = wordIndex * 32 + bits.trailingZeroBitCount
                bits &= bits - 1
                guard id < vocabSize else { continue }
                ids.append(id)
                if ids.count > limit { return nil }
            }
        }
        return ids
    }
}

/// The process's memory as jetsam sees it, from `task_vm_info`. The lifetime
/// peak comes from the kernel ledger, so a peak between two samples is not
/// missed the way polling `phys_footprint` misses it.
public struct ProcessMemorySnapshot: Codable, Sendable, Equatable {
    public let footprintBytes: Int64
    /// Highest `phys_footprint` this process has reached.
    public let lifetimePeakBytes: Int64?
    /// Bytes left before the memory limit (0 when the OS reports none).
    public let limitBytesRemaining: Int64?
    /// Graphics (Metal) memory charged to the footprint.
    public let graphicsFootprintBytes: Int64?

    public init(footprintBytes: Int64, lifetimePeakBytes: Int64?, limitBytesRemaining: Int64?, graphicsFootprintBytes: Int64?) {
        self.footprintBytes = footprintBytes
        self.lifetimePeakBytes = lifetimePeakBytes
        self.limitBytesRemaining = limitBytesRemaining
        self.graphicsFootprintBytes = graphicsFootprintBytes
    }

    public static func current() -> ProcessMemorySnapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Older kernels return a shorter struct; only read what they filled.
        let revision4 = mach_msg_type_number_t(
            (MemoryLayout<task_vm_info_data_t>.offset(of: \task_vm_info_data_t.limit_bytes_remaining)! + 8)
                / MemoryLayout<integer_t>.size
        )
        return ProcessMemorySnapshot(
            footprintBytes: Int64(info.phys_footprint),
            lifetimePeakBytes: info.ledger_phys_footprint_peak > 0 ? info.ledger_phys_footprint_peak : nil,
            limitBytesRemaining: count >= revision4 ? Int64(clamping: info.limit_bytes_remaining) : nil,
            graphicsFootprintBytes: info.ledger_tag_graphics_footprint > 0 ? info.ledger_tag_graphics_footprint : nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case footprintBytes = "footprint_bytes"
        case lifetimePeakBytes = "lifetime_peak_bytes"
        case limitBytesRemaining = "limit_bytes_remaining"
        case graphicsFootprintBytes = "graphics_footprint_bytes"
    }
}

public enum ThermalStateName {
    public static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    public static var current: String { name(ProcessInfo.processInfo.thermalState) }
}

/// What one inference call cost around the decoder: the decode telemetry,
/// memory and thermal state on either side, and where the call fell in the
/// loaded model's life (the first call after a load is the cold one).
public struct InferenceTelemetry: Codable, Sendable, Equatable {
    public var decode: DecodeTelemetry?
    public var memoryBefore: ProcessMemorySnapshot?
    public var memoryAfter: ProcessMemorySnapshot?
    /// `ProcessInfo.thermalState` names. They can read nominal while the
    /// device throttles, so decode throughput is recorded alongside.
    public var thermalBefore: String?
    public var thermalAfter: String?
    /// Calls this loaded container served before this one; 0 is cold.
    public var callsSinceLoad: Int?
    public var secondsSinceLoad: Double?
    /// How long the load that served this call took.
    public var loadMilliseconds: Int?
    /// generate or probe; with probe, `decode` describes the prefill only.
    public var scoring: ScoringMode?

    public init(
        decode: DecodeTelemetry? = nil, memoryBefore: ProcessMemorySnapshot? = nil,
        memoryAfter: ProcessMemorySnapshot? = nil, thermalBefore: String? = nil, thermalAfter: String? = nil,
        callsSinceLoad: Int? = nil, secondsSinceLoad: Double? = nil, loadMilliseconds: Int? = nil,
        scoring: ScoringMode? = nil
    ) {
        self.decode = decode
        self.memoryBefore = memoryBefore
        self.memoryAfter = memoryAfter
        self.thermalBefore = thermalBefore
        self.thermalAfter = thermalAfter
        self.callsSinceLoad = callsSinceLoad
        self.secondsSinceLoad = secondsSinceLoad
        self.loadMilliseconds = loadMilliseconds
        self.scoring = scoring
    }

    enum CodingKeys: String, CodingKey {
        case decode
        case memoryBefore = "memory_before"
        case memoryAfter = "memory_after"
        case thermalBefore = "thermal_before"
        case thermalAfter = "thermal_after"
        case callsSinceLoad = "calls_since_load"
        case secondsSinceLoad = "seconds_since_load"
        case loadMilliseconds = "load_ms"
        case scoring
    }
}

/// Device conditions around a recording: what the benchmark protocol buckets
/// and controls for (roadmap §4.5).
public struct DeviceConditions: Codable, Sendable, Equatable {
    public var thermalState: String
    public var lowPowerMode: Bool
    /// 0...1, or nil where the platform does not report it.
    public var batteryLevel: Double?
    /// unplugged, charging, full, or unknown.
    public var batteryState: String?
    /// Seconds since the current AR session started running; nil when none
    /// is running. The sustained bucket is ≥ 30 minutes of continuous AR.
    public var secondsSinceARStart: Double?
    /// Total AR running time this launch.
    public var arActiveSeconds: Double?

    public init(
        thermalState: String, lowPowerMode: Bool, batteryLevel: Double? = nil, batteryState: String? = nil,
        secondsSinceARStart: Double? = nil, arActiveSeconds: Double? = nil
    ) {
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.secondsSinceARStart = secondsSinceARStart
        self.arActiveSeconds = arActiveSeconds
    }

    enum CodingKeys: String, CodingKey {
        case thermalState = "thermal_state"
        case lowPowerMode = "low_power_mode"
        case batteryLevel = "battery_level"
        case batteryState = "battery_state"
        case secondsSinceARStart = "seconds_since_ar_start"
        case arActiveSeconds = "ar_active_seconds"
    }
}

/// The benchmark protocol's latency buckets. Gates move to the sustained
/// bucket once device rows exist; cold and warm are reported beside it.
public enum LatencyBucket: String, Codable, CaseIterable, Sendable {
    /// The first inference after the model loaded.
    case cold
    case warm
    /// At least `sustainedARSeconds` of continuous AR: the thermal regime a
    /// user 30 minutes into a build is actually in.
    case sustained

    public static let sustainedARSeconds: Double = 1_800

    public static func classify(callsSinceLoad: Int?, secondsSinceARStart: Double?) -> LatencyBucket {
        if let seconds = secondsSinceARStart, seconds >= sustainedARSeconds { return .sustained }
        return callsSinceLoad == 0 ? .cold : .warm
    }
}

/// Which variant of the VLM path produced a call (ADR 0010 amendment). Every
/// axis defaults to the shipping baseline; `id` names only the axes that
/// differ, so rows from the same arm always share one id.
public struct RecoveryInferenceVariant: Codable, Sendable, Equatable {
    public var decode: DecodeMode
    public var vote: RecoveryVoteRule
    /// Mask slot letters already emitted, so a ranking cannot repeat one
    /// (the rank schema's `uniqueItems` is ignored by the pinned xgrammar).
    public var uniqueSlots: Bool
    public var scoring: ScoringMode
    public var slotOrder: SlotOrder
    public var boardLayout: BoardLayoutVersion
    public var labels: TileLabelStyle
    public var promptStyle: PromptStyle
    /// The side the board is resized to before the vision encoder; 1024 is
    /// one image token per 32×32 block, 1,024 tokens.
    public var imageSide: Int
    /// Step checks only: which render the photo is compared against.
    public var checkTarget: CheckTarget
    /// A/B arm label when the developer arm picker scheduled this call.
    public var armID: String?
    /// A LoRA adapter loaded over the pinned weights (ADR 0019), as
    /// `<name>@<first 12 hex of its SHA-256>`. Nil is the pinned model alone.
    public var adapter: String?

    public static let baselineImageSide = 1_024

    public init(
        decode: DecodeMode = .legacy, vote: RecoveryVoteRule = .bordaDedup, uniqueSlots: Bool = false,
        scoring: ScoringMode = .generate, slotOrder: SlotOrder = .sorted, boardLayout: BoardLayoutVersion = .v1,
        labels: TileLabelStyle = .slotAndStep, promptStyle: PromptStyle = .baseline,
        imageSide: Int = RecoveryInferenceVariant.baselineImageSide, checkTarget: CheckTarget = .guideCamera,
        armID: String? = nil, adapter: String? = nil
    ) {
        self.decode = decode
        self.vote = vote
        self.uniqueSlots = uniqueSlots
        self.scoring = scoring
        self.slotOrder = slotOrder
        self.boardLayout = boardLayout
        self.labels = labels
        self.promptStyle = promptStyle
        self.imageSide = imageSide
        self.checkTarget = checkTarget
        self.armID = armID
        self.adapter = adapter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decode = try container.decodeIfPresent(DecodeMode.self, forKey: .decode) ?? .legacy
        vote = try container.decodeIfPresent(RecoveryVoteRule.self, forKey: .vote) ?? .bordaDedup
        uniqueSlots = try container.decodeIfPresent(Bool.self, forKey: .uniqueSlots) ?? false
        scoring = try container.decodeIfPresent(ScoringMode.self, forKey: .scoring) ?? .generate
        slotOrder = try container.decodeIfPresent(SlotOrder.self, forKey: .slotOrder) ?? .sorted
        boardLayout = try container.decodeIfPresent(BoardLayoutVersion.self, forKey: .boardLayout) ?? .v1
        labels = try container.decodeIfPresent(TileLabelStyle.self, forKey: .labels) ?? .slotAndStep
        promptStyle = try container.decodeIfPresent(PromptStyle.self, forKey: .promptStyle) ?? .baseline
        imageSide = try container.decodeIfPresent(Int.self, forKey: .imageSide) ?? Self.baselineImageSide
        checkTarget = try container.decodeIfPresent(CheckTarget.self, forKey: .checkTarget) ?? .guideCamera
        armID = try container.decodeIfPresent(String.self, forKey: .armID)
        adapter = try container.decodeIfPresent(String.self, forKey: .adapter)
    }

    public static let baseline = RecoveryInferenceVariant()

    /// A combination no call can honour.
    public struct InvalidCombination: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Throws for combinations that would run but measure nothing. A
    /// log-probability vote reads each view's slot distribution, which only
    /// probe scoring produces; with generated calls no view votes, and every
    /// session would quietly come out insufficient under this arm's id.
    public func validate() throws {
        if vote == .logprob, scoring != .probe {
            throw InvalidCombination(description: "vote=logprob needs scoring=probe: generated calls carry no slot probabilities")
        }
        if let adapter, !Self.isValidAdapterIdentity(adapter) {
            throw InvalidCombination(description: "adapter must be <name>@<12 hex>, name in [a-z0-9._-]: \(adapter)")
        }
    }

    /// `<name>@<12 lowercase hex>`, with the name in `[a-z0-9._-]`: nothing
    /// that could break `id`'s `axis=value,axis=value` form.
    public static func isValidAdapterIdentity(_ identity: String) -> Bool {
        let parts = identity.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].count == 12 else { return false }
        let nameOK = parts[0].unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || ".-_".unicodeScalars.contains(scalar)
        }
        let hashOK = parts[1].unicodeScalars.allSatisfy { scalar in
            ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar)
        }
        return nameOK && hashOK
    }

    public var id: String {
        var parts: [String] = []
        if decode != .legacy { parts.append("decode=\(decode.rawValue)") }
        if vote != .bordaDedup { parts.append("vote=\(vote.rawValue)") }
        if uniqueSlots { parts.append("unique_slots") }
        if scoring != .generate { parts.append("scoring=\(scoring.rawValue)") }
        if slotOrder != .sorted { parts.append("slot_order=\(slotOrder.rawValue)") }
        if boardLayout != .v1 { parts.append("board=\(boardLayout.rawValue)") }
        if labels != .slotAndStep { parts.append("labels=\(labels.rawValue)") }
        if promptStyle != .baseline { parts.append("prompt=\(promptStyle.rawValue)") }
        if imageSide != Self.baselineImageSide { parts.append("image_side=\(imageSide)") }
        if checkTarget != .guideCamera { parts.append("check_target=\(checkTarget.rawValue)") }
        if let adapter { parts.append("adapter=\(adapter)") }
        return parts.isEmpty ? "baseline" : parts.joined(separator: ",")
    }

    enum CodingKeys: String, CodingKey {
        case decode
        case vote
        case uniqueSlots = "unique_slots"
        case scoring
        case slotOrder = "slot_order"
        case boardLayout = "board_layout"
        case labels
        case promptStyle = "prompt_style"
        case imageSide = "image_side"
        case checkTarget = "check_target"
        case armID = "arm_id"
        case adapter
    }
}

/// How admission went for the model a session used: the floor it was
/// judged against and what loading and warming actually cost (ADR 0003).
public struct AdmissionSnapshot: Codable, Sendable, Equatable {
    public var floorBytes: Int64
    public var availableBytesAtCheck: Int64?
    public var footprintBeforeLoadBytes: Int64?
    public var loadMilliseconds: Int?
    public var warmUpMilliseconds: Int?
    /// Lifetime footprint peak after the warm-up inference.
    public var warmUpPeakBytes: Int64?
    /// Lifetime footprint peak just before the load. The peak never resets,
    /// so an earlier load or AR spike can already sit above what loading
    /// this model reaches.
    public var lifetimePeakBeforeLoadBytes: Int64?

    public init(
        floorBytes: Int64, availableBytesAtCheck: Int64? = nil, footprintBeforeLoadBytes: Int64? = nil,
        loadMilliseconds: Int? = nil, warmUpMilliseconds: Int? = nil, warmUpPeakBytes: Int64? = nil,
        lifetimePeakBeforeLoadBytes: Int64? = nil
    ) {
        self.floorBytes = floorBytes
        self.availableBytesAtCheck = availableBytesAtCheck
        self.footprintBeforeLoadBytes = footprintBeforeLoadBytes
        self.loadMilliseconds = loadMilliseconds
        self.warmUpMilliseconds = warmUpMilliseconds
        self.warmUpPeakBytes = warmUpPeakBytes
        self.lifetimePeakBeforeLoadBytes = lifetimePeakBeforeLoadBytes
    }

    /// What the load and warm-up added at their peak: the warm-up peak less
    /// the footprint before load (ADR 0003). Nil when the run cannot say,
    /// because the process had already peaked at least as high before the
    /// load, so the lifetime peak after warm-up is not this model's.
    public var modelPeakCostBytes: Int64? {
        guard let peak = warmUpPeakBytes, let before = footprintBeforeLoadBytes,
              let peakBefore = lifetimePeakBeforeLoadBytes, peak > peakBefore else { return nil }
        return peak - before
    }

    /// True when the inputs were recorded but an earlier peak hides the
    /// model's: profile again in a fresh process.
    public var isPeakMasked: Bool {
        warmUpPeakBytes != nil && footprintBeforeLoadBytes != nil
            && lifetimePeakBeforeLoadBytes != nil && modelPeakCostBytes == nil
    }

    enum CodingKeys: String, CodingKey {
        case floorBytes = "floor_bytes"
        case availableBytesAtCheck = "available_bytes_at_check"
        case footprintBeforeLoadBytes = "footprint_before_load_bytes"
        case loadMilliseconds = "load_ms"
        case warmUpMilliseconds = "warm_up_ms"
        case warmUpPeakBytes = "warm_up_peak_bytes"
        case lifetimePeakBeforeLoadBytes = "lifetime_peak_before_load_bytes"
    }
}

public extension DeviceIdentity {
    /// The OS build (e.g. "24A335"): the structured field the free-text
    /// `operating_system` string only embeds. Evals re-run per build because
    /// on-device system models are not pinned.
    static var osBuild: String? { sysctlString("kern.osversion") }

    /// The GPU architecture name Metal reports (e.g. "applegpu_g17p"),
    /// which is what decides kernel availability, not the marketing name.
    static var gpuArchitecture: String? {
        #if canImport(Metal)
        return MTLCreateSystemDefaultDevice()?.architecture.name
        #else
        return nil
        #endif
    }

    static var physicalMemoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }

    internal static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// How a VLM call reaches its decision (ADR 0010 amendment).
public enum ScoringMode: String, Codable, CaseIterable, Sendable {
    /// Greedy grammar-constrained generation of the full JSON answer.
    case generate
    /// One prefill over the prompt plus a canonical answer prefix, reading
    /// the masked distributions at the decision positions. No tokens are
    /// generated, so neither the duplicate-letter nor the cache-feeding
    /// defect can touch it, and the answer comes with probabilities.
    case probe
}

/// The probabilities a probe call read. `options` holds the decision's
/// values — slot letters for a rank, verdicts for a check — each the summed
/// masked-softmax mass of the legal tokens that begin it.
public struct ProbeReadout: Codable, Sendable, Equatable {
    /// Mass on `insufficient` at the status value (rank calls only).
    public let pInsufficient: Double?
    public let options: [String: Double]

    public init(pInsufficient: Double?, options: [String: Double]) {
        self.pInsufficient = pInsufficient
        self.options = options
    }

    /// Options, most probable first; ties in name order.
    public var ranked: [String] {
        options.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    enum CodingKeys: String, CodingKey {
        case pInsufficient = "p_insufficient"
        case options
    }
}

public enum ProbeScoring {
    /// Default decision threshold on P(insufficient). 0.5 reproduces what a
    /// greedy decoder would choose; the recorded distributions let offline
    /// analysis pick a better one without re-running inference.
    public static let insufficientThreshold = 0.5

    /// Sums candidate-token probability into the options each token can
    /// begin. A token matches an option when either is a prefix of the other
    /// (a sub-word start like "in", or the whole value); a token that could
    /// begin several options splits its mass evenly among them, and one that
    /// begins none is ignored. The result is renormalized over the options.
    public static func group(_ candidates: [(text: String, probability: Double)], options: [String]) -> [String: Double] {
        var mass = Dictionary(uniqueKeysWithValues: options.map { ($0, 0.0) })
        for candidate in candidates {
            let text = candidate.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let matches = options.filter { $0.hasPrefix(text) || text.hasPrefix($0) }
            guard !matches.isEmpty else { continue }
            for option in matches {
                mass[option, default: 0] += candidate.probability / Double(matches.count)
            }
        }
        let total = mass.values.reduce(0, +)
        guard total > 0 else { return mass }
        return mass.mapValues { $0 / total }
    }
}
