import SwiftUI
import Cocoa
import Foundation
import UserNotifications
import IOKit
import Darwin
import ServiceManagement

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

struct DDCServiceDescriptor {
    let service: CFTypeRef
    let registryPath: String
}

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

    func getExternalAVServices() -> [DDCServiceDescriptor] {
        #if arch(arm64)
        var services: [DDCServiceDescriptor] = []
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
                    let registryPath = registryPath(for: service)
                    if !registryPath.isEmpty,
                       let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service) {
                        services.append(DDCServiceDescriptor(
                            service: avService.takeRetainedValue(),
                            registryPath: registryPath
                        ))
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

    #if arch(arm64)
    private func registryPath(for service: io_service_t) -> String {
        var path = [CChar](repeating: 0, count: 1024)
        let result = path.withUnsafeMutableBufferPointer { buffer in
            IORegistryEntryGetPath(service, kIOServicePlane, buffer.baseAddress!)
        }
        guard result == KERN_SUCCESS else { return "" }
        return String(cString: path)
    }
    #endif

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
    // Registry paths avoid restoring brightness to the wrong monitor when the
    // order of DCPAVServiceProxy entries changes between processes.
    let registryPath: String?
    let brightness: UInt16?

    private enum CodingKeys: String, CodingKey {
        case registryPath
        case brightness
    }

    init(registryPath: String, brightness: UInt16) {
        self.registryPath = registryPath
        self.brightness = brightness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A legacy recovery file may contain only `index`. Decode it without
        // using that unsafe positional mapping; the display entry is skipped.
        registryPath = try container.decodeIfPresent(String.self, forKey: .registryPath)
        brightness = try container.decodeIfPresent(UInt16.self, forKey: .brightness)
    }
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

    func dimDisplay(displayID: CGDirectDisplayID, snapshot: GammaSnapshot? = nil) -> Bool {
        if let snapshot = snapshot ?? capture(displayID: displayID) {
            remember(snapshot)
        }
        let result = CGSetDisplayTransferByFormula(displayID, 0, 0, 1, 0, 0, 1, 0, 0, 1)
        guard result == .success else {
            print("GammaManager: Failed to dim display \(displayID) (error \(result.rawValue))")
            return false
        }
        print("GammaManager: Dimmed display \(displayID)")
        return true
    }

    func restore(snapshot: GammaSnapshot) -> Bool {
        let sampleCount = Int(snapshot.count)
        guard sampleCount > 0,
              sampleCount <= 4096,
              snapshot.red.count == snapshot.green.count,
              snapshot.red.count == snapshot.blue.count,
              sampleCount <= snapshot.red.count,
              snapshot.red.count <= 4096,
              snapshot.red.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              snapshot.green.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              snapshot.blue.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            print("GammaManager: Refusing to restore an invalid recovery snapshot")
            return false
        }

        let displayID = CGDirectDisplayID(snapshot.displayID)
        var red = snapshot.red
        var green = snapshot.green
        var blue = snapshot.blue
        let result = CGSetDisplayTransferByTable(displayID, snapshot.count, &red, &green, &blue)
        guard result == .success else {
            print("GammaManager: Failed to restore display \(displayID) (error \(result.rawValue))")
            return false
        }
        print("GammaManager: Restored display \(displayID) from recovery state")
        return true
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
    let registryPath: String
    let savedBrightness: UInt16
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

    func getBrightness(displayID: CGDirectDisplayID) -> Float? {
        guard let getFunc = getBrightnessFunc else { return nil }
        var brightness: Float = 0.0
        guard getFunc(displayID, &brightness) == 0,
              brightness.isFinite,
              (0.0...1.0).contains(brightness) else {
            return nil
        }
        return brightness
    }

    @discardableResult
    func setBrightness(displayID: CGDirectDisplayID, level: Float) -> Bool {
        guard let setFunc = setBrightnessFunc,
              level.isFinite,
              (0.0...1.0).contains(level) else { return false }
        return setFunc(displayID, level) == 0
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
            if CGDisplayIsBuiltin(display) != 0,
               let saved = getBrightness(displayID: display) {
                dimmedDisplays[display] = .displayServices(savedBrightness: saved)
                builtInSnapshots.append(BuiltInDisplaySnapshot(
                    displayID: display,
                    brightness: saved
                ))
            } else if let snapshot = GammaManager.shared.capture(displayID: display) {
                GammaManager.shared.remember(snapshot)
                dimmedDisplays[display] = .gamma
                gammaSnapshots.append(snapshot)
            } else {
                print("BrightnessManager: No safe dimming method for display \(display)")
            }
        }

        var ddcSnapshots: [DDCDisplaySnapshot] = []
        let avServices = DDCManager.shared.getExternalAVServices()
        for descriptor in avServices {
            guard let reading = DDCManager.shared.readBrightness(service: descriptor.service) else {
                // Never dim an external display if its original brightness
                // cannot be read and therefore cannot be safely restored.
                print("DDCManager: Skipping display with unreadable brightness state")
                continue
            }

            print("DDCManager: Saved brightness \(reading.current)/\(reading.max)")
            dimmedDDCServices.append(DDCDisplayState(
                service: descriptor.service,
                registryPath: descriptor.registryPath,
                savedBrightness: reading.current
            ))
            ddcSnapshots.append(DDCDisplaySnapshot(
                registryPath: descriptor.registryPath,
                brightness: reading.current
            ))
        }

        guard !dimmedDisplays.isEmpty || !dimmedDDCServices.isEmpty else {
            print("BrightnessManager: No display could be safely dimmed")
            return false
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
                guard setBrightness(displayID: display, level: 0.0) else {
                    print("BrightnessManager: Failed to dim built-in display \(display)")
                    rollbackBlackout(recoveryFile: recoveryFile)
                    return false
                }
                print("BrightnessManager: Dimmed built-in display \(display)")
            case .gamma:
                if let snapshot = gammaSnapshots.first(where: { $0.displayID == display }) {
                    guard GammaManager.shared.dimDisplay(displayID: display, snapshot: snapshot) else {
                        rollbackBlackout(recoveryFile: recoveryFile)
                        return false
                    }
                }
            }
        }

        // Keep external displays connected for screenshots and Computer Use.
        // DDC brightness 0 is deliberately used instead of VCP power-off.
        for state in dimmedDDCServices {
            guard DDCManager.shared.setBrightness(service: state.service, value: 0) else {
                print("BrightnessManager: Failed to dim external display at \(state.registryPath)")
                rollbackBlackout(recoveryFile: recoveryFile)
                return false
            }
        }

        return true
    }

    private func rollbackBlackout(recoveryFile: URL) {
        restoreAllDisplays()
        try? FileManager.default.removeItem(at: recoveryFile)
    }

    func restoreAllDisplays() {
        for state in dimmedDDCServices {
            if !DDCManager.shared.setBrightness(
                service: state.service,
                value: state.savedBrightness
            ) {
                print("BrightnessManager: Failed to restore external display at \(state.registryPath)")
            }
        }
        dimmedDDCServices.removeAll()

        for (display, method) in dimmedDisplays {
            switch method {
            case .displayServices(let saved):
                guard setBrightness(displayID: display, level: saved) else {
                    print("BrightnessManager: Failed to restore built-in display \(display)")
                    continue
                }
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
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            print("BrightnessManager: Failed to write recovery state: \(error)")
            return false
        }
    }

    func restoreFromRecoveryFile(_ url: URL) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? NSNumber,
               fileSize.intValue > 1_048_576 {
                print("BrightnessManager: Recovery file is unexpectedly large; refusing to read it")
                return
            }

            let data = try Data(contentsOf: url)
            let state = try JSONDecoder().decode(BlackoutRecoveryState.self, from: data)

            var avServicesByPath: [String: CFTypeRef] = [:]
            for descriptor in DDCManager.shared.getExternalAVServices() {
                avServicesByPath[descriptor.registryPath] = descriptor.service
            }

            for snapshot in state.ddcDisplays {
                guard let registryPath = snapshot.registryPath,
                      !registryPath.isEmpty,
                      let savedBrightness = snapshot.brightness,
                      let service = avServicesByPath[registryPath] else {
                    // This also safely skips legacy index-based entries. An
                    // index is not a stable identity across process launches.
                    continue
                }
                guard DDCManager.shared.setBrightness(service: service, value: savedBrightness) else {
                    print("BrightnessManager: Failed to restore external display at \(registryPath)")
                    continue
                }
            }

            for snapshot in state.builtInDisplays {
                guard setBrightness(
                    displayID: CGDirectDisplayID(snapshot.displayID),
                    level: snapshot.brightness
                ) else {
                    print("BrightnessManager: Failed to restore built-in display \(snapshot.displayID)")
                    continue
                }
            }

            for snapshot in state.gammaDisplays {
                _ = GammaManager.shared.restore(snapshot: snapshot)
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
    private var keyEventTap: CFMachPort?
    private var keyEventRunLoopSource: CFRunLoopSource?
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

        startKeyboardMonitoring()

        print("InputMonitor: Started")
    }

    func stopMonitoring() {
        mouseCheckTimer?.invalidate()
        mouseCheckTimer = nil
        if let source = keyEventRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            keyEventRunLoopSource = nil
        }
        if let tap = keyEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            keyEventTap = nil
        }
        cumulativeDistance = 0.0
        keyPressTimestamps = []
        onTrigger = nil
    }

    private func startKeyboardMonitoring() {
        guard CGPreflightListenEventAccess() else {
            print("InputMonitor: Keyboard monitoring unavailable without Input Monitoring permission")
            return
        }

        let keyDownMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: keyDownMask,
            callback: Self.keyboardEventCallback,
            userInfo: context
        ) else {
            print("InputMonitor: Failed to create keyboard event tap")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            print("InputMonitor: Failed to create keyboard event run-loop source")
            return
        }

        keyEventTap = tap
        keyEventRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static let keyboardEventCallback: CGEventTapCallBack = {
        _, eventType, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        switch eventType {
        case .keyDown:
            monitor.handleKeyPress()
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = monitor.keyEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
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

// MARK: - System power state

struct SystemPowerState {
    let systemNeverSleeps: Bool
    let displaySleepMinutes: Int?
    let hasExternalCaffeinate: Bool
}

/// Reads the effective power policy without changing any macOS settings.
/// KeepAwake's switch is intentionally independent from assertions owned by
/// other processes, so an external caffeinate never appears as our own switch.
final class SystemPowerStateReader {
    static let shared = SystemPowerStateReader()

    private init() {}

    func read(forProcessID processID: pid_t) -> SystemPowerState {
        let customSettings = commandOutput(arguments: ["-g", "custom"])
        let profiles = parsePowerProfiles(customSettings)
        let activeProfileName = activePowerProfileName(
            from: commandOutput(arguments: ["-g", "batt"])
        )
        let activeProfile = activeProfileName.flatMap { profiles[$0] }
            ?? (profiles.count == 1 ? profiles.values.first : nil)

        let assertions = commandOutput(arguments: ["-g", "assertions"])
        return SystemPowerState(
            systemNeverSleeps: activeProfile?["sleep"] == 0,
            displaySleepMinutes: activeProfile?["displaysleep"],
            hasExternalCaffeinate: hasExternalCaffeinate(
                in: assertions,
                currentProcessID: processID
            )
        )
    }

    private func commandOutput(arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("SystemPowerStateReader: failed to run pmset: \(error)")
            return ""
        }

        guard process.terminationStatus == 0 else { return "" }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parsePowerProfiles(_ output: String) -> [String: [String: Int]] {
        var profiles: [String: [String: Int]] = [:]
        var currentProfile: String?

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "AC Power:" || trimmed == "Battery Power:" {
                let name = String(trimmed.dropLast())
                profiles[name] = [:]
                currentProfile = name
                continue
            }

            guard let currentProfile else { continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2,
                  let value = Int(parts[1]),
                  parts[0] == "sleep" || parts[0] == "displaysleep" else {
                continue
            }
            profiles[currentProfile]?[String(parts[0])] = value
        }

        return profiles
    }

    private func activePowerProfileName(from output: String) -> String? {
        if output.contains("Now drawing from 'AC Power'") {
            return "AC Power"
        }
        if output.contains("Now drawing from 'Battery Power'") {
            return "Battery Power"
        }
        return nil
    }

    private func hasExternalCaffeinate(in assertions: String, currentProcessID: pid_t) -> Bool {
        let marker = "Process ID "

        for line in assertions.components(separatedBy: .newlines)
            where line.contains("Details: caffeinate asserting on behalf of \(marker)") {
            guard let markerRange = line.range(of: marker) else { continue }
            let suffix = line[markerRange.upperBound...]
            let pidText = suffix.prefix(while: { $0.isNumber })
            guard let ownerPID = Int(pidText) else { continue }
            if ownerPID != Int(currentProcessID) {
                return true
            }
        }

        return false
    }
}

// MARK: - Localization (i18n)

enum AppLanguageSetting: String, CaseIterable {
    case system = "system"
    case en = "en"
    case zh = "zh"

    var localizedName: String {
        switch self {
        case .system: return L10n.languageSystem
        case .en: return "English"
        case .zh: return "简体中文"
        }
    }
}

enum Language: String {
    case en, zh
}

struct L10n {
    static let languageSettingKey = "appLanguageSetting"

    static var currentSetting: AppLanguageSetting {
        get {
            if let saved = UserDefaults.standard.string(forKey: languageSettingKey),
               let setting = AppLanguageSetting(rawValue: saved) {
                return setting
            }
            return .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: languageSettingKey)
        }
    }

    static var current: Language {
        switch currentSetting {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            if preferred.hasPrefix("zh") {
                return .zh
            }
            return .en
        case .en:
            return .en
        case .zh:
            return .zh
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3"
    }
    
    // Use this helper for all localized strings
    static func localized(_ en: String, zh: String) -> String {
        switch current {
        case .zh: return zh
        case .en: return en
        }
    }
    
    // MARK: - Toggle View
    static var sleepTitle: String { localized("Sleep", zh: "倒头就") }
    static var sleepIcon: String { "💤" }
    static var coffeeTitle: String { localized("Coffee", zh: "倒杯") }
    static var coffeeIcon: String { "☕️" }
    static var allowedToSleep: String { localized("Normal system sleep", zh: "按系统设置休眠") }
    static var systemNeverSleeps: String {
        localized("System sleep is already set to Never", zh: "系统已设置为永不休眠，无需开启")
    }
    static func systemNeverSleepsWithDisplaySleep(_ minutes: Int) -> String {
        localized(
            "System sleep is Never; display sleeps after \(minutes) min",
            zh: "系统不会休眠；显示器 \(minutes) 分钟后关闭"
        )
    }
    static var otherCaffeinateActive: String {
        localized("Another program is keeping your Mac awake", zh: "其他程序正在保持电脑唤醒")
    }
    
    // MARK: - Menu Items
    static var setDuration: String { localized("Set Duration", zh: "设置时长") }
    static var blackoutMode: String { localized("Blackout Mode (Energy Saving)", zh: "假装下钟 (偷偷努力)") }
    static var keyboardRestorePermissionRequired: String {
        localized("Keyboard restore: Permission required…", zh: "键盘恢复：需要授权…")
    }
    static var keyboardRestoreRestartRequired: String {
        localized("Keyboard restore: Restart to apply…", zh: "键盘恢复：点击重启以应用授权…")
    }
    static var launchAtLogin: String { localized("Launch at Login", zh: "开机启动") }
    static var notifications: String { localized("Notifications", zh: "通知") }
    static var language: String { localized("Language", zh: "语言") }
    static var languageSystem: String { localized("Follow System", zh: "跟随系统") }
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
    static var blackoutFailedTitle: String { localized("Blackout Mode Unavailable", zh: "息屏模式不可用") }
    static var blackoutFailedBody: String { localized("No display could be dimmed safely; screen state was left unchanged.", zh: "没有显示器可以安全调暗；屏幕状态未改变。") }
    static var blackoutAutoRestoredTitle: String { localized("Blackout Mode Auto-Restored", zh: "息屏模式已自动恢复") }
    static var blackoutAutoRestoredBody: String { localized("Screens restored due to detected user input.", zh: "检测到用户输入，屏幕已恢复。") }
    static var blackoutDeactivatedTitle: String { localized("Blackout Mode Deactivated", zh: "息屏模式已关闭") }
    static var blackoutDeactivatedBody: String { localized("Screen brightness restored.", zh: "屏幕亮度已恢复。") }
    static var keyboardRestorePermissionTitle: String {
        localized("Allow Keyboard Restore?", zh: "允许按键恢复屏幕？")
    }
    static var keyboardRestorePermissionBody: String {
        localized(
            "When Blackout Mode is active, KeepAwake can restore your displays after three key presses. It only counts key presses and never reads, stores, or uploads which keys you press.",
            zh: "息屏模式开启后，连续按键 3 次可以恢复屏幕。KeepAwake 只统计按键次数，不会读取、保存或上传具体按键内容。"
        )
    }
    static var openSystemSettings: String { localized("Open System Settings", zh: "打开系统设置") }
    static var useMouseOnly: String { localized("Use Mouse Only", zh: "仅使用鼠标恢复") }
    static var cancel: String { localized("Cancel", zh: "取消") }
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
            KeepAwake is a 100% native macOS menubar app that prevents idle system and display sleep while it is active. It does not bypass manual lock or authentication.
            
            Includes Blackout Mode to safely dim displays to 0% for automated agents and Energy Saving.
            
            Features:
            • DDC/CI brightness control for external monitors
            • Gamma fallback for unsupported displays
            • Safety auto-restore via mouse/keyboard
            
            Built with Swift & AppKit.
            Version \(appVersion)
            """,
            zh: """
            KeepAwake 是一款 100% 原生 macOS 菜单栏应用，可在开启期间阻止系统和显示器空闲休眠，但不会绕过手动锁屏或身份验证。
            
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
    case fifteenMinutes
    case oneHour
    case threeHours
    case untilEightAM
    case indefinitely
    
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

// MARK: - ToggleMenuItemView (SwiftUI)

struct CustomToggle: View {
    @Binding var isOn: Bool
    
    var body: some View {
        ZStack {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.gray.opacity(0.3))
                .frame(width: 38, height: 22)
            
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 1)
                .frame(width: 18, height: 18)
                .offset(x: isOn ? 8 : -8)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isOn)
        }
        .onTapGesture {
            isOn.toggle()
        }
    }
}

