import Foundation

@main
struct KeyboardPermissionFlowTests {
    private static var failures: [String] = []

    static func main() {
        expect(
            .needsAuthorization,
            availability: .permissionDenied,
            requestPending: false,
            restartPending: false,
            launchedWithRestartPending: false,
            completedSettingsRoundTrip: false,
            scenario: "new install without permission"
        )
        expect(
            .needsAuthorization,
            availability: .permissionDenied,
            requestPending: true,
            restartPending: false,
            launchedWithRestartPending: false,
            completedSettingsRoundTrip: false,
            scenario: "settings opened but user has not returned"
        )
        expect(
            .repairRequired,
            availability: .permissionDenied,
            requestPending: true,
            restartPending: false,
            launchedWithRestartPending: false,
            completedSettingsRoundTrip: true,
            scenario: "stale grant after returning from settings"
        )
        expect(
            .restartRequired,
            availability: .eventTapUnavailable,
            requestPending: true,
            restartPending: false,
            launchedWithRestartPending: false,
            completedSettingsRoundTrip: true,
            scenario: "permission granted but current process cannot create an event tap"
        )
        expect(
            .monitoringUnavailable,
            availability: .eventTapUnavailable,
            requestPending: false,
            restartPending: false,
            launchedWithRestartPending: false,
            completedSettingsRoundTrip: false,
            scenario: "event tap failure unrelated to a permission change"
        )
        expect(
            .repairRequired,
            availability: .permissionDenied,
            requestPending: false,
            restartPending: true,
            launchedWithRestartPending: true,
            completedSettingsRoundTrip: true,
            scenario: "permission still denied after the requested restart"
        )
        expect(
            .monitoringUnavailable,
            availability: .eventTapUnavailable,
            requestPending: false,
            restartPending: true,
            launchedWithRestartPending: true,
            completedSettingsRoundTrip: true,
            scenario: "event tap still unavailable after the requested restart"
        )
        expect(
            .available,
            availability: .available,
            requestPending: true,
            restartPending: true,
            launchedWithRestartPending: true,
            completedSettingsRoundTrip: true,
            scenario: "working event tap clears all transitional state"
        )

        if failures.isEmpty {
            print("KeyboardPermissionFlowTests: 8 passed")
            return
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        exit(1)
    }

    private static func expect(
        _ expected: KeyboardPermissionPhase,
        availability: KeyboardMonitoringAvailability,
        requestPending: Bool,
        restartPending: Bool,
        launchedWithRestartPending: Bool,
        completedSettingsRoundTrip: Bool,
        scenario: String
    ) {
        let actual = KeyboardPermissionFlow.phase(
            availability: availability,
            requestPending: requestPending,
            restartPending: restartPending,
            launchedWithRestartPending: launchedWithRestartPending,
            completedSettingsRoundTrip: completedSettingsRoundTrip
        )
        if actual != expected {
            failures.append("\(scenario): expected \(expected), got \(actual)")
        }
    }
}
