import Cocoa
import Foundation
import UserNotifications
import IOKit

// MARK: - DisplayServices Private Framework (for built-in Apple displays)

typealias DisplayServicesSetBrightnessType = @convention(c) (CGDirectDisplayID, Float) -> Int32
typealias DisplayServicesGetBrightnessType = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

// MARK: - IOAVService Private API (DDC/CI on Apple Silicon)

#if arch(arm64)
@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32, _ inputBuffer: UnsafeMutableRawPointer, _ inputBufferSize: UInt32) -> IOReturn

@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32, _ outputBuffer: UnsafeMutableRawPointer, _ outputBufferSize: UInt32) -> IOReturn
#endif

// MARK: - DDCManager (DDC/CI protocol for external monitors)

class DDCManager {
    static let shared = DDCManager()

    private let chipAddress: UInt32 = 0x37       // DDC/CI I2C 7-bit slave address
    private let hostAddress: UInt8 = 0x51        // Host source address
    private let destAddress: UInt8 = 0x6E        // Display destination (0x37 << 1)

    // VCP codes
    private let vcpBrightness: UInt8 = 0x10      // Brightness
    private let vcpPowerMode: UInt8 = 0xD6       // Display Power Mode

    // Power mode values
    static let powerOn: UInt16 = 0x01
    static let powerOff: UInt16 = 0x04           // DPMS Off (standby, still accepts DDC)

    private init() {}

    /// DDC/CI checksum: XOR of destination address, host address, and all data bytes
    private func checksum(_ data: [UInt8]) -> UInt8 {
        return ([destAddress, hostAddress] + data).reduce(UInt8(0)) { $0 ^ $1 }
    }

