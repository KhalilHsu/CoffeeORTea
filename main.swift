import Cocoa
import Foundation
import UserNotifications
import IOKit
import Darwin

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
        return setVCPFeature(service: service, vcp: vcpBrightness, value: value)
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

// MARK: - Persisted Blackout recovery state

struct GammaSnapshot: Codable {
    let displayID: UInt32
    let red: [Float]
    let green: [Float]
    let blue: [Float]
    let count: UInt32
}

struct BuiltInDisplaySnapshot: Codable {
    let displayID: UInt32
    let brightness: Float
}

struct DDCDisplaySnapshot: Codable {
    let index: Int
    let brightness: UInt16?
}

struct BlackoutRecoveryState: Codable {
    let builtInDisplays: [BuiltInDisplaySnapshot]
    let gammaDisplays: [GammaSnapshot]
    let ddcDisplays: [DDCDisplaySnapshot]
}

// MARK: - GammaManager (software brightness fallback)

class GammaManager {
    static let shared = GammaManager()

    private var savedGammas: [CGDirectDisplayID: (
        red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue], count: UInt32
    )] = [:]

    private init() {}

    func capture(displayID: CGDirectDisplayID) -> GammaSnapshot? {
        let sampleCount: UInt32 = 256
        var red = [CGGammaValue](repeating: 0, count: Int(sampleCount))
        var green = [CGGammaValue](repeating: 0, count: Int(sampleCount))
        var blue = [CGGammaValue](repeating: 0, count: Int(sampleCount))
        var actualCount: UInt32 = 0

        guard CGGetDisplayTransferByTable(displayID, sampleCount, &red, &green, &blue, &actualCount) == .success else {
            return nil
        }

        return GammaSnapshot(
            displayID: displayID,
            red: red,
            green: green,
            blue: blue,
            count: actualCount
        )
    }

    func remember(_ snapshot: GammaSnapshot) {
        savedGammas[CGDirectDisplayID(snapshot.displayID)] = (
            snapshot.red,
            snapshot.green,
            snapshot.blue,
            snapshot.count
        )
    }

    func dimDisplay(displayID: CGDirectDisplayID, snapshot: GammaSnapshot? = nil) {
        if let snapshot = snapshot ?? capture(displayID: displayID) {
            remember(snapshot)
        }
        CGSetDisplayTransferByFormula(displayID, 0, 0, 1, 0, 0, 1, 0, 0, 1)
        print("GammaManager: Dimmed display \(displayID)")
    }

    func restore(snapshot: GammaSnapshot) {
        let displayID = CGDirectDisplayID(snapshot.displayID)
        var red = snapshot.red
        var green = snapshot.green
        var blue = snapshot.blue
        CGSetDisplayTransferByTable(displayID, snapshot.count, &red, &green, &blue)
        print("GammaManager: Restored display \(displayID) from recovery state")
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
    let savedBrightness: UInt16?
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

    func dimAllDisplays(recoveryFile: URL) -> Bool {
        dimmedDisplays.removeAll()
        dimmedDDCServices.removeAll()

        let displays = getActiveDisplays()
        var builtInSnapshots: [BuiltInDisplaySnapshot] = []
        var gammaSnapshots: [GammaSnapshot] = []

        for display in displays {
            if CGDisplayIsBuiltin(display) != 0 {
                let saved = getBrightness(displayID: display)
                dimmedDisplays[display] = .displayServices(savedBrightness: saved)
                builtInSnapshots.append(BuiltInDisplaySnapshot(
                    displayID: display,
                    brightness: saved
                ))
            } else if let snapshot = GammaManager.shared.capture(displayID: display) {
                GammaManager.shared.remember(snapshot)
                dimmedDisplays[display] = .gamma
                gammaSnapshots.append(snapshot)
            }
        }

        var ddcSnapshots: [DDCDisplaySnapshot] = []
        let avServices = DDCManager.shared.getExternalAVServices()
        for (index, avService) in avServices.enumerated() {
            var savedBrightness: UInt16?
            if let reading = DDCManager.shared.readBrightness(service: avService) {
                savedBrightness = reading.current
                print("DDCManager: Saved brightness \(reading.current)/\(reading.max)")
            }

            dimmedDDCServices.append(DDCDisplayState(
                service: avService,
                savedBrightness: savedBrightness
            ))
            ddcSnapshots.append(DDCDisplaySnapshot(index: index, brightness: savedBrightness))
        }

        let recoveryState = BlackoutRecoveryState(
            builtInDisplays: builtInSnapshots,
            gammaDisplays: gammaSnapshots,
            ddcDisplays: ddcSnapshots
        )

        guard writeRecoveryState(recoveryState, to: recoveryFile) else {
            dimmedDisplays.removeAll()
            dimmedDDCServices.removeAll()
            return false
        }

        for (display, method) in dimmedDisplays {
            switch method {
            case .displayServices:
                setBrightness(displayID: display, level: 0.0)
                print("BrightnessManager: Dimmed built-in display \(display)")
            case .gamma:
                if let snapshot = gammaSnapshots.first(where: { $0.displayID == display }) {
                    GammaManager.shared.dimDisplay(displayID: display, snapshot: snapshot)
                }
            }
        }

        // Keep external displays connected for screenshots and Computer Use.
        // DDC brightness 0 is deliberately used instead of VCP power-off.
        for state in dimmedDDCServices {
            _ = DDCManager.shared.setBrightness(service: state.service, value: 0)
        }

        return true
    }

    func restoreAllDisplays() {
        for state in dimmedDDCServices {
            if let savedBrightness = state.savedBrightness {
                _ = DDCManager.shared.setBrightness(service: state.service, value: savedBrightness)
            }
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

    private func writeRecoveryState(_ state: BlackoutRecoveryState, to url: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("BrightnessManager: Failed to write recovery state: \(error)")
            return false
        }
    }

    func restoreFromRecoveryFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let state = try JSONDecoder().decode(BlackoutRecoveryState.self, from: data)

            let avServices = DDCManager.shared.getExternalAVServices()
            for snapshot in state.ddcDisplays {
                guard snapshot.index < avServices.count,
                      let savedBrightness = snapshot.brightness else { continue }
                _ = DDCManager.shared.setBrightness(
                    service: avServices[snapshot.index],
                    value: savedBrightness
                )
            }

            for snapshot in state.builtInDisplays {
                setBrightness(
                    displayID: CGDirectDisplayID(snapshot.displayID),
                    level: snapshot.brightness
                )
            }

            for snapshot in state.gammaDisplays {
                GammaManager.shared.restore(snapshot: snapshot)
            }
            print("BrightnessManager: Restored displays from recovery state")
        } catch {
            print("BrightnessManager: Failed to restore recovery state: \(error)")
        }
    }
}