class ToggleMenuState: ObservableObject {
    @Published var isOn: Bool = false
    @Published var statusText: String = ""
    @Published var updateCounter: Int = 0
    var onToggle: ((Bool) -> Void)?
}

struct ToggleMenuView: View {
    @ObservedObject var state: ToggleMenuState
    
    var body: some View {
        _ = state.updateCounter
        return VStack(spacing: 4) {
            ZStack {
                HStack {
                    HStack(spacing: 3) {
                        if L10n.current == .en {
                            Text(L10n.sleepIcon)
                                .font(.system(size: 13))
                            Text(L10n.sleepTitle)
                                .font(.system(size: 13, weight: .medium))
                        } else {
                            Text(L10n.sleepTitle)
                                .font(.system(size: 13, weight: .medium))
                            Text(L10n.sleepIcon)
                                .font(.system(size: 13))
                        }
                    }
                    .foregroundColor(state.isOn ? .secondary : .primary)
                    .padding(.leading, 16)
                    
                    Spacer()
                    
                    HStack(spacing: 3) {
                        if L10n.current == .en {
                            Text(L10n.coffeeIcon)
                                .font(.system(size: 15))
                            Text(L10n.coffeeTitle)
                                .font(.system(size: 13, weight: .medium))
                        } else {
                            Text(L10n.coffeeTitle)
                                .font(.system(size: 13, weight: .medium))
                            Text(L10n.coffeeIcon)
                                .font(.system(size: 15))
                        }
                    }
                    .foregroundColor(state.isOn ? .primary : .secondary)
                    .padding(.trailing, 16)
                }
                
                CustomToggle(isOn: Binding(
                    get: { state.isOn },
                    set: { newValue in
                        state.isOn = newValue
                        state.onToggle?(newValue)
                    }
                ))
            }
            
            if !state.statusText.isEmpty {
                Text(state.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 280, height: 56)
        .environment(\.controlActiveState, .active)
    }
}

class ToggleMenuItemView: NSHostingView<ToggleMenuView> {
    let state = ToggleMenuState()
    
    var onToggle: ((Bool) -> Void)? {
        get { state.onToggle }
        set { state.onToggle = newValue }
    }
    
    var isOn: Bool {
        get { state.isOn }
        set { state.isOn = newValue }
    }
    
    var statusText: String {
        get { state.statusText }
        set { state.statusText = newValue }
    }
    
    init() {
        super.init(rootView: ToggleMenuView(state: ToggleMenuState())) // Dummy init
        self.rootView = ToggleMenuView(state: self.state)
        self.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @MainActor required dynamic init(rootView: ToggleMenuView) {
        fatalError("init(rootView:) has not been implemented")
    }
}

// MARK: - DurationSliderMenuItemView (SwiftUI)

struct CustomDiscreteSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var isEnabled: Bool
    var onEditingChanged: (Bool) -> Void
    
    let trackHeight: CGFloat = 20
    let thumbSize: CGFloat = 26
    
    @State private var isDraggingThumb = false
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let usableWidth = width - thumbSize
            let stepCount = CGFloat(range.upperBound - range.lowerBound)
            let stepWidth = stepCount > 0 ? usableWidth / stepCount : 0
            
            let currentX = CGFloat(value - range.lowerBound) * stepWidth
            
            ZStack(alignment: .leading) {
                // Inactive Track
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: trackHeight)
                
                // Active Track
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(isEnabled ? Color.accentColor : Color.gray.opacity(0.4))
                    .frame(width: currentX + thumbSize, height: trackHeight)
                    .animation(.spring(response: 0.2, dampingFraction: 0.9), value: currentX)
                
                // Ticks
                ForEach(range, id: \.self) { i in
                    let tickX = CGFloat(i - range.lowerBound) * stepWidth
                    let isActive = i <= value
                    Circle()
                        .fill(isActive ? Color.white.opacity(0.5) : Color.gray.opacity(0.4))
                        .frame(width: 5, height: 5)
                        .offset(x: tickX + thumbSize / 2 - 2.5)
                }
                
                // Thumb
                Circle()
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .scaleEffect(isDraggingThumb ? 1.15 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.9), value: isDraggingThumb)
                    .offset(x: currentX)
                    .animation(.spring(response: 0.2, dampingFraction: 0.9), value: currentX)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !isDraggingThumb {
                            isDraggingThumb = true
                        }
                        onEditingChanged(true)
                        let dragX = gesture.location.x - thumbSize / 2
                        let rawValue = round(dragX / stepWidth) + CGFloat(range.lowerBound)
                        let clampedValue = min(max(Int(rawValue), range.lowerBound), range.upperBound)
                        if clampedValue != value {
                            value = clampedValue
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        }
                    }
                    .onEnded { _ in
                        guard isEnabled else { return }
                        if isDraggingThumb {
                            isDraggingThumb = false
                        }
                        onEditingChanged(false)
                    }
            )
            .frame(height: max(trackHeight, thumbSize))
            .onDisappear {
                if isDraggingThumb {
                    isDraggingThumb = false
                }
            }
        }
        .frame(height: max(trackHeight, thumbSize))
    }
}