    /// Find all IOAVService references for external displays (Apple Silicon only)
    func getExternalAVServices() -> [CFTypeRef] {
        #if arch(arm64)
        var services: [CFTypeRef] = []
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"),
            &iterator
        ) == KERN_SUCCESS else { return services }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let locationRef = IORegistryEntryCreateCFProperty(
                service, "Location" as CFString, kCFAllocatorDefault, 0
            ) {
                if let location = locationRef.takeRetainedValue() as? String,
                   location == "External" {
                    if let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service) {
                        services.append(avService.takeRetainedValue())
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return services
        #else
        return []
        #endif
    }

    // MARK: - Generic VCP Feature Read/Write

    /// Read a VCP feature value via DDC/CI
    func readVCPFeature(service: CFTypeRef, vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        #if arch(arm64)
        // Build Get VCP Feature request: [length=0x82, cmd=0x01, vcp, checksum]
        var requestData: [UInt8] = [0x82, 0x01, vcp]
        requestData.append(checksum(requestData))

        let writeResult = IOAVServiceWriteI2C(
            service, chipAddress, UInt32(hostAddress),
            &requestData, UInt32(requestData.count)
        )
        guard writeResult == KERN_SUCCESS else { return nil }

        usleep(50000)  // 50ms delay for display MCU processing

        // Read 11-byte reply
        var reply = [UInt8](repeating: 0, count: 11)
        let readResult = IOAVServiceReadI2C(
            service, chipAddress, UInt32(hostAddress),
            &reply, UInt32(reply.count)
        )
        guard readResult == KERN_SUCCESS else { return nil }

        // Parse reply - standard format:
        // [0x6E, 0x88, 0x02, result, vcp, type, maxH, maxL, curH, curL, cs]
        if reply.count >= 11 && reply[0] == 0x6E && reply[2] == 0x02 {
            guard reply[3] == 0x00 else { return nil }
            let maxVal = (UInt16(reply[6]) << 8) | UInt16(reply[7])
            let curVal = (UInt16(reply[8]) << 8) | UInt16(reply[9])
            if maxVal > 0 { return (current: curVal, max: maxVal) }
        }
        // Alternative format without source byte
        if reply.count >= 10 && reply[1] == 0x02 {
            guard reply[2] == 0x00 else { return nil }
            let maxVal = (UInt16(reply[5]) << 8) | UInt16(reply[6])
            let curVal = (UInt16(reply[7]) << 8) | UInt16(reply[8])
            if maxVal > 0 { return (current: curVal, max: maxVal) }
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Set a VCP feature value via DDC/CI, with 3 retries
    func setVCPFeature(service: CFTypeRef, vcp: UInt8, value: UInt16) -> Bool {
        #if arch(arm64)
        let highByte = UInt8((value >> 8) & 0xFF)
        let lowByte = UInt8(value & 0xFF)

        // Build Set VCP Feature command: [length=0x84, cmd=0x03, vcp, valH, valL, checksum]
        var data: [UInt8] = [0x84, 0x03, vcp, highByte, lowByte]
        data.append(checksum(data))

        for _ in 0..<3 {
            let result = IOAVServiceWriteI2C(
                service, chipAddress, UInt32(hostAddress),
                &data, UInt32(data.count)
            )
            if result == KERN_SUCCESS { return true }
            usleep(20000)
        }
        return false
        #else
        return false
        #endif
    }

    // MARK: - Convenience Methods

    /// Read current brightness (VCP 0x10)
    func readBrightness(service: CFTypeRef) -> (current: UInt16, max: UInt16)? {
        return readVCPFeature(service: service, vcp: vcpBrightness)
    }

    /// Set brightness (VCP 0x10)
    func setBrightness(service: CFTypeRef, value: UInt16) -> Bool {
        return setVCPFeature(service: service, vcp: vcpBrightness, value: min(value, 100))
    }

    /// Power off display via DPMS standby (VCP 0xD6 = 0x04)
    func displayPowerOff(service: CFTypeRef) -> Bool {
        let result = setVCPFeature(service: service, vcp: vcpPowerMode, value: DDCManager.powerOff)
        if result { print("DDCManager: Sent display power OFF command") }
        return result
    }

    /// Power on display (VCP 0xD6 = 0x01)
    func displayPowerOn(service: CFTypeRef) -> Bool {
        let result = setVCPFeature(service: service, vcp: vcpPowerMode, value: DDCManager.powerOn)
        if result { print("DDCManager: Sent display power ON command") }
        return result
    }
}

// MARK: - GammaManager (software brightness fallback for unsupported displays)

class GammaManager {
    static let shared = GammaManager()

    private var savedGammas: [CGDirectDisplayID: (
        red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue], count: UInt32
    )] = [:]

    private init() {}

    /// Dim a display by zeroing its gamma table (screen appears black, backlight stays on)
    func dimDisplay(displayID: CGDirectDisplayID) {
        // Save current gamma table
        let sampleCount: UInt32 = 256
        var red = [CGGammaValue](repeating: 0, count: Int(sampleCount))
        var green = [CGGammaValue](repeating: 0, count: Int(sampleCount))
        var blue = [CGGammaValue](repeating: 0, count: Int(sampleCount))
        var actualCount: UInt32 = 0

        if CGGetDisplayTransferByTable(displayID, sampleCount, &red, &green, &blue, &actualCount) == .success {
            savedGammas[displayID] = (red, green, blue, actualCount)
        }

        // Set gamma formula to produce black output (min=0, max=0, gamma=1 for each channel)
        CGSetDisplayTransferByFormula(displayID, 0, 0, 1, 0, 0, 1, 0, 0, 1)
        print("GammaManager: Dimmed display \(displayID)")
    }

    /// Restore a display's original gamma table
    func restoreDisplay(displayID: CGDirectDisplayID) {
        if let saved = savedGammas.removeValue(forKey: displayID) {
            CGSetDisplayTransferByTable(displayID, saved.count, saved.red, saved.green, saved.blue)
            print("GammaManager: Restored display \(displayID)")
        } else {
            CGDisplayRestoreColorSyncSettings()
            print("GammaManager: Restored ColorSync defaults for display \(displayID)")
        }
    }
}

// MARK: - BrightnessManager (unified brightness control)

/// Tracks how each display was dimmed for proper restoration
enum DimMethod {
    case displayServices(savedBrightness: Float)
    case gamma
}

/// Tracks DDC state per external display service
struct DDCDisplayState {
    let service: CFTypeRef
    let savedBrightness: UInt16
    let wasPoweredOff: Bool
}

class BrightnessManager {
    static let shared = BrightnessManager()

    // DisplayServices handles (for built-in Apple displays)
    private var displayServicesHandle: UnsafeMutableRawPointer?
    private var setBrightnessFunc: DisplayServicesSetBrightnessType?
    private var getBrightnessFunc: DisplayServicesGetBrightnessType?

    // State tracking
    var dimmedDisplays: [CGDirectDisplayID: DimMethod] = [:]
    var dimmedDDCServices: [DDCDisplayState] = []

    init() {
        displayServicesHandle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices",
            RTLD_LAZY
        )
        if let handle = displayServicesHandle {
            if let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") {
                setBrightnessFunc = unsafeBitCast(setSymbol, to: DisplayServicesSetBrightnessType.self)
            }
            if let getSymbol = dlsym(handle, "DisplayServicesGetBrightness") {
                getBrightnessFunc = unsafeBitCast(getSymbol, to: DisplayServicesGetBrightnessType.self)
            }
        }
    }