// MARK: - BlackoutWatchdog (best-effort crash recovery)

final class BlackoutWatchdog {
    static func run(recoveryFile: URL, parentPID: pid_t) {
        while processIsAlive(parentPID) {
            usleep(200_000)
        }

        guard FileManager.default.fileExists(atPath: recoveryFile.path) else { return }
        BrightnessManager.shared.restoreFromRecoveryFile(recoveryFile)
        try? FileManager.default.removeItem(at: recoveryFile)
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
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

// MARK: - Localization (i18n)

enum Language: String {
    case en, zh
}

struct L10n {
    static let current: Language = {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh") {
            return .zh
        }
        return .en
    }()

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    }
    
    // Use this helper for all localized strings
    static func localized(_ en: String, zh: String) -> String {
        switch current {
        case .zh: return zh
        case .en: return en
        }
    }
    
    // MARK: - Toggle View
    static var sleepLabel: String { localized("💤 Sleep", zh: "💤 睡眠") }
    static var coffeeLabel: String { localized("☕️ Coffee", zh: "☕️ 咖啡") }
    static var allowedToSleep: String { localized("Normal system sleep", zh: "按系统设置休眠") }
    
    // MARK: - Menu Items
    static var setDuration: String { localized("Set Duration", zh: "设置时长") }
    static var blackoutMode: String { localized("Blackout Mode (Energy Saving)", zh: "息屏模式（省电）") }
    static var aboutKeepAwake: String { localized("About KeepAwake", zh: "关于 KeepAwake") }
    static var quit: String { localized("Quit", zh: "退出") }
    