class DurationSliderState: ObservableObject {
    @Published var selectedDuration: DurationOption = .indefinitely
    @Published var isEnabled: Bool = true
    @Published var updateCounter: Int = 0
    var onDurationChanged: ((DurationOption) -> Void)?
}

struct DurationSliderMenuView: View {
    @ObservedObject var state: DurationSliderState
    @State private var isEditing: Bool = false
    
    var body: some View {
        _ = state.updateCounter
        return VStack(spacing: 4) {
            HStack {
                Text(L10n.setDuration)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(state.isEnabled ? .primary : .secondary)
                    .padding(.leading, 16)
                Spacer()
                Text(state.selectedDuration.localizedName)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(state.isEnabled ? .secondary : Color(nsColor: .tertiaryLabelColor))
                    .padding(.trailing, 21)
            }
            
            CustomDiscreteSlider(
                value: Binding(get: {
                    DurationOption.allCases.firstIndex(of: state.selectedDuration) ?? 0
                }, set: { index in
                    if index >= 0 && index < DurationOption.allCases.count {
                        state.selectedDuration = DurationOption.allCases[index]
                    }
                }),
                range: 0...(DurationOption.allCases.count - 1),
                isEnabled: state.isEnabled,
                onEditingChanged: { editing in
                    isEditing = editing
                    if !editing {
                        state.onDurationChanged?(state.selectedDuration)
                    }
                }
            )
            .padding(.leading, 16)
            .padding(.trailing, 17)
        }
        .frame(width: 280, height: 52)
        .environment(\.controlActiveState, .active) // Forces active accent color
        .onDisappear {
            // If the menu is abruptly closed (e.g. mouse released outside the menu window)
            // we need to commit the value we were dragging to.
            if isEditing {
                isEditing = false
                state.onDurationChanged?(state.selectedDuration)
            }
        }
    }
}

