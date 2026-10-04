import Foundation

/// The single runtime gate for the whole app (ADR 0012, amended 2026-09-25):
/// iPhone 17 Pro and iPhone 17 Pro Max, or a later Pro-class iPhone.
///
/// Those are the only LiDAR iPhones with 12 GB of memory and the A19 Pro, so
/// they are one hardware tier to test and measure. The iPhone 17 and iPhone
/// Air share the generation but have no LiDAR; LiDAR models before the 17
/// Pro have 8 GB. No Info.plist capability key expresses either
/// requirement, so this check is the enforcement and App Store metadata
/// must state the floor.
struct DeviceFloor {
    struct Inputs: Equatable, Sendable {
        var hasLiDARAR: Bool
        /// Hardware identifier such as "iPhone18,1".
        var modelIdentifier: String
        var physicalMemoryBytes: UInt64
        var isiOSAppOnMac: Bool
    }

    enum Verdict: Equatable, Sendable {
        case supported
        case macNotSupported
        case noLiDAR
        case unsupportedModel(String)
        case insufficientMemory(UInt64)
    }

    /// iPhone18,1 and iPhone18,2 are the 17 Pro and 17 Pro Max.
    static let minimumIPhoneFamily = 18
    /// RECONSTRUCTED: 12 GB devices report roughly 12e9 bytes and 8 GB devices
    /// roughly 8e9 (community reports). The margin absorbs reporting
    /// differences until a 17 Pro reading confirms it.
    static let minimumPhysicalMemoryBytes: UInt64 = 10_000_000_000

    static func evaluate(_ inputs: Inputs) -> Verdict {
        // iPhone apps can run on Apple silicon Macs, which have no LiDAR
        // scanner the app could use.
        if inputs.isiOSAppOnMac { return .macNotSupported }
        guard inputs.hasLiDARAR else { return .noLiDAR }
        // LiDAR iPads running the app in compatibility mode land here: the
        // floor is iPhone-only, and an iPad cannot be excluded at install time.
        guard let family = iPhoneFamily(inputs.modelIdentifier), family >= minimumIPhoneFamily else {
            return .unsupportedModel(inputs.modelIdentifier)
        }
        guard inputs.physicalMemoryBytes >= minimumPhysicalMemoryBytes else {
            return .insufficientMemory(inputs.physicalMemoryBytes)
        }
        return .supported
    }

    /// The major number of an "iPhone<major>,<minor>" identifier.
    static func iPhoneFamily(_ identifier: String) -> Int? {
        guard identifier.hasPrefix("iPhone") else { return nil }
        let parts = identifier.dropFirst("iPhone".count).split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), Int(parts[1]) != nil else { return nil }
        return major
    }

    @MainActor
    static var currentInputs: Inputs {
        let process = ProcessInfo.processInfo
        // The Simulator's uname reports the host CPU; it names the simulated
        // device in its environment instead.
        let identifier = process.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? DeviceIdentity.modelIdentifier
        return Inputs(
            hasLiDARAR: ARCameraManager.isSupported,
            modelIdentifier: identifier,
            physicalMemoryBytes: process.physicalMemory,
            isiOSAppOnMac: process.isiOSAppOnMac
        )
    }

    @MainActor
    static var current: Verdict {
        #if DEBUG
        if let override = debugOverride {
            return override
        }
        #endif
        return evaluate(currentInputs)
    }

    #if DEBUG
    /// `-BrickyDeviceFloorOverride <verdict>` forces a verdict in Debug builds
    /// only, so UI tests can reach the app in the Simulator (which has no
    /// LiDAR) and can exercise the unsupported screen. Release builds always
    /// evaluate the real device.
    static var debugOverride: Verdict? {
        guard let value = UserDefaults.standard.string(forKey: "BrickyDeviceFloorOverride") else { return nil }
        switch value {
        case "supported": return .supported
        case "macNotSupported": return .macNotSupported
        case "noLiDAR": return .noLiDAR
        case "unsupportedModel": return .unsupportedModel("override")
        case "insufficientMemory": return .insufficientMemory(0)
        default: return nil
        }
    }
    #endif
}