    // MARK: - Durations (display names)
    static var indefinitely: String { localized("Keep computer awake", zh: "保持电脑唤醒") }
    static var fifteenMinutes: String { localized("15 Minutes", zh: "15 分钟") }
    static var oneHour: String { localized("1 Hour", zh: "1 小时") }
    static var threeHours: String { localized("3 Hours", zh: "3 小时") }
    static var untilEightAM: String { localized("Until 8:00 AM", zh: "直到早上 8:00") }
    
    // MARK: - Notifications
    static var blackoutActivatedTitle: String { localized("Blackout Mode Activated", zh: "息屏模式已激活") }
    static var blackoutActivatedBody: String { localized("All screens dimmed while keeping the display connection. Shake mouse rapidly or press any key 3x to restore.", zh: "所有屏幕已调暗，但保持显示连接。快速摇动鼠标或连按 3 次任意键可恢复。") }
    static var blackoutAutoRestoredTitle: String { localized("Blackout Mode Auto-Restored", zh: "息屏模式已自动恢复") }
    static var blackoutAutoRestoredBody: String { localized("Screens restored due to detected user input.", zh: "检测到用户输入，屏幕已恢复。") }
    static var blackoutDeactivatedTitle: String { localized("Blackout Mode Deactivated", zh: "息屏模式已关闭") }
    static var blackoutDeactivatedBody: String { localized("Screen brightness restored.", zh: "屏幕亮度已恢复。") }
    static var activatedTitle: String { localized("Keep Awake Activated", zh: "保持唤醒已激活") }
    static func activatedBody(duration: String) -> String { localized("Mac will stay awake: \(duration)", zh: "Mac 将保持唤醒：\(duration)") }
    static var deactivatedTitle: String { localized("Keep Awake Deactivated", zh: "保持唤醒已关闭") }
    static var deactivatedBody: String { localized("Normal sleep settings restored.", zh: "已恢复正常睡眠设置。") }
    
    // MARK: - Timer
    static func remaining(_ timeStr: String) -> String { localized("Keep awake (\(timeStr) remaining)", zh: "保持电脑唤醒（剩余 \(timeStr)）") }
    
    // MARK: - About
    static var aboutTitle: String { localized("About KeepAwake", zh: "关于 KeepAwake") }
    static var aboutBody: String {
        localized(
            """
            KeepAwake is a 100% native macOS menubar app that prevents your Mac from sleeping or locking.
            
            Includes Blackout Mode to safely dim displays to 0% for automated agents and Energy Saving.
            
            Features:
            • DDC/CI brightness control for external monitors
            • Gamma fallback for unsupported displays
            • Safety auto-restore via mouse/keyboard
            
            Built with Swift & AppKit.
            Version \(appVersion)
            """,
            zh: """
            KeepAwake 是一款 100% 原生 macOS 菜单栏应用，可防止 Mac 进入睡眠或锁定。
            
            包含息屏模式，可安全地将显示器亮度降至 0%，适用于自动化代理和省电场景。
            
            功能特色：
            • DDC/CI 外接显示器亮度控制
            • 不支持的显示器使用 Gamma 降级方案
            • 通过鼠标/键盘安全自动恢复
            
            使用 Swift 和 AppKit 构建。
            版本 \(appVersion)
            """
        )
    }
    static var ok: String { localized("OK", zh: "好") }
}

enum DurationOption: String, CaseIterable {
    case indefinitely
    case fifteenMinutes
    case oneHour
    case threeHours
    case untilEightAM
    