class DurationSliderMenuItemView: NSHostingView<DurationSliderMenuView> {
    let state = DurationSliderState()
    
    var onDurationChanged: ((DurationOption) -> Void)? {
        get { state.onDurationChanged }
        set { state.onDurationChanged = newValue }
    }
    
    var isEnabled: Bool {
        get { state.isEnabled }
        set { state.isEnabled = newValue }
    }
    
    var selectedDuration: DurationOption {
        get { state.selectedDuration }
        set { state.selectedDuration = newValue }
    }
    
    init() {
        super.init(rootView: DurationSliderMenuView(state: DurationSliderState())) // Dummy init
        self.rootView = DurationSliderMenuView(state: self.state)
        self.frame = NSRect(x: 0, y: 0, width: 280, height: 52)
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @MainActor required dynamic init(rootView: DurationSliderMenuView) {
        fatalError("init(rootView:) has not been implemented")
    }
}

// MARK: - Blackout Mode Hover Tooltip

struct BlackoutTooltipContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("黑屏省电，后台任务与 Agent 不中断。")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("晃动鼠标或连按 3 次按键即可点亮。")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .frame(width: 210)
    }
}

final class BlackoutTooltipManager {
    static let shared = BlackoutTooltipManager()
    private var window: NSPanel?
    private var timer: Timer?
    private var monitorTimer: Timer?
    private weak var targetView: NSView?

    func schedule(relativeTo view: NSView) {
        cancel()
        guard L10n.current == .zh else { return }
        self.targetView = view

        let t = Timer(timeInterval: 0.25, repeats: false) { [weak self, weak view] _ in
            guard let self = self, let view = view, let win = view.window else { return }

            let rectInWindow = view.convert(view.bounds, to: nil)
            let screenRect = win.convertToScreen(rectInWindow)
            let mouseLoc = NSEvent.mouseLocation

            // Only show if mouse is currently inside view bounds and highlighted
            guard screenRect.contains(mouseLoc),
                  view.enclosingMenuItem?.isHighlighted == true else {
                return
            }

            self.show(relativeTo: view, screenRect: screenRect, mouseLoc: mouseLoc)
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        monitorTimer?.invalidate()
        monitorTimer = nil
        if let win = window {
            win.orderOut(nil)
            window = nil
        }
        targetView = nil
    }

    private func show(relativeTo view: NSView, screenRect: NSRect, mouseLoc: NSPoint) {
        let text1 = "黑屏省电，后台任务与 Agent 不中断。"
        let text2 = "晃动鼠标或连按 3 次按键即可点亮。"
        let font1 = NSFont.systemFont(ofSize: 11, weight: .regular)
        let font2 = NSFont.systemFont(ofSize: 10, weight: .regular)

        let size1 = (text1 as NSString).size(withAttributes: [.font: font1])
        let size2 = (text2 as NSString).size(withAttributes: [.font: font2])

        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 5
        let spacing: CGFloat = 2

        let panelWidth: CGFloat = ceil(max(size1.width, size2.width)) + (horizontalPadding * 2) + 1
        let panelHeight: CGFloat = ceil(size1.height + size2.height) + spacing + (verticalPadding * 2)

        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        // Native macOS Tooltip position: offset under the cursor pointer
        var panelX = mouseLoc.x + 2
        var panelY = mouseLoc.y - panelHeight - 14

        // Keep horizontally on screen
        if panelX + panelWidth > visibleFrame.maxX - 8 {
            panelX = visibleFrame.maxX - panelWidth - 8
        }
        if panelX < visibleFrame.minX + 8 {
            panelX = visibleFrame.minX + 8
        }

        // If below screen bottom, flip to above cursor
        if panelY < visibleFrame.minY + 8 {
            panelY = mouseLoc.y + 18
        }

        let panel = NSPanel(
            contentRect: NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu + 1
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true

        let radius: CGFloat = 5
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        visualEffect.material = .toolTip
        visualEffect.blendingMode = .withinWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = radius
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor

        // Labels matching native tooltip typography
        let label1 = NSTextField(labelWithString: text1)
        label1.font = font1
        label1.textColor = .labelColor
        label1.maximumNumberOfLines = 1
        label1.lineBreakMode = .byClipping

        let label2 = NSTextField(labelWithString: text2)
        label2.font = font2
        label2.textColor = .secondaryLabelColor
        label2.maximumNumberOfLines = 1
        label2.lineBreakMode = .byClipping

        let stack = NSStackView(views: [label1, label2])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: verticalPadding, left: horizontalPadding, bottom: verticalPadding, right: horizontalPadding)
        stack.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
        ])