    func getBrightness(displayID: CGDirectDisplayID) -> Float {
        guard let getFunc = getBrightnessFunc else { return 1.0 }
        var brightness: Float = 0.0
        _ = getFunc(displayID, &brightness)
        return brightness
    }

    func setBrightness(displayID: CGDirectDisplayID, level: Float) {
        guard let setFunc = setBrightnessFunc else { return }
        _ = setFunc(displayID, level)
    }

    func getActiveDisplays() -> [CGDirectDisplayID] {
        let maxDisplays: UInt32 = 16
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        if CGGetActiveDisplayList(maxDisplays, &activeDisplays, &displayCount) == .success {
            return Array(activeDisplays.prefix(Int(displayCount)))
        }
        return [CGMainDisplayID()]
    }

    /// Dim all displays using the best available method for each
    ///
    /// Strategy:
    /// - Built-in displays → DisplayServices (hardware brightness to 0)
    /// - External displays → Gamma black (immediate visual blackout)
    ///                      + DDC power off (physically turns off monitor for real power savings)
    func dimAllDisplays() {
        dimmedDisplays.removeAll()
        dimmedDDCServices.removeAll()

        let displays = getActiveDisplays()
        var externalDisplays: [CGDirectDisplayID] = []

        // Step 1: Built-in displays → DisplayServices
        for display in displays {
            if CGDisplayIsBuiltin(display) != 0 {
                let saved = getBrightness(displayID: display)
                setBrightness(displayID: display, level: 0.0)
                dimmedDisplays[display] = .displayServices(savedBrightness: saved)
                print("BrightnessManager: Dimmed built-in display \(display) (saved: \(saved))")
            } else {
                externalDisplays.append(display)
            }
        }

        guard !externalDisplays.isEmpty else { return }

        // Step 2: External displays → Always apply gamma black first (instant visual effect)
        for display in externalDisplays {
            GammaManager.shared.dimDisplay(displayID: display)
            dimmedDisplays[display] = .gamma
        }
        print("BrightnessManager: Applied gamma blackout to \(externalDisplays.count) external display(s)")

        // Step 3: External displays → Also try DDC power off (real power savings)
        let avServices = DDCManager.shared.getExternalAVServices()
        for avService in avServices {
            // Save current brightness for later restore
            var savedBrightness: UInt16 = 100
            if let reading = DDCManager.shared.readBrightness(service: avService) {
                savedBrightness = reading.current
                print("DDCManager: Saved brightness \(reading.current)/\(reading.max)")
            } else {
                print("DDCManager: Could not read brightness, assuming 100")
            }

            // Send display power off command (DPMS standby)
            let powerOffSuccess = DDCManager.shared.displayPowerOff(service: avService)
            dimmedDDCServices.append(DDCDisplayState(
                service: avService,
                savedBrightness: savedBrightness,
                wasPoweredOff: powerOffSuccess
            ))

            if powerOffSuccess {
                print("BrightnessManager: External display powered off via DDC/CI")
            } else {
                print("BrightnessManager: DDC power off failed, gamma fallback is active")
            }
        }
    }