    var localizedName: String {
        switch self {
        case .indefinitely: return L10n.indefinitely
        case .fifteenMinutes: return L10n.fifteenMinutes
        case .oneHour: return L10n.oneHour
        case .threeHours: return L10n.threeHours
        case .untilEightAM: return L10n.untilEightAM
        }
    }
    
    var seconds: Double? {
        switch self {
        case .indefinitely: return nil
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        case .threeHours: return 3 * 60 * 60
        case .untilEightAM:
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
        }
    }
}

// MARK: - ToggleMenuItemView (custom NSSwitch toggle for menu bar)

class ToggleMenuItemView: NSView {
    let toggleSwitch = NSSwitch()
    private let sleepLabel = NSTextField(labelWithString: "")
    private let coffeeLabel = NSTextField(labelWithString: "")
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
        sleepLabel.stringValue = L10n.sleepLabel
        coffeeLabel.stringValue = L10n.coffeeLabel

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
            statusLabel.topAnchor.constraint(equalTo: toggleSwitch.bottomAnchor, constant: 8),
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
    var selectedDuration: DurationOption = .indefinitely

    // UI references
    let toggleView = ToggleMenuItemView()

    // Blackout Mode state
    var isBlackoutModeActive: Bool = false
    let inputMonitor = InputMonitor()
    var blackoutRecoveryURL: URL?
    var blackoutWatchdogProcess: Process?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        requestNotificationPermission()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusBarIcon(isAwake: false)

        constructMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isBlackoutModeActive {
            disableBlackoutMode()
        } else {
            stopBlackoutWatchdog()
        }
        killCaffeinate()
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
        toggleView.onToggle = { [weak self] isOn in
            guard let self = self else { return }
            if isOn {
                self.activate()
                // Revert if activation failed
                if self.caffeinateProcess == nil {
                    self.toggleView.isOn = false
                    self.toggleView.statusText = L10n.allowedToSleep
                }
            } else {
                self.deactivate()
            }
        }
        toggleItem.view = toggleView
        toggleView.statusText = L10n.allowedToSleep
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // ── Set Duration submenu (disabled by default when Sleep is active) ──
        let durationMenuItem = NSMenuItem(title: "\(L10n.setDuration)  \(selectedDuration.localizedName)", action: nil, keyEquivalent: "")
        durationMenuItem.tag = 101
        durationMenuItem.isEnabled = false
        let durationSubmenu = NSMenu()
        durationSubmenu.autoenablesItems = false
        
