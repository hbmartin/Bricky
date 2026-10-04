import Foundation

/// Chooses which VLM-path variant a device recovery runs, for on-device A/B
/// rows (ADR 0010 amendment). Developer-only: without the evidence toggle
/// every call runs the baseline, so no user ever sees an experimental arm.
///
/// Two modes run on device. `single` runs the variant every time;
/// `interleave` alternates control and variant (control first), which is
/// how device latency and thermal rows must be collected: interleaved, so
/// drift hits both arms alike. Paired comparison on identical evidence is a
/// Mac job — replay one bundle through both arms (`compare_arms.py`) —
/// because running both arms per recovery on device would double the
/// inference and contaminate the very latency being measured.
struct InferenceArmScheduler {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case off
        case single
        case interleave
    }

    struct Plan: Codable, Equatable, Sendable {
        var mode: Mode = .off
        var variant = RecoveryInferenceVariant.baseline
    }

    static let controlArm = "A"
    static let variantArm = "B"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var plan: Plan {
        get {
            guard let data = defaults.data(forKey: AppConfig.Defaults.inferenceArmPlan),
                  let plan = try? JSONDecoder().decode(Plan.self, from: data) else { return Plan() }
            return plan
        }
        nonmutating set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: AppConfig.Defaults.inferenceArmPlan)
        }
    }

    /// The variant for the next recovery (or check), advancing the
    /// interleave counter.
    func next(evidenceEnabled: Bool) -> RecoveryInferenceVariant {
        let plan = plan
        guard evidenceEnabled, plan.mode != .off else { return .baseline }
        switch plan.mode {
        case .off:
            return .baseline
        case .single:
            var variant = plan.variant
            variant.armID = Self.variantArm
            return variant
        case .interleave:
            let counter = defaults.integer(forKey: AppConfig.Defaults.inferenceArmCounter)
            defaults.set(counter + 1, forKey: AppConfig.Defaults.inferenceArmCounter)
            if counter.isMultiple(of: 2) {
                var control = RecoveryInferenceVariant.baseline
                control.armID = Self.controlArm
                return control
            }
            var variant = plan.variant
            variant.armID = Self.variantArm
            return variant
        }
    }
}
