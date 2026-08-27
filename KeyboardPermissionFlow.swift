import Foundation

enum KeyboardMonitoringAvailability: Equatable {
    case permissionDenied
    case eventTapUnavailable
    case available
}

enum KeyboardPermissionPhase: Equatable {
    case needsAuthorization
    case restartRequired
    case repairRequired
    case monitoringUnavailable
    case available
}

struct KeyboardPermissionFlow {
    static func phase(
        availability: KeyboardMonitoringAvailability,
        requestPending: Bool,
        restartPending: Bool,
        launchedWithRestartPending: Bool,
        completedSettingsRoundTrip: Bool
    ) -> KeyboardPermissionPhase {
        switch availability {
        case .available:
            return .available

        case .eventTapUnavailable:
            if restartPending && launchedWithRestartPending {
                return .monitoringUnavailable
            }
            if requestPending || restartPending {
                return .restartRequired
            }
            return .monitoringUnavailable

        case .permissionDenied:
            if (restartPending && launchedWithRestartPending)
                || (requestPending && completedSettingsRoundTrip) {
                return .repairRequired
            }
            return .needsAuthorization
        }
    }
}
