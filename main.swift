import Cocoa
import Foundation
import UserNotifications

// Dynamic loading of private DisplayServices framework for screen brightness control
typealias DisplayServicesSetBrightnessType = @convention(c) (CGDirectDisplayID, Float) -> Int32
typealias DisplayServicesGetBrightnessType = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

class BrightnessManager {
    static let shared = BrightnessManager()
    private var displayServicesHandle: UnsafeMutableRawPointer?
    private var setBrightnessFunc: DisplayServicesSetBrightnessType?
    private var getBrightnessFunc: DisplayServicesGetBrightnessType?
    
    init() {
        displayServicesHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices", RTLD_LAZY)
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
        let result = CGGetActiveDisplayList(maxDisplays, &activeDisplays, &displayCount)
        if result == .success {
            return Array(activeDisplays.prefix(Int(displayCount)))
        }
        return [CGMainDisplayID()]
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var caffeinateProcess: Process?
    var timer: Timer?
    var endTime: Date?
    var selectedDurationName: String = "Indefinitely"
    
    // Blackout Mode state
    var isBlackoutModeActive: Bool = false
    var savedBrightnesses: [CGDirectDisplayID: Float] = [:]
    
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
        
        // Save current brightness of all displays and set to 0.0
        let displays = BrightnessManager.shared.getActiveDisplays()
        for display in displays {
            let current = BrightnessManager.shared.getBrightness(displayID: display)
            savedBrightnesses[display] = current
            BrightnessManager.shared.setBrightness(displayID: display, level: 0.0)
        }
        
        // Update UI
        if let blackoutItem = statusItem.menu?.item(withTag: 102) {
            blackoutItem.state = .on
        }
        
        showNotification(title: "Blackout Mode Activated", body: "Screens are blacked out to save energy. Press F2 (brightness up) to restore manually.")
    }
    
    func disableBlackoutMode() {
        guard isBlackoutModeActive else { return }
        isBlackoutModeActive = false
        
        // Restore saved brightnesses
        for (display, brightness) in savedBrightnesses {
            BrightnessManager.shared.setBrightness(displayID: display, level: brightness)
        }
        savedBrightnesses.removeAll()
        
        // Update UI
        if let blackoutItem = statusItem.menu?.item(withTag: 102) {
            blackoutItem.state = .off
        }
        
        showNotification(title: "Blackout Mode Deactivated", body: "Screen brightness restored.")
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
                // If 8 AM has passed today, target 8 AM tomorrow
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
        
        // Start caffeinate process
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
        
        // Set up timer if a duration limit is set
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
        
        // Update menu status
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
        
        // Set initial countdown string
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
        
        // Print to stdout/stderr for logging
        print("Notification - \(title): \(body)")
    }
    
    @objc func showAbout(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "About KeepAwake"
        alert.informativeText = "KeepAwake is a 100% native macOS menubar app that prevents your Mac from sleeping or locking.\n\nIncludes Blackout Mode to safely dim displays to 0% for automated agents and Energy Saving.\n\nBuilt with Swift & AppKit.\nVersion 1.0.0"
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
