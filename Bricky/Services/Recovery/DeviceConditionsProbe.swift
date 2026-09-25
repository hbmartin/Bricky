import Foundation
import UIKit

/// Snapshots the conditions the benchmark protocol controls for: thermal
/// state, Low Power Mode, battery, and continuous AR time.
enum DeviceConditionsProbe {
    @MainActor
    static func snapshot(clock: ARActivityClock = .shared) -> DeviceConditions {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }
        return DeviceConditions(
            thermalState: ThermalStateName.current,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryLevel: device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil,
            batteryState: batteryStateName(device.batteryState),
            secondsSinceARStart: clock.secondsSinceStart,
            arActiveSeconds: clock.activeSeconds
        )
    }

    static func batteryStateName(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unplugged: "unplugged"
        case .charging: "charging"
        case .full: "full"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }
}