        panel.contentView = visualEffect
        panel.invalidateShadow()
        panel.orderFront(nil)
        self.window = panel

        // Continuous heartbeat monitor to dismiss as soon as mouse leaves or row is no longer highlighted
        let m = Timer(timeInterval: 0.04, repeats: true) { [weak self, weak view] _ in
            guard let self = self, let view = view, let win = view.window else {
                self?.cancel()
                return
            }
            let rectInWin = view.convert(view.bounds, to: nil)
            let sRect = win.convertToScreen(rectInWin)
            let currentMouse = NSEvent.mouseLocation

            if !sRect.contains(currentMouse) || view.enclosingMenuItem?.isHighlighted != true {
                self.cancel()
            }
        }
        RunLoop.main.add(m, forMode: .common)
        self.monitorTimer = m
    }
}

// MARK: - TrailingCheckMenuItemView (AppKit)

final class TrailingCheckMenuItemView: NSView {
    var rowTitle: String {
        didSet { needsDisplay = true }
    }
    let showsIndicator: Bool
    var onActivate: (() -> Void)?
    var hasHoverPopover = false
    private var wasHighlighted = false

    var isOn = false {
        didSet { needsDisplay = true }
    }

    var isItemEnabled = true {
        didSet { needsDisplay = true }
    }

    init(title: String, showsIndicator: Bool, width: CGFloat = 280, hasHoverPopover: Bool = false) {
        self.rowTitle = title
        self.showsIndicator = showsIndicator
        self.hasHoverPopover = hasHoverPopover
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseUp(with event: NSEvent) {
        wasHighlighted = false
        if hasHoverPopover {
            BlackoutTooltipManager.shared.cancel()
        }
        guard isItemEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        enclosingMenuItem?.menu?.cancelTracking()
        onActivate?()
    }

    func resetInteractionState() {
        wasHighlighted = false
        if hasHoverPopover {
            BlackoutTooltipManager.shared.cancel()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let isHighlighted = enclosingMenuItem?.isHighlighted == true
        if hasHoverPopover && isItemEnabled {
            if isHighlighted && !wasHighlighted {
                BlackoutTooltipManager.shared.schedule(relativeTo: self)
            } else if !isHighlighted && wasHighlighted {
                BlackoutTooltipManager.shared.cancel()
            }
            wasHighlighted = isHighlighted
        }

        if isHighlighted && isItemEnabled {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 5, dy: 0),
                xRadius: 5,
                yRadius: 5
            ).fill()
        }

        let textColor: NSColor
        if !isItemEnabled {
            textColor = .tertiaryLabelColor
        } else if isHighlighted {
            textColor = .alternateSelectedControlTextColor
        } else {
            textColor = .labelColor
        }

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: textColor
        ]
        let titleSize = rowTitle.size(withAttributes: titleAttributes)
        rowTitle.draw(
            at: NSPoint(x: 16, y: (bounds.height - titleSize.height) / 2),
            withAttributes: titleAttributes
        )

        if showsIndicator && isOn {
            let checkmark = "✓"
            let checkmarkAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: textColor
            ]
            let checkmarkSize = checkmark.size(withAttributes: checkmarkAttributes)
            checkmark.draw(
                at: NSPoint(
                    x: bounds.width - 16 - checkmarkSize.width,
                    y: (bounds.height - checkmarkSize.height) / 2
                ),
                withAttributes: checkmarkAttributes
            )
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var caffeinateProcess: Process?
    var timer: Timer?
    var endTime: Date?
    var selectedDuration: DurationOption = .indefinitely