        for duration in DurationOption.allCases {
            let item = NSMenuItem(title: duration.localizedName, action: #selector(changeDuration(_:)), keyEquivalent: "")
            item.representedObject = duration.rawValue
            item.isEnabled = false
            item.state = (duration == selectedDuration) ? .on : .off
            durationSubmenu.addItem(item)
        }
        durationMenuItem.submenu = durationSubmenu
        menu.addItem(durationMenuItem)

        // ── Blackout Mode toggle (disabled by default when Sleep is active) ──
        let blackoutItem = NSMenuItem(title: L10n.blackoutMode, action: #selector(toggleBlackoutMode(_:)), keyEquivalent: "")
        blackoutItem.tag = 102
        blackoutItem.isEnabled = false
        menu.addItem(blackoutItem)

        menu.addItem(NSMenuItem.separator())

        // ── About & Quit ──
        let aboutItem = NSMenuItem(title: L10n.aboutKeepAwake, action: #selector(openAppInfo(_:)), keyEquivalent: "")
        aboutItem.image = nil // Ensure no system icon is added
        aboutItem.isEnabled = true
        menu.addItem(aboutItem)
        let quitItem = NSMenuItem(title: L10n.quit, action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let isCoffeeActive = caffeinateProcess != nil
        if let durationItem = menu.item(withTag: 101) {
            durationItem.isEnabled = isCoffeeActive
            durationItem.submenu?.items.forEach { $0.isEnabled = isCoffeeActive }
            durationItem.title = "\(L10n.setDuration)  \(selectedDuration.localizedName)"
        }
        if let blackoutItem = menu.item(withTag: 102) {
            blackoutItem.isEnabled = isCoffeeActive
        }
        if !isCoffeeActive {
            toggleView.statusText = L10n.allowedToSleep
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.tag == 101 || menuItem.tag == 102 {
            return caffeinateProcess != nil
        }
        return true
    }

    @objc func changeDuration(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let duration = DurationOption(rawValue: rawValue) else { return }
        
        selectedDuration = duration

        // Update checkmarks in submenu
        if let submenu = sender.menu {
            for item in submenu.items {
                let itemDurationRaw = item.representedObject as? String
                item.state = (itemDurationRaw == duration.rawValue) ? .on : .off
            }
        }

        // Activate/reactivate with new duration
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

        if caffeinateProcess == nil {
            activate()
            guard caffeinateProcess != nil else { return }
        }

        let recoveryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwake-blackout-\(ProcessInfo.processInfo.processIdentifier).json")
        try? FileManager.default.removeItem(at: recoveryFile)
        blackoutRecoveryURL = recoveryFile

        guard startBlackoutWatchdog(recoveryFile: recoveryFile) else {
            stopBlackoutWatchdog()
            return
        }
        guard BrightnessManager.shared.dimAllDisplays(recoveryFile: recoveryFile) else {
            stopBlackoutWatchdog()
            return
        }

        blackoutRecoveryURL = recoveryFile
        isBlackoutModeActive = true

        inputMonitor.startMonitoring { [weak self] in
            self?.disableBlackoutMode(autoRestored: true)
        }

        if let blackoutItem = statusItem.menu?.item(withTag: 102) {
            blackoutItem.state = .on
        }

        showNotification(
            title: L10n.blackoutActivatedTitle,
            body: L10n.blackoutActivatedBody
        )
    }

    func disableBlackoutMode(autoRestored: Bool = false) {
        guard isBlackoutModeActive else { return }
        isBlackoutModeActive = false

        inputMonitor.stopMonitoring()
        BrightnessManager.shared.restoreAllDisplays()
        stopBlackoutWatchdog()

        if let blackoutItem = statusItem.menu?.item(withTag: 102) {
            blackoutItem.state = .off
        }

        if autoRestored {
            showNotification(
                title: L10n.blackoutAutoRestoredTitle,
                body: L10n.blackoutAutoRestoredBody
            )
        } else {
            showNotification(
                title: L10n.blackoutDeactivatedTitle,
                body: L10n.blackoutDeactivatedBody
            )
        }
    }

    private func startBlackoutWatchdog(recoveryFile: URL) -> Bool {
        if let existingProcess = blackoutWatchdogProcess {
            if existingProcess.isRunning { return true }
            blackoutWatchdogProcess = nil
        }

        let executableURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--blackout-watchdog",
            recoveryFile.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ]

        do {
            try process.run()
            blackoutWatchdogProcess = process
            return true
        } catch {
            print("Failed to start blackout watchdog: \(error)")
            return false
        }
    }

    private func stopBlackoutWatchdog() {
        if let process = blackoutWatchdogProcess {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            blackoutWatchdogProcess = nil
        }

        if let recoveryFile = blackoutRecoveryURL {
            try? FileManager.default.removeItem(at: recoveryFile)
            blackoutRecoveryURL = nil
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
            toggleView.isOn = false
            toggleView.statusText = ""
            return
        }

        // Timer setup
        if let seconds = selectedDuration.seconds {
            startTimer(seconds: seconds)
        } else {
            timer?.invalidate()
            timer = nil
            endTime = nil
            setStatusBarIcon(isAwake: true)
            toggleView.statusText = selectedDuration.localizedName
        }

        // Update toggle and menu state
        toggleView.isOn = true

        // Enable Set Duration and Blackout Mode options
        if let durationItem = statusItem.menu?.item(withTag: 101) {
            durationItem.isEnabled = true
            durationItem.submenu?.items.forEach { $0.isEnabled = true }
        }
        if let blackoutItem = statusItem.menu?.item(withTag: 102) {
            blackoutItem.isEnabled = true
        }

        showNotification(title: L10n.activatedTitle, body: L10n.activatedBody(duration: selectedDuration.localizedName))
    }

    func deactivate() {
        // Automatically exit Blackout Mode when deactivating
        disableBlackoutMode()

        killCaffeinate()
        timer?.invalidate()
        timer = nil
        endTime = nil

        // Update menu bar icon
        setStatusBarIcon(isAwake: false)

        // Update toggle and menu state
        toggleView.isOn = false
        toggleView.statusText = L10n.allowedToSleep

        // Disable Set Duration and Blackout Mode options
        if let durationItem = statusItem.menu?.item(withTag: 101) {
            durationItem.isEnabled = false
            durationItem.submenu?.items.forEach { $0.isEnabled = false }
        }
        if let blackoutItem = statusItem.menu?.item(withTag: 102) {
            blackoutItem.isEnabled = false
            blackoutItem.state = .off
        }

        showNotification(title: L10n.deactivatedTitle, body: L10n.deactivatedBody)
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

        if hours > 0 {
            let timeStr = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            setStatusBarIcon(isAwake: true, timeStr: timeStr)
            toggleView.statusText = L10n.remaining(timeStr)
        } else {
            let timeStr = String(format: "%02d:%02d", minutes, seconds)
            setStatusBarIcon(isAwake: true, timeStr: timeStr)
            toggleView.statusText = L10n.remaining(timeStr)
        }
    }

    func setStatusBarIcon(isAwake: Bool, timeStr: String? = nil) {
        guard let button = statusItem.button else { return }
        if isAwake {
            button.image = createCoffeeIcon()
        } else {
            button.image = createSleepIcon()
        }
        button.title = timeStr.map { " " + $0 } ?? ""
    }

    /// Draw a 💤-style icon: three z's from bottom-left (small) to upper-right (large)
    func createSleepIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            let fontSizes: [CGFloat] = [6, 8.5, 11]
            let positions: [NSPoint] = [
                NSPoint(x: 1, y: 11),   // small z, bottom-left
                NSPoint(x: 5, y: 5),    // medium z, middle
                NSPoint(x: 9, y: -1),   // large Z, upper-right
            ]
            for i in 0..<3 {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSizes[i], weight: .bold),
                    .foregroundColor: NSColor.black
                ]
                "z".draw(at: positions[i], withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Render the coffee SF Symbol into a fixed 18x18 canvas to avoid width jitter
    func createCoffeeIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            if let base = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                if let configuredImage = base.withSymbolConfiguration(config) ?? base.copy() as? NSImage {
                    // Center the image in the 18x18 canvas
                    let imgSize = configuredImage.size
                    let x = (size.width - imgSize.width) / 2.0
                    let y = (size.height - imgSize.height) / 2.0
                    configuredImage.draw(in: NSRect(x: x, y: y, width: imgSize.width, height: imgSize.height))
                }
            }
            return true
        }
        image.isTemplate = true
        return image
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

    @objc func openAppInfo(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = L10n.aboutTitle
        alert.informativeText = L10n.aboutBody
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.ok)
        alert.runModal()
    }

    @objc func quitApp(_ sender: NSMenuItem) {
        deactivate()
        NSApplication.shared.terminate(nil)
    }
}

if CommandLine.arguments.count >= 4,
   CommandLine.arguments[1] == "--blackout-watchdog",
   let parentPID = Int32(CommandLine.arguments[3]) {
    BlackoutWatchdog.run(
        recoveryFile: URL(fileURLWithPath: CommandLine.arguments[2]),
        parentPID: pid_t(parentPID)
    )
    exit(0)
}

// Programmatic entry point for custom single-file AppKit app
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