    /// Restore all dimmed displays to their original state
    func restoreAllDisplays() {
        // Step 1: DDC displays → power on first (takes time to initialize)
        for state in dimmedDDCServices {
            if state.wasPoweredOff {
                _ = DDCManager.shared.displayPowerOn(service: state.service)
            }
        }

        // Step 2: Wait for monitors to wake up if any were powered off
        if dimmedDDCServices.contains(where: { $0.wasPoweredOff }) {
            usleep(800000)  // 800ms for monitor to initialize after power on
        }

        // Step 3: Restore DDC brightness
        for state in dimmedDDCServices {
            if DDCManager.shared.setBrightness(service: state.service, value: state.savedBrightness) {
                print("BrightnessManager: Restored DDC brightness to \(state.savedBrightness)")
            }
        }
        dimmedDDCServices.removeAll()

        // Step 4: Restore gamma and DisplayServices displays
        for (display, method) in dimmedDisplays {
            switch method {
            case .displayServices(let saved):
                setBrightness(displayID: display, level: saved)
                print("BrightnessManager: Restored built-in display \(display) to \(saved)")
            case .gamma:
                GammaManager.shared.restoreDisplay(displayID: display)
            }
        }
        dimmedDisplays.removeAll()
    }
}

// MARK: - InputMonitor (safety auto-restore for Blackout Mode)

class InputMonitor {
    private var mouseCheckTimer: Timer?
    private var lastMousePosition: NSPoint = .zero
    private var cumulativeDistance: CGFloat = 0.0
    private var distanceWindowStart: Date = Date()
    private var keyPressTimestamps: [Date] = []
    private var keyEventMonitor: Any?
    private var onTrigger: (() -> Void)?

    // Thresholds
    private let distanceThreshold: CGFloat = 500.0     // 500 pixels cumulative
    private let distanceTimeWindow: TimeInterval = 3.0 // within 3 seconds
    private let keyPressesRequired: Int = 3            // 3 key presses
    private let keyTimeWindow: TimeInterval = 2.0      // within 2 seconds
    private let checkInterval: TimeInterval = 0.1      // check mouse every 100ms for accuracy

    func startMonitoring(callback: @escaping () -> Void) {
        stopMonitoring()

        onTrigger = callback
        lastMousePosition = NSEvent.mouseLocation
        cumulativeDistance = 0.0
        distanceWindowStart = Date()
        keyPressTimestamps = []

        // Timer-based mouse position tracking (no permissions needed)
        mouseCheckTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkMousePosition()
        }