    private let notificationCenter = UNUserNotificationCenter.current()
    private let notificationsEnabledKey = "notificationsEnabled"
    private let launchAtLoginConfiguredKey = "launchAtLoginConfigured"
    private let blackoutPermissionExplainedKey = "blackoutPermissionExplained"
    private let blackoutMouseOnlyAcceptedKey = "blackoutMouseOnlyAccepted"
    private let keyboardPermissionRestartPendingKey = "keyboardPermissionRestartPending"
    private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    private var notificationAuthorizationResolved = false
    private var pendingNotifications: [(title: String, body: String)] = []
    private var notificationsEnabled: Bool = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "notificationsEnabled") != nil else {
            return true
        }
        return defaults.bool(forKey: "notificationsEnabled")
    }()

    // UI references
    let toggleView = ToggleMenuItemView()
    let durationSliderView = DurationSliderMenuItemView()
    let blackoutMenuView = TrailingCheckMenuItemView(
        title: L10n.blackoutMode,
        showsIndicator: true,
        hasHoverPopover: true
    )
    let keyboardRestorePermissionMenuView = TrailingCheckMenuItemView(
        title: L10n.keyboardRestorePermissionRequired,
        showsIndicator: false
    )
    let launchAtLoginMenuView = TrailingCheckMenuItemView(
        title: L10n.launchAtLogin,
        showsIndicator: true
    )
    let notificationMenuView = TrailingCheckMenuItemView(
        title: L10n.notifications,
        showsIndicator: true
    )
    let aboutMenuView = TrailingCheckMenuItemView(
        title: L10n.aboutKeepAwake,
        showsIndicator: false
    )
    let quitMenuView = TrailingCheckMenuItemView(
        title: L10n.quit,
        showsIndicator: false
    )
    private var languageMenuItem: NSMenuItem?
    private var languageSubmenu: NSMenu?
    private var languageSubmenuViews: [AppLanguageSetting: TrailingCheckMenuItemView] = [:]

    // Blackout Mode state
    var isBlackoutModeActive: Bool = false
    let inputMonitor = InputMonitor()
    var blackoutRecoveryURL: URL?
    var blackoutWatchdogProcess: Process?

    private var isKeepAwakeActive: Bool {
        caffeinateProcess?.isRunning == true
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        guard ensureSingleInstance() else { return }

        // Input Monitoring changes apply to a newly launched process. A fresh
        // launch has consumed any pending "restart to apply" state, whether
        // the user granted the permission or chose not to.
        UserDefaults.standard.removeObject(forKey: keyboardPermissionRestartPendingKey)

        configureDefaultLaunchAtLogin()

        notificationCenter.delegate = self
        if notificationsEnabled {
            requestNotificationPermission()
        } else {
            refreshNotificationAuthorizationStatus()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusBarIcon(isAwake: false)

        constructMenu()
        refreshWakeStatus()
    }

    private func configureDefaultLaunchAtLogin() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: launchAtLoginConfiguredKey) == nil else {
            return
        }

        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
            defaults.set(true, forKey: launchAtLoginConfiguredKey)
        } catch {
            // Leave the marker unset so a later launch can retry a transient
            // registration failure. macOS may still require user approval.
            print("Failed to enable Launch at Login by default: \(error)")
        }
    }

    private func ensureSingleInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return true }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let existing = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first(where: { $0.processIdentifier != currentPID }) else {
            return true
        }

        existing.activate(options: [.activateIgnoringOtherApps])
        print("KeepAwake: another instance is already running")
        NSApplication.shared.terminate(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isBlackoutModeActive {
            disableBlackoutMode(notify: false)
        } else {
            stopBlackoutWatchdog()
        }
        killCaffeinate()
    }

    private var systemAllowsNotifications: Bool {
        notificationAuthorizationStatus == .authorized
            || notificationAuthorizationStatus == .provisional
    }

    private var canDeliverNotifications: Bool {
        notificationsEnabled && systemAllowsNotifications
    }

    func requestNotificationPermission() {
        notificationCenter.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }

            guard settings.authorizationStatus == .notDetermined else {
                self.updateNotificationAuthorization(settings.authorizationStatus)
                return
            }

            self.notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
                if let error = error {
                    print("Notification authorization error: \(error)")
                }

                // Read the final status instead of trusting the Boolean alone.
                // This also makes the menu reflect changes made in System Settings.
                self?.notificationCenter.getNotificationSettings { [weak self] settings in
                    self?.updateNotificationAuthorization(settings.authorizationStatus)
                }
            }
        }
    }

    private func refreshNotificationAuthorizationStatus() {
        notificationCenter.getNotificationSettings { [weak self] settings in
            self?.updateNotificationAuthorization(settings.authorizationStatus)
        }
    }

    private func updateNotificationAuthorization(_ status: UNAuthorizationStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.notificationAuthorizationStatus = status
            self.notificationAuthorizationResolved = true

            if status == .denied && self.notificationsEnabled {
                self.notificationsEnabled = false
                UserDefaults.standard.set(false, forKey: self.notificationsEnabledKey)
            }
            self.updateNotificationMenuItem()

            guard self.canDeliverNotifications else {
                if status == .denied {
                    print("Notifications are disabled for KeepAwake in System Settings")
                }
                self.pendingNotifications.removeAll()
                return
            }

            let pending = self.pendingNotifications
            self.pendingNotifications.removeAll()
            for notification in pending {
                self.addNotification(title: notification.title, body: notification.body)
            }
        }
    }

    private func updateNotificationMenuItem() {
        notificationMenuView.isOn = canDeliverNotifications
    }

    func constructMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Stateful rows draw a fixed trailing checkmark instead of using
        // AppKit's leading state column.
        menu.showsStateColumn = false
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
                    self.refreshWakeStatus()
                }
            } else {
                self.deactivate()
            }
        }
        toggleItem.view = toggleView
        toggleView.statusText = L10n.allowedToSleep
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // ── Set Duration Slider (disabled by default when Sleep is active) ──
        let durationMenuItem = NSMenuItem()
        durationMenuItem.tag = 101
        durationMenuItem.isEnabled = false
        
        durationSliderView.selectedDuration = selectedDuration
        durationSliderView.onDurationChanged = { [weak self] newDuration in
            guard let self = self else { return }
            self.selectedDuration = newDuration
            // The user wanted this in the main panel. If they drag the slider, we want to update.
            // Only reactivate if we're currently awake, OR the user explicitly expects this to turn it on?
            // Usually, changing duration while asleep doesn't wake it. Just changing setting.
            // If it is active, we should re-activate with new duration.
            if self.isKeepAwakeActive {
                self.activate()
            }
        }
        durationMenuItem.view = durationSliderView
        menu.addItem(durationMenuItem)

        // ── Blackout Mode toggle (disabled by default when Sleep is active) ──
        let blackoutItem = NSMenuItem(title: L10n.blackoutMode, action: nil, keyEquivalent: "")
        blackoutItem.tag = 102
        blackoutItem.isEnabled = false
        blackoutMenuView.isItemEnabled = false
        blackoutMenuView.onActivate = { [weak self] in
            guard let self = self else { return }
            self.toggleBlackoutMode(blackoutItem)
        }
        blackoutItem.view = blackoutMenuView
        menu.addItem(blackoutItem)

        let keyboardRestorePermissionItem = NSMenuItem(
            title: L10n.keyboardRestorePermissionRequired,
            action: nil,
            keyEquivalent: ""
        )
        keyboardRestorePermissionItem.tag = 105
        keyboardRestorePermissionItem.isHidden = true
        keyboardRestorePermissionMenuView.onActivate = { [weak self] in
            self?.handleKeyboardRestorePermissionAction()
        }
        keyboardRestorePermissionItem.view = keyboardRestorePermissionMenuView
        menu.addItem(keyboardRestorePermissionItem)

        menu.addItem(NSMenuItem.separator())

        // ── About & Quit ──
        let launchAtLoginItem = NSMenuItem(title: L10n.launchAtLogin, action: nil, keyEquivalent: "")
        launchAtLoginItem.tag = 103
        launchAtLoginMenuView.onActivate = { [weak self] in
            guard let self = self else { return }
            self.toggleLaunchAtLogin(launchAtLoginItem)
        }
        launchAtLoginItem.view = launchAtLoginMenuView
        menu.addItem(launchAtLoginItem)

        let notificationItem = NSMenuItem(title: L10n.notifications, action: nil, keyEquivalent: "")
        notificationItem.tag = 104
        notificationMenuView.isOn = canDeliverNotifications
        notificationMenuView.onActivate = { [weak self] in
            guard let self = self else { return }
            self.toggleNotifications(notificationItem)
        }
        notificationItem.view = notificationMenuView
        menu.addItem(notificationItem)

        // ── Language Submenu ──
        let langItem = NSMenuItem(title: L10n.language, action: nil, keyEquivalent: "")
        langItem.tag = 106
        let langSubmenu = NSMenu(title: L10n.language)
        langSubmenu.autoenablesItems = false
        langSubmenu.showsStateColumn = false

        languageSubmenuViews.removeAll()
        for setting in AppLanguageSetting.allCases {
            let item = NSMenuItem()
            let view = TrailingCheckMenuItemView(
                title: setting.localizedName,
                showsIndicator: true,
                width: 150
            )
            view.isOn = (setting == L10n.currentSetting)
            view.onActivate = { [weak self] in
                self?.handleLanguageSelection(setting)
            }
            item.view = view
            languageSubmenuViews[setting] = view
            langSubmenu.addItem(item)
            if setting == .system {
                langSubmenu.addItem(NSMenuItem.separator())
            }
        }
        langItem.submenu = langSubmenu
        self.languageMenuItem = langItem
        self.languageSubmenu = langSubmenu
        menu.addItem(langItem)

        let aboutItem = NSMenuItem(title: L10n.aboutKeepAwake, action: nil, keyEquivalent: "")
        aboutItem.isEnabled = true
        aboutMenuView.onActivate = { [weak self] in
            guard let self = self else { return }
            self.openAppInfo(aboutItem)
        }
        aboutItem.view = aboutMenuView
        menu.addItem(aboutItem)
        let quitItem = NSMenuItem(title: L10n.quit, action: nil, keyEquivalent: "")
        quitItem.isEnabled = true
        quitMenuView.onActivate = { [weak self] in
            guard let self = self else { return }
            self.quitApp(quitItem)
        }
        quitItem.view = quitMenuView
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        resetMenuInteractionState()
        refreshWakeStatus()
        refreshNotificationAuthorizationStatus()
        let isCoffeeActive = isKeepAwakeActive
        if let durationItem = menu.item(withTag: 101) {
            durationItem.isEnabled = isCoffeeActive
            durationSliderView.isEnabled = isCoffeeActive
            durationSliderView.selectedDuration = selectedDuration
        }
        if let blackoutItem = menu.item(withTag: 102) {
            blackoutItem.isEnabled = isCoffeeActive
            blackoutMenuView.isItemEnabled = isCoffeeActive
            blackoutMenuView.isOn = isBlackoutModeActive
        }
        updateKeyboardRestorePermissionMenuItem(in: menu)
        if let launchAtLoginItem = menu.item(withTag: 103) {
            launchAtLoginItem.isEnabled = true
            launchAtLoginMenuView.isOn = SMAppService.mainApp.status == .enabled
        }
        for (setting, view) in languageSubmenuViews {
            view.rowTitle = setting.localizedName
            view.isOn = (setting == L10n.currentSetting)
        }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if item?.view !== blackoutMenuView {
            BlackoutTooltipManager.shared.cancel()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        BlackoutTooltipManager.shared.cancel()
        resetMenuInteractionState()
    }

    private func resetMenuInteractionState() {
        blackoutMenuView.resetInteractionState()
        keyboardRestorePermissionMenuView.resetInteractionState()
        launchAtLoginMenuView.resetInteractionState()
        notificationMenuView.resetInteractionState()
        aboutMenuView.resetInteractionState()
        quitMenuView.resetInteractionState()
        for (_, view) in languageSubmenuViews {
            view.resetInteractionState()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.tag == 101 || menuItem.tag == 102 {
            return isKeepAwakeActive
        }
        return true
    }

    private func updateWakeMenuState(isActive: Bool) {
        if let durationItem = statusItem.menu?.item(withTag: 101) {
            durationItem.isEnabled = isActive
            durationSliderView.isEnabled = isActive
            durationSliderView.selectedDuration = selectedDuration
        }
        if let blackoutItem = statusItem.menu?.item(withTag: 102) {
            blackoutItem.isEnabled = isActive
            blackoutMenuView.isItemEnabled = isActive
            if !isActive {
                blackoutMenuView.isOn = false
            }
        }
    }

    private func refreshWakeStatus() {
        if let process = caffeinateProcess, !process.isRunning {
            // The termination handler is asynchronous. Handle the dead child
            // here as well so a menu refresh cannot leave Blackout active in
            // the small window before that handler reaches the main queue.
            handleCaffeinateTermination(process)
            return
        }

        let isActive = isKeepAwakeActive
        updateWakeMenuState(isActive: isActive)

        guard !isActive else {
            toggleView.isOn = true
            return
        }

        let state = SystemPowerStateReader.shared.read(
            forProcessID: ProcessInfo.processInfo.processIdentifier
        )
        setStatusBarIcon(isAwake: false)
        toggleView.isOn = false

        if state.systemNeverSleeps {
            if let minutes = state.displaySleepMinutes, minutes > 0 {
                toggleView.statusText = L10n.systemNeverSleepsWithDisplaySleep(minutes)
            } else {
                toggleView.statusText = L10n.systemNeverSleeps
            }
        } else if state.hasExternalCaffeinate {
            toggleView.statusText = L10n.otherCaffeinateActive
        } else {
            toggleView.statusText = L10n.allowedToSleep
        }
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

        guard confirmKeyboardRestorePermissionIfNeeded() else { return }

        if !isKeepAwakeActive {
            activate()
            guard isKeepAwakeActive else { return }
        }

        let recoveryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwake-blackout-\(UUID().uuidString).json")
        try? FileManager.default.removeItem(at: recoveryFile)
        blackoutRecoveryURL = recoveryFile

        guard startBlackoutWatchdog(recoveryFile: recoveryFile) else {
            stopBlackoutWatchdog()
            return
        }
        guard BrightnessManager.shared.dimAllDisplays(recoveryFile: recoveryFile) else {
            stopBlackoutWatchdog()
            showNotification(
                title: L10n.blackoutFailedTitle,
                body: L10n.blackoutFailedBody
            )
            return
        }

        blackoutRecoveryURL = recoveryFile
        isBlackoutModeActive = true

        inputMonitor.startMonitoring { [weak self] in
            self?.disableBlackoutMode(autoRestored: true)
        }

        if let blackoutItem = statusItem.menu?.item(withTag: 102) {
            blackoutItem.isEnabled = true
            blackoutMenuView.isItemEnabled = true
            blackoutMenuView.isOn = true
        }

        showNotification(
            title: L10n.blackoutActivatedTitle,
            body: L10n.blackoutActivatedBody
        )
    }

    private var hasKeyboardRestorePermission: Bool {
        CGPreflightListenEventAccess()
    }

    private func confirmKeyboardRestorePermissionIfNeeded() -> Bool {
        if hasKeyboardRestorePermission {
            return true
        }

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: blackoutMouseOnlyAcceptedKey) {
            return true
        }

        defaults.set(true, forKey: blackoutPermissionExplainedKey)
        updateKeyboardRestorePermissionMenuItem(in: statusItem.menu)

        let alert = NSAlert()
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = L10n.keyboardRestorePermissionTitle
        alert.informativeText = L10n.keyboardRestorePermissionBody
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.openSystemSettings)
        alert.addButton(withTitle: L10n.useMouseOnly)
        alert.addButton(withTitle: L10n.cancel)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openKeyboardInputSettings()
            return false
        case .alertSecondButtonReturn:
            defaults.set(true, forKey: blackoutMouseOnlyAcceptedKey)
            return true
        default:
            return false
        }
    }

    private func updateKeyboardRestorePermissionMenuItem(in menu: NSMenu?) {
        guard let item = menu?.item(withTag: 105) else { return }
        let defaults = UserDefaults.standard
        let shouldShow = !hasKeyboardRestorePermission
            && defaults.bool(forKey: blackoutPermissionExplainedKey)
        keyboardRestorePermissionMenuView.rowTitle = defaults.bool(
            forKey: keyboardPermissionRestartPendingKey
        ) ? L10n.keyboardRestoreRestartRequired : L10n.keyboardRestorePermissionRequired
        item.isHidden = !shouldShow
        item.isEnabled = shouldShow
        keyboardRestorePermissionMenuView.isItemEnabled = shouldShow
    }

    private func handleKeyboardRestorePermissionAction() {
        if UserDefaults.standard.bool(forKey: keyboardPermissionRestartPendingKey) {
            restartApp()
        } else {
            openKeyboardInputSettings()
        }
    }

    private func openKeyboardInputSettings() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: blackoutPermissionExplainedKey)

        if CGRequestListenEventAccess() {
            defaults.removeObject(forKey: keyboardPermissionRestartPendingKey)
            updateKeyboardRestorePermissionMenuItem(in: statusItem.menu)
            return
        }

        defaults.set(true, forKey: keyboardPermissionRestartPendingKey)
        updateKeyboardRestorePermissionMenuItem(in: statusItem.menu)

        guard let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    private func restartApp() {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "sleep 1; /usr/bin/open \"$1\"",
            "keepawake-relaunch",
            Bundle.main.bundlePath
        ]

        do {
            try relauncher.run()
            NSApplication.shared.terminate(nil)
        } catch {
            print("KeepAwake: failed to relaunch after permission change: \(error)")
        }
    }

    func disableBlackoutMode(autoRestored: Bool = false, notify: Bool = true) {
        guard isBlackoutModeActive else { return }
        isBlackoutModeActive = false

        inputMonitor.stopMonitoring()
        BrightnessManager.shared.restoreAllDisplays()
        stopBlackoutWatchdog()

        if statusItem.menu?.item(withTag: 102) != nil {
            blackoutMenuView.isOn = false
        }

        if notify {
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
        process.terminationHandler = { [weak self] terminatedProcess in
            DispatchQueue.main.async { [weak self] in
                self?.handleCaffeinateTermination(terminatedProcess)
            }
        }

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

        updateWakeMenuState(isActive: true)

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
        refreshWakeStatus()

        showNotification(title: L10n.deactivatedTitle, body: L10n.deactivatedBody)
    }

    private func handleCaffeinateTermination(_ terminatedProcess: Process) {
        guard caffeinateProcess === terminatedProcess else { return }

        caffeinateProcess = nil
        timer?.invalidate()
        timer = nil
        endTime = nil

        // A dead assertion must never leave Blackout Mode active. Restore the
        // displays even when caffeinate was killed by the system or a crash.
        if isBlackoutModeActive {
            disableBlackoutMode(notify: false)
        }

        refreshWakeStatus()
        print("KeepAwake: caffeinate terminated unexpectedly")
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

    // A menu-bar app is often considered foreground while its menu is open.
    // Without this delegate method macOS may silently suppress the banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func showNotification(title: String, body: String) {
        guard notificationsEnabled else {
            print("Notification skipped because notifications are turned off: \(title)")
            return
        }

        guard notificationAuthorizationResolved else {
            pendingNotifications.append((title: title, body: body))
            print("Notification queued until authorization is resolved: \(title)")
            return
        }

        guard canDeliverNotifications else {
            print("Notification skipped because authorization is disabled: \(title)")
            return
        }

        addNotification(title: title, body: body)
    }

    private func addNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        notificationCenter.add(request) { error in
            if let error = error {
                print("Notification delivery error: \(error)")
            }
        }

        print("Notification - \(title): \(body)")
    }

    @objc func toggleNotifications(_ sender: NSMenuItem) {
        if notificationsEnabled {
            notificationsEnabled = false
            UserDefaults.standard.set(false, forKey: notificationsEnabledKey)
            pendingNotifications.removeAll()
            updateNotificationMenuItem()
            return
        }

        notificationCenter.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }

            switch settings.authorizationStatus {
            case .authorized, .provisional:
                DispatchQueue.main.async {
                    self.notificationAuthorizationStatus = settings.authorizationStatus
                    self.notificationAuthorizationResolved = true
                    self.notificationsEnabled = true
                    UserDefaults.standard.set(true, forKey: self.notificationsEnabledKey)
                    self.updateNotificationMenuItem()
                }
            case .notDetermined:
                self.notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                    if let error = error {
                        print("Notification authorization error: \(error)")
                    }

                    self?.notificationCenter.getNotificationSettings { [weak self] updatedSettings in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            self.notificationAuthorizationStatus = updatedSettings.authorizationStatus
                            self.notificationAuthorizationResolved = true
                            self.notificationsEnabled = granted
                                && (updatedSettings.authorizationStatus == .authorized
                                    || updatedSettings.authorizationStatus == .provisional)
                            UserDefaults.standard.set(
                                self.notificationsEnabled,
                                forKey: self.notificationsEnabledKey
                            )
                            self.updateNotificationMenuItem()
                        }
                    }
                }
            default:
                DispatchQueue.main.async {
                    self.notificationAuthorizationStatus = settings.authorizationStatus
                    self.notificationAuthorizationResolved = true
                    self.notificationsEnabled = false
                    UserDefaults.standard.set(false, forKey: self.notificationsEnabledKey)
                    self.updateNotificationMenuItem()
                    print("Notifications remain off because macOS permission is unavailable")
                }
            }
        }
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

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: launchAtLoginConfiguredKey)
        } catch {
            print("Failed to toggle Launch at Login: \(error)")
        }
    }

    func handleLanguageSelection(_ setting: AppLanguageSetting) {
        guard setting != L10n.currentSetting else { return }

        L10n.currentSetting = setting
        updateLanguageUI()
    }

    private func updateLanguageUI() {
        // 1. Update language submenu
        languageMenuItem?.title = L10n.language
        for (setting, view) in languageSubmenuViews {
            view.rowTitle = setting.localizedName
            view.isOn = (setting == L10n.currentSetting)
        }

        // 2. Update SwiftUI views
        toggleView.state.updateCounter += 1
        durationSliderView.state.updateCounter += 1

        // 3. Update AppKit menu rows
        blackoutMenuView.rowTitle = L10n.blackoutMode
        updateKeyboardRestorePermissionMenuItem(in: statusItem.menu)
        launchAtLoginMenuView.rowTitle = L10n.launchAtLogin
        notificationMenuView.rowTitle = L10n.notifications
        aboutMenuView.rowTitle = L10n.aboutKeepAwake
        quitMenuView.rowTitle = L10n.quit

        // 4. Update toggle status text
        if isKeepAwakeActive {
            if let process = caffeinateProcess, process.isRunning {
                if let end = endTime {
                    let remaining = end.timeIntervalSinceNow
                    if remaining > 0 {
                        updateTitle(remaining: remaining)
                    }
                } else {
                    toggleView.statusText = L10n.indefinitely
                }
            }
        } else {
            refreshWakeStatus()
        }
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
