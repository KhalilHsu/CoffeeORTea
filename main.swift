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

    private let chipAddress: UInt32 = 0x37
    private let hostAddress: UInt8 = 0x51
    private let destAddress: UInt8 = 0x6E

    private let vcpBrightness: UInt8 = 0x10
    private let vcpPowerMode: UInt8 = 0xD6

    static let powerOn: UInt16 = 0x01
    static let powerOff: UInt16 = 0x04

    private init() {}

    private func checksum(_ data: [UInt8]) -> UInt8 {
        return ([destAddress, hostAddress] + data).reduce(UInt8(0)) { $0 ^ $1 }
    }

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

    func readVCPFeature(service: CFTypeRef, vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        #if arch(arm64)
        var requestData: [UInt8] = [0x82, 0x01, vcp]
        requestData.append(checksum(requestData))

        let writeResult = IOAVServiceWriteI2C(
            service, chipAddress, UInt32(hostAddress),
            &requestData, UInt32(requestData.count)
        )
        guard writeResult == KERN_SUCCESS else { return nil }

        usleep(50000)

        var reply = [UInt8](repeating: 0, count: 11)
        let readResult = IOAVServiceReadI2C(
            service, chipAddress, UInt32(hostAddress),
            &reply, UInt32(reply.count)
        )
        guard readResult == KERN_SUCCESS else { return nil }

        if reply.count >= 11 && reply[0] == 0x6E && reply[2] == 0x02 {
            guard reply[3] == 0x00 else { return nil }
            let maxVal = (UInt16(reply[6]) << 8) | UInt16(reply[7])
            let curVal = (UInt16(reply[8]) << 8) | UInt16(reply[9])
            if maxVal > 0 { return (current: curVal, max: maxVal) }
        }
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

    func setVCPFeature(service: CFTypeRef, vcp: UInt8, value: UInt16) -> Bool {
        #if arch(arm64)
        let highByte = UInt8((value >> 8) & 0xFF)
        let lowByte = UInt8(value & 0xFF)

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

    func readBrightness(service: CFTypeRef) -> (current: UInt16, max: UInt16)? {
        return readVCPFeature(service: service, vcp: vcpBrightness)
    }

    func setBrightness(service: CFTypeRef, value: UInt16) -> Bool {
        return setVCPFeature(service: service, vcp: vcpBrightness, value: min(value, 100))
    }

    func displayPowerOff(service: CFTypeRef) -> Bool {
        let result = setVCPFeature(service: service, vcp: vcpPowerMode, value: DDCManager.powerOff)
        if result { print("DDCManager: Sent display power OFF command") }
        return result
    }

    func displayPowerOn(service: CFTypeRef) -> Bool {
        let result = setVCPFeature(service: service, vcp: vcpPowerMode, value: DDCManager.powerOn)
        if result { print("DDCManager: Sent display power ON command") }
        return result
    }
}

// MARK: - GammaManager (software brightness fallback)

class GammaManager {
    static let shared = GammaManager()

    private var savedGammas: [CGDirectDisplayID: (
        red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue], count: UInt32
    )] = [:]

    private init() {}

    func dimDisplay(displayID: CGDirectDisplayID) {
        let sampleCount: UInt32 = 256
        var red = [CGGammaValue](repeating: 0, count: Int(sampleCount))
        var green = [CGGammaValue](repeating: 0, count: Int(sampleCount))
        var blue = [CGGammaValue](repeating: 0, count: Int(sampleCount))
        var actualCount: UInt32 = 0

        if CGGetDisplayTransferByTable(displayID, sampleCount, &red, &green, &blue, &actualCount) == .success {
            savedGammas[displayID] = (red, green, blue, actualCount)
        }

        CGSetDisplayTransferByFormula(displayID, 0, 0, 1, 0, 0, 1, 0, 0, 1)
        print("GammaManager: Dimmed display \(displayID)")
    }

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

enum DimMethod {
    case displayServices(savedBrightness: Float)
    case gamma
}

struct DDCDisplayState {
    let service: CFTypeRef
    let savedBrightness: UInt16
    let wasPoweredOff: Bool
}

class BrightnessManager {
    static let shared = BrightnessManager()

    private var displayServicesHandle: UnsafeMutableRawPointer?
    private var setBrightnessFunc: DisplayServicesSetBrightnessType?
    private var getBrightnessFunc: DisplayServicesGetBrightnessType?

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

    func dimAllDisplays() {
        dimmedDisplays.removeAll()
        dimmedDDCServices.removeAll()

        let displays = getActiveDisplays()
        var externalDisplays: [CGDirectDisplayID] = []

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

        for display in externalDisplays {
            GammaManager.shared.dimDisplay(displayID: display)
            dimmedDisplays[display] = .gamma
        }

        let avServices = DDCManager.shared.getExternalAVServices()
        for avService in avServices {
            var savedBrightness: UInt16 = 100
            if let reading = DDCManager.shared.readBrightness(service: avService) {
                savedBrightness = reading.current
                print("DDCManager: Saved brightness \(reading.current)/\(reading.max)")
            }

            let powerOffSuccess = DDCManager.shared.displayPowerOff(service: avService)
            dimmedDDCServices.append(DDCDisplayState(
                service: avService,
                savedBrightness: savedBrightness,
                wasPoweredOff: powerOffSuccess
            ))
        }
    }

    func restoreAllDisplays() {
        for state in dimmedDDCServices {
            if state.wasPoweredOff {
                _ = DDCManager.shared.displayPowerOn(service: state.service)
            }
        }

        if dimmedDDCServices.contains(where: { $0.wasPoweredOff }) {
            usleep(800000)
        }

        for state in dimmedDDCServices {
            _ = DDCManager.shared.setBrightness(service: state.service, value: state.savedBrightness)
        }
        dimmedDDCServices.removeAll()

        for (display, method) in dimmedDisplays {
            switch method {
            case .displayServices(let saved):
                setBrightness(displayID: display, level: saved)
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

    private let distanceThreshold: CGFloat = 500.0
    private let distanceTimeWindow: TimeInterval = 3.0
    private let keyPressesRequired: Int = 3
    private let keyTimeWindow: TimeInterval = 2.0
    private let checkInterval: TimeInterval = 0.1

    func startMonitoring(callback: @escaping () -> Void) {
        stopMonitoring()

        onTrigger = callback
        lastMousePosition = NSEvent.mouseLocation
        cumulativeDistance = 0.0
        distanceWindowStart = Date()
        keyPressTimestamps = []

        mouseCheckTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkMousePosition()
        }

        keyEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.handleKeyPress()
        }

        print("InputMonitor: Started")
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

        guard distance > 1.0 else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(distanceWindowStart)

        if elapsed > distanceTimeWindow {
            cumulativeDistance = distance
            distanceWindowStart = now
        } else {
            cumulativeDistance += distance
        }

        if cumulativeDistance >= distanceThreshold {
            print("InputMonitor: Mouse threshold reached (\(Int(cumulativeDistance))px)")
            trigger()
        }
    }

    private func handleKeyPress() {
        let now = Date()
        keyPressTimestamps.append(now)
        keyPressTimestamps = keyPressTimestamps.filter { now.timeIntervalSince($0) <= keyTimeWindow }

        if keyPressTimestamps.count >= keyPressesRequired {
            print("InputMonitor: Key press threshold reached")
            trigger()
        }
    }

    private func trigger() {
        let callback = onTrigger
        stopMonitoring()
        DispatchQueue.main.async { callback?() }
    }
}

// MARK: - ToggleMenuItemView (custom NSSwitch toggle for menu bar)

class ToggleMenuItemView: NSView {
    let toggleSwitch = NSSwitch()
    private let sleepLabel = NSTextField(labelWithString: "💤 Sleep")
    private let coffeeLabel = NSTextField(labelWithString: "☕️ Coffee")
    private let statusLabel = NSTextField(labelWithString: "")

    var onToggle: ((Bool) -> Void)?

    var isOn: Bool {
        get { toggleSwitch.state == .on }
        set {
            toggleSwitch.state = newValue ? .on : .off
            updateAppearance()
        }
    }

    var statusText: String = "" {
        didSet {
            statusLabel.stringValue = statusText
            statusLabel.isHidden = statusText.isEmpty
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        // Configure text labels
        for label in [sleepLabel, coffeeLabel] {
            label.isBezeled = false
            label.drawsBackground = false
            label.isEditable = false
            label.isSelectable = false
            label.font = .systemFont(ofSize: 13, weight: .medium)
        }

        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.isHidden = true

        toggleSwitch.target = self
        toggleSwitch.action = #selector(switchToggled(_:))

        addSubview(sleepLabel)
        addSubview(toggleSwitch)
        addSubview(coffeeLabel)
        addSubview(statusLabel)

        // Auto Layout
        sleepLabel.translatesAutoresizingMaskIntoConstraints = false
        toggleSwitch.translatesAutoresizingMaskIntoConstraints = false
        coffeeLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            sleepLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            sleepLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            toggleSwitch.centerXAnchor.constraint(equalTo: centerXAnchor),
            toggleSwitch.centerYAnchor.constraint(equalTo: sleepLabel.centerYAnchor),

            coffeeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            coffeeLabel.centerYAnchor.constraint(equalTo: sleepLabel.centerYAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: toggleSwitch.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])

        updateAppearance()
    }

    private func updateAppearance() {
        let active = toggleSwitch.state == .on
        sleepLabel.textColor = active ? .tertiaryLabelColor : .labelColor
        coffeeLabel.textColor = active ? .labelColor : .tertiaryLabelColor
    }

    @objc private func switchToggled(_ sender: NSSwitch) {
        updateAppearance()
        onToggle?(sender.state == .on)
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var caffeinateProcess: Process?
    var timer: Timer?
    var endTime: Date?
    var selectedDurationName: String = "Indefinitely"

    // UI references
    var toggleView: ToggleMenuItemView?

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
        menu.autoenablesItems = false
        menu.delegate = self

        // ── Custom toggle switch ──
        let toggleItem = NSMenuItem()
        let toggle = ToggleMenuItemView()
        toggle.onToggle = { [weak self] isOn in
            guard let self = self else { return }
            if isOn {
                self.activate()
                // Revert if activation failed
                if self.caffeinateProcess == nil {
                    toggle.isOn = false
                    toggle.statusText = "Allowed to Sleep"
                }
            } else {
                self.deactivate()
            }
        }
        toggleItem.view = toggle
        self.toggleView = toggle
        toggle.statusText = "Allowed to Sleep"
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // ── Set Duration submenu (disabled by default when Sleep is active) ──
        let durationMenuItem = NSMenuItem(title: "Set Duration", action: nil, keyEquivalent: "")
        durationMenuItem.tag = 101
        durationMenuItem.isEnabled = false
        let durationSubmenu = NSMenu()
        durationSubmenu.autoenablesItems = false
        let durations = ["Indefinitely", "15 Minutes", "1 Hour", "3 Hours", "Until 8:00 AM"]
        for duration in durations {
            let item = NSMenuItem(title: duration, action: #selector(changeDuration(_:)), keyEquivalent: "")
            item.isEnabled = false
            item.state = (duration == selectedDurationName) ? .on : .off
            durationSubmenu.addItem(item)
        }
        durationMenuItem.submenu = durationSubmenu
        menu.addItem(durationMenuItem)

        // ── Blackout Mode toggle (disabled by default when Sleep is active) ──
        let blackoutItem = NSMenuItem(title: "Blackout Mode (Energy Saving)", action: #selector(toggleBlackoutMode(_:)), keyEquivalent: "")
        blackoutItem.tag = 102
        blackoutItem.isEnabled = false
        menu.addItem(blackoutItem)

        menu.addItem(NSMenuItem.separator())

        // ── About & Quit ──
        let aboutItem = NSMenuItem(title: "About KeepAwake", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.isEnabled = true
        menu.addItem(aboutItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let isCoffeeActive = caffeinateProcess != nil
        if let durationItem = menu.item(withTag: 101) {
            durationItem.isEnabled = isCoffeeActive
            durationItem.submenu?.items.forEach { $0.isEnabled = isCoffeeActive }
        }
        if let blackoutItem = menu.item(withTag: 102) {
            blackoutItem.isEnabled = isCoffeeActive
        }
        if !isCoffeeActive {
            toggleView?.statusText = "Allowed to Sleep"
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.tag == 101 || menuItem.tag == 102 {
            return caffeinateProcess != nil
        }
        return true
    }

    @objc func changeDuration(_ sender: NSMenuItem) {
        selectedDurationName = sender.title

        // Update checkmarks in submenu
        if let submenu = sender.menu {
            for item in submenu.items {
                item.state = (item.title == selectedDurationName) ? .on : .off
            }
        }

        // Activate/reactivate with new duration (also turns on Coffee if off)
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

        if caffeinateProcess == nil {
            activate()
        }

        BrightnessManager.shared.dimAllDisplays()

        inputMonitor.startMonitoring { [weak self] in
            self?.disableBlackoutMode(autoRestored: true)
        }

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

        inputMonitor.stopMonitoring()
        BrightnessManager.shared.restoreAllDisplays()

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
            toggleView?.isOn = false
            toggleView?.statusText = ""
            return
        }

        // Timer setup
        if let seconds = getDurationSeconds() {
            startTimer(seconds: seconds)
        } else {
            timer?.invalidate()
            timer = nil
            endTime = nil
            if let button = statusItem.button {
                button.title = "☕️"
            }
            toggleView?.statusText = selectedDurationName
        }

        // Update toggle and menu state
        toggleView?.isOn = true

        // Enable Set Duration and Blackout Mode options
        if let durationItem = statusItem.menu?.item(withTag: 101) {
            durationItem.isEnabled = true
            durationItem.submenu?.items.forEach { $0.isEnabled = true }
        }
        if let blackoutItem = statusItem.menu?.item(withTag: 102) {
            blackoutItem.isEnabled = true
        }

        showNotification(title: "Keep Awake Activated", body: "Mac will stay awake: \(selectedDurationName)")
    }

    func deactivate() {
        // Automatically exit Blackout Mode when deactivating
        disableBlackoutMode()

        killCaffeinate()
        timer?.invalidate()
        timer = nil
        endTime = nil

        // Update menu bar icon
        if let button = statusItem.button {
            button.title = "💤"
        }

        // Update toggle and menu state
        toggleView?.isOn = false
        toggleView?.statusText = "Allowed to Sleep"

        // Disable Set Duration and Blackout Mode options
        if let durationItem = statusItem.menu?.item(withTag: 101) {
            durationItem.isEnabled = false
            durationItem.submenu?.items.forEach { $0.isEnabled = false }
        }
        if let blackoutItem = statusItem.menu?.item(withTag: 102) {
            blackoutItem.isEnabled = false
            blackoutItem.state = .off
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
                let timeStr = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
                button.title = "☕️ " + timeStr
                toggleView?.statusText = timeStr + " remaining"
            } else {
                let timeStr = String(format: "%02d:%02d", minutes, seconds)
                button.title = "☕️ " + timeStr
                toggleView?.statusText = timeStr + " remaining"
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
        Version 1.2.0
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