        // Global keyboard event monitor (requires Accessibility permissions; degrades gracefully)
        keyEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.handleKeyPress()
        }

        print("InputMonitor: Started (mouse: \(Int(distanceThreshold))px/\(distanceTimeWindow)s, keys: \(keyPressesRequired)x/\(keyTimeWindow)s)")
    }

    func stopMonitoring() {
        mouseCheckTimer?.invalidate()
        mouseCheckTimer = nil
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        cumulativeDistance = 0.0
        keyPressTimestamps = []
        onTrigger = nil
    }

    private func checkMousePosition() {
        let currentPos = NSEvent.mouseLocation
        let dx = currentPos.x - lastMousePosition.x
        let dy = currentPos.y - lastMousePosition.y
        let distance = sqrt(dx * dx + dy * dy)
        lastMousePosition = currentPos

        // Only count meaningful movement (> 1 pixel, filters out sub-pixel jitter)
        guard distance > 1.0 else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(distanceWindowStart)

        if elapsed > distanceTimeWindow {
            // Reset sliding window
            cumulativeDistance = distance
            distanceWindowStart = now
        } else {
            cumulativeDistance += distance
        }

        if cumulativeDistance >= distanceThreshold {
            print("InputMonitor: Mouse threshold reached (\(Int(cumulativeDistance))px in \(String(format: "%.1f", elapsed))s)")
            trigger()
        }
    }

    private func handleKeyPress() {
        let now = Date()
        keyPressTimestamps.append(now)

        // Sliding window: remove timestamps outside the time window
        keyPressTimestamps = keyPressTimestamps.filter { now.timeIntervalSince($0) <= keyTimeWindow }

        if keyPressTimestamps.count >= keyPressesRequired {
            print("InputMonitor: Key press threshold reached (\(keyPressTimestamps.count)x in \(keyTimeWindow)s)")
            trigger()
        }
    }

    private func trigger() {
        let callback = onTrigger
        stopMonitoring()
        DispatchQueue.main.async { callback?() }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var caffeinateProcess: Process?
    var timer: Timer?
    var endTime: Date?
    var selectedDurationName: String = "Indefinitely"

    // Blackout Mode state
    var isBlackoutModeActive: Bool = false
    let inputMonitor = InputMonitor()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        requestNotificationPermission()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "💤"
        }

        constructMenu()
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    func constructMenu() {
        let menu = NSMenu()

        // Status display
        let statusItemMenu = NSMenuItem(title: "Status: Allowed to Sleep", action: nil, keyEquivalent: "")
        statusItemMenu.tag = 100
        menu.addItem(statusItemMenu)
        menu.addItem(NSMenuItem.separator())

        // Prevent Sleep toggle
        let toggleItem = NSMenuItem(title: "Prevent Sleep", action: #selector(toggleSleep(_:)), keyEquivalent: "")
        toggleItem.tag = 101
        menu.addItem(toggleItem)

        // Set Duration submenu
        let durationMenuItem = NSMenuItem(title: "Set Duration", action: nil, keyEquivalent: "")
        let durationSubmenu = NSMenu()
        let durations = ["Indefinitely", "15 Minutes", "1 Hour", "3 Hours", "Until 8:00 AM"]
        for duration in durations {
            let item = NSMenuItem(title: duration, action: #selector(changeDuration(_:)), keyEquivalent: "")
            item.state = (duration == selectedDurationName) ? .on : .off
            durationSubmenu.addItem(item)
        }
        durationMenuItem.submenu = durationSubmenu
        menu.addItem(durationMenuItem)

        // Blackout Mode toggle
        let blackoutItem = NSMenuItem(title: "Blackout Mode (Energy Saving)", action: #selector(toggleBlackoutMode(_:)), keyEquivalent: "")
        blackoutItem.tag = 102
        menu.addItem(blackoutItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About KeepAwake", action: #selector(showAbout(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func toggleSleep(_ sender: NSMenuItem) {
        if caffeinateProcess == nil {
            activate()
        } else {
            deactivate()
        }
    }

    @objc func changeDuration(_ sender: NSMenuItem) {
        selectedDurationName = sender.title

        // Update checkmarks in submenu
        if let submenu = statusItem.menu?.item(withTitle: "Set Duration")?.submenu {
            for item in submenu.items {
                item.state = (item.title == selectedDurationName) ? .on : .off
            }
        }

        // Reactivate with the new duration
        activate()
    }

    @objc func toggleBlackoutMode(_ sender: NSMenuItem) {
        if isBlackoutModeActive {
            disableBlackoutMode()
        } else {
            enableBlackoutMode()
        }
    }

    func enableBlackoutMode() {
        guard !isBlackoutModeActive else { return }
        isBlackoutModeActive = true

        // Ensure sleep prevention is also activated
        if caffeinateProcess == nil {
            activate()
        }

        // Dim all displays (gamma + DDC power off)
        BrightnessManager.shared.dimAllDisplays()

        // Start safety input monitoring for auto-restore
        inputMonitor.startMonitoring { [weak self] in
            self?.disableBlackoutMode(autoRestored: true)
        }

        // Update UI
        if let blackoutItem = statusItem.menu?.item(withTag: 102) {
            blackoutItem.state = .on
        }

        showNotification(
            title: "Blackout Mode Activated",
            body: "All screens powered off. Shake mouse rapidly or press any key 3x to restore."
        )
    }

    func disableBlackoutMode(autoRestored: Bool = false) {
        guard isBlackoutModeActive else { return }
        isBlackoutModeActive = false

        // Stop safety monitoring
        inputMonitor.stopMonitoring()

        // Restore all displays (DDC power on + gamma restore)
        BrightnessManager.shared.restoreAllDisplays()

        // Update UI
        if let blackoutItem = statusItem.menu?.item(withTag: 102) {
            blackoutItem.state = .off
        }

        if autoRestored {
            showNotification(
                title: "Blackout Mode Auto-Restored",
                body: "Screens restored due to detected user input."
            )
        } else {
            showNotification(
                title: "Blackout Mode Deactivated",
                body: "Screen brightness restored."
            )
        }
    }

    func getDurationSeconds() -> Double? {
        switch selectedDurationName {
        case "15 Minutes":
            return 15 * 60
        case "1 Hour":
            return 60 * 60
        case "3 Hours":
            return 3 * 60 * 60
        case "Until 8:00 AM":
            let calendar = Calendar.current
            let now = Date()
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = 8
            components.minute = 0
            components.second = 0

            guard let targetDateToday = calendar.date(from: components) else { return nil }
            var targetDate = targetDateToday
            if targetDate <= now {
                if let tomorrow = calendar.date(byAdding: .day, value: 1, to: targetDateToday) {
                    targetDate = tomorrow
                }
            }
            return targetDate.timeIntervalSince(now)
        default:
            return nil
        }
    }

    func activate() {
        killCaffeinate()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-dims", "-w", String(ProcessInfo.processInfo.processIdentifier)]

        do {
            try process.run()
            caffeinateProcess = process
        } catch {
            print("Failed to run caffeinate: \(error)")
            return
        }

        if let seconds = getDurationSeconds() {
            startTimer(seconds: seconds)
        } else {
            timer?.invalidate()
            timer = nil
            endTime = nil
            if let button = statusItem.button {
                button.title = "☕️"
            }
        }

        if let toggleItem = statusItem.menu?.item(withTag: 101) {
            toggleItem.state = .on
        }
        if let statusLabel = statusItem.menu?.item(withTag: 100) {
            statusLabel.title = "Status: Blocked Sleep (\(selectedDurationName))"
        }

        showNotification(title: "Keep Awake Activated", body: "Mac will stay awake: \(selectedDurationName)")
    }

    func deactivate() {
        // Automatically exit Blackout Mode when deactivating sleep prevention
        disableBlackoutMode()

        killCaffeinate()
        timer?.invalidate()
        timer = nil
        endTime = nil

        if let button = statusItem.button {
            button.title = "💤"
        }
        if let toggleItem = statusItem.menu?.item(withTag: 101) {
            toggleItem.state = .off
        }
        if let statusLabel = statusItem.menu?.item(withTag: 100) {
            statusLabel.title = "Status: Allowed to Sleep"
        }

        showNotification(title: "Keep Awake Deactivated", body: "Normal sleep settings restored.")
    }

    func startTimer(seconds: Double) {
        timer?.invalidate()
        endTime = Date().addingTimeInterval(seconds)
        updateTitle(remaining: seconds)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func tick() {
        guard let endTime = endTime else { return }
        let remaining = endTime.timeIntervalSinceNow
        if remaining <= 0 {
            deactivate()
        } else {
            updateTitle(remaining: remaining)
        }
    }

    func updateTitle(remaining: Double) {
        let remainingInt = Int(remaining)
        let hours = remainingInt / 3600
        let minutes = (remainingInt % 3600) / 60
        let seconds = remainingInt % 60

        if let button = statusItem.button {
            if hours > 0 {
                button.title = String(format: "☕️ %02d:%02d:%02d", hours, minutes, seconds)
            } else {
                button.title = String(format: "☕️ %02d:%02d", minutes, seconds)
            }
        }
    }

    func killCaffeinate() {
        if let process = caffeinateProcess {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            caffeinateProcess = nil
        }
    }

    func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)

        print("Notification - \(title): \(body)")
    }

    @objc func showAbout(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "About KeepAwake"
        alert.informativeText = """
        KeepAwake is a 100% native macOS menubar app that prevents your Mac from sleeping or locking.

        Includes Blackout Mode to safely dim displays to 0% for automated agents and Energy Saving.

        Features:
        • DDC/CI power control for external monitors
        • Gamma fallback for unsupported displays
        • Safety auto-restore via mouse/keyboard

        Built with Swift & AppKit.
        Version 1.1.0
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func quitApp(_ sender: NSMenuItem) {
        deactivate()
        NSApplication.shared.terminate(nil)
    }
}

// Programmatic entry point for custom single-file AppKit app
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
