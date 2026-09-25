import Dispatch
import Foundation
import os
import RecoveryMLX

/// One reading of the process's memory from the kernel's own accounting:
/// `os_proc_available_memory()` and `task_vm_info.phys_footprint`. Never
/// MLX's allocator counters, which see only MLX's buffers and miss AR,
/// RealityKit, and the verifier's renders.
struct MemoryBudget: Equatable, Sendable {
    /// What the process may still allocate before the kernel's limit.
    let availableBytes: UInt64
    /// What the process holds now.
    let footprintBytes: UInt64

    /// The process's whole budget. Unlike `availableBytes`, which a loaded
    /// model consumes, it does not move when the model loads or unloads.
    var totalBytes: UInt64 { availableBytes + footprintBytes }

    static func current() -> MemoryBudget {
        MemoryBudget(
            availableBytes: UInt64(os_proc_available_memory()),
            footprintBytes: UInt64(max(0, ProcessMemorySnapshot.current()?.footprintBytes ?? 0))
        )
    }
}

/// VLM admission from the process budget (ADR 0003 amendment).
///
/// The model may use the budget minus everything else the process holds.
/// Re-checking with the model loaded therefore counts the model's own
/// resident bytes as its headroom rather than refusing it for them, and a
/// model already admitted keeps its admission until headroom falls a
/// margin below the floor, so AR's allocation churn cannot flap it.
struct MemoryGovernor: Sendable {
    enum Decision: Equatable, Sendable {
        case admit
        case refuse(shortfallBytes: UInt64)
    }

    let floorBytes: UInt64
    let hysteresisBytes: UInt64

    static let standard = MemoryGovernor(
        floorBytes: RecoveryModelManager.minimumAvailableMemory,
        hysteresisBytes: 256 * 1_024 * 1_024
    )

    /// Bytes the model may occupy. `modelResidentBytes` is what a loaded
    /// model already holds (0 when unloaded).
    func headroom(_ budget: MemoryBudget, modelResidentBytes: UInt64) -> UInt64 {
        let others = budget.footprintBytes - min(modelResidentBytes, budget.footprintBytes)
        return budget.totalBytes - min(others, budget.totalBytes)
    }

    func evaluate(_ budget: MemoryBudget, modelResidentBytes: UInt64, currentlyAdmitted: Bool) -> Decision {
        let threshold = currentlyAdmitted ? floorBytes - min(hysteresisBytes, floorBytes) : floorBytes
        let available = headroom(budget, modelResidentBytes: modelResidentBytes)
        return available >= threshold ? .admit : .refuse(shortfallBytes: threshold - available)
    }
}

/// What one critical-pressure unload measured: the budget when iOS warned,
/// and again 500 ms after the model was released, once the kernel has
/// reclaimed the pages.
struct PressureRelief: Equatable, Sendable {
    let before: MemoryBudget
    let after: MemoryBudget

    var freedBytes: Int64 { Int64(after.availableBytes) - Int64(before.availableBytes) }
}

enum MemoryPressureLevel: Sendable {
    case warning
    case critical
}

/// The system's memory-pressure notifications; a fake in tests.
@MainActor
protocol MemoryPressureSignaling: AnyObject {
    func start(_ handler: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void)
    func stop()
}

@MainActor
final class DispatchMemoryPressureSignal: MemoryPressureSignaling {
    private var source: DispatchSourceMemoryPressure?

    func start(_ handler: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void) {
        stop()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let event = self?.source?.data else { return }
                handler(event.contains(.critical) ? .critical : .warning)
            }
        }
        source.activate()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}

/// What the device's thermal state allows the VLM to start (ADR 0003
/// amendment). Geometric work is never withheld: it is what keeps recovery
/// available on a hot device, and it is far cheaper than a VLM pass.
enum InferencePolicy {
    enum Work: Sendable {
        /// A hierarchical recovery: six or more VLM calls back to back.
        case recovery
        /// One step-check call.
        case check
    }

    enum Decision: Equatable, Sendable {
        case allowed
        /// Run the geometric pass only; an inconclusive fit becomes
        /// `thermalDeferred` and the manual picker.
        case geometricOnly
        /// Start no VLM work at all.
        case deferred
    }

    static func decide(_ work: Work, thermal: ProcessInfo.ThermalState) -> Decision {
        switch thermal {
        case .nominal, .fair:
            return .allowed
        case .serious:
            // A single check is one call; a recovery would hold the GPU for
            // the length of the hierarchy while the device throttles.
            return work == .check ? .allowed : .geometricOnly
        case .critical:
            return work == .check ? .deferred : .geometricOnly
        @unknown default:
            return work == .check ? .deferred : .geometricOnly
        }
    }

    static let deferredCheckMessage = "Your iPhone is too warm to run the on-device check right now. Let it cool and try again, or advance the guide yourself."
}
