import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import IOBluetooth
import IOKit.ps
import NotchKit
import SwiftUI

/// Volume, brightness, battery and headphone HUDs in the notch.
///
/// With Accessibility permission, the volume and brightness keys are taken over: NotchMan changes the level
/// itself and swallows the key so macOS's own overlay never shows. Without it, volume changes are mirrored in
/// the notch (macOS's overlay shows too). Keys NotchMan can't handle (e.g. an external display's brightness)
/// pass through untouched.
@MainActor
final class SystemHUDs: NSObject {
    static let volumeKey = "hud.volume"
    static let brightnessKey = "hud.brightness"
    static let batteryKey = "hud.battery"
    static let bluetoothKey = "hud.bluetooth"

    static func isOn(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private let show: (NotchTransient) -> Void
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var batterySource: CFRunLoopSource?
    private var lastPower: (onAC: Bool, percent: Int)?
    private var bluetoothNotification: IOBluetoothUserNotification?
    private var bluetoothWatchStarted = Date.distantFuture
    private var volumeListenerDevice: AudioDeviceID?
    /// Our own key presses also trip the volume listener; skip the echo.
    private var lastKeyChange = Date.distantPast

    /// The C callbacks have no context; the live instance is kept here (main thread only).
    nonisolated(unsafe) private static var current: SystemHUDs?

    init(show: @escaping (NotchTransient) -> Void) {
        self.show = show
        super.init()
        Self.current = self
    }

    func start() {
        installKeyTap()
        installVolumeListener()
        installBatteryWatcher()
        installBluetoothWatcher()
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows macOS's Accessibility prompt (once); NotchMan picks up the grant on its next check.
    static func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt's value.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Retries the key tap (after Accessibility was granted).
    func refresh() {
        if tap == nil { installKeyTap() }
    }

    var isTakingOverKeys: Bool { tap != nil }

    /// Checks every few seconds for the Accessibility grant (made in System Settings, outside NotchMan).
    func waitForAccessibility() {
        Task { [weak self] in
            while let self, self.tap == nil {
                try? await Task.sleep(for: .seconds(5))
                self.refresh()
            }
        }
    }

    // MARK: - Media keys

    private enum MediaKey: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    private func installKeyTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << 14)  // NSEventType.systemDefined
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { SystemHUDs.current?.reenableTap() }
                return Unmanaged.passUnretained(event)
            }
            let handled = MainActor.assumeIsolated { SystemHUDs.current?.handleSystemEvent(event) ?? false }
            return handled ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
    }

    private func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true to swallow the event.
    private func handleSystemEvent(_ cgEvent: CGEvent) -> Bool {
        guard let event = NSEvent(cgEvent: cgEvent), event.subtype.rawValue == 8 else { return false }
        let data = event.data1
        guard let key = MediaKey(rawValue: (data & 0xFFFF_0000) >> 16) else { return false }
        let isDown = ((data & 0xFF00) >> 8) == 0x0A
        let fine = event.modifierFlags.contains(.option) && event.modifierFlags.contains(.shift)

        switch key {
        case .soundUp, .soundDown, .mute:
            guard Self.isOn(Self.volumeKey), SystemVolume.level != nil else { return false }
            if isDown { changeVolume(key, fine: fine) }
            return true
        case .brightnessUp, .brightnessDown:
            guard Self.isOn(Self.brightnessKey), let level = SystemBrightness.level else { return false }
            if isDown {
                let next = SystemVolume.stepped(level, up: key == .brightnessUp, fine: fine)
                guard SystemBrightness.setLevel(next) else { return false }
                show(NotchTransient(id: "brightness", systemImage: next < 0.5 ? "sun.min.fill" : "sun.max.fill", level: Double(next)))
            }
            return true
        }
    }

    private func changeVolume(_ key: MediaKey, fine: Bool) {
        guard let level = SystemVolume.level else { return }
        lastKeyChange = Date()
        if key == .mute {
            SystemVolume.setMuted(!SystemVolume.isMuted)
        } else {
            let next = SystemVolume.stepped(level, up: key == .soundUp, fine: fine)
            SystemVolume.setLevel(next)
            // Turning it up unmutes, as macOS does.
            if key == .soundUp, SystemVolume.isMuted { SystemVolume.setMuted(false) }
        }
        showVolume()
    }

    private func showVolume() {
        guard let level = SystemVolume.level else { return }
        let muted = SystemVolume.isMuted
        show(NotchTransient(id: "volume", systemImage: SystemVolume.symbol(level: level, muted: muted),
                            level: muted ? 0 : Double(level)))
    }

    // MARK: - Volume changes from elsewhere (menu bar, other apps, or keys without Accessibility)

    private func installVolumeListener() {
        guard let device = SystemVolume.device else { return }
        volumeListenerDevice = device
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main) { _, _ in
            MainActor.assumeIsolated {
                guard let hud = SystemHUDs.current, SystemHUDs.isOn(SystemHUDs.volumeKey),
                      Date().timeIntervalSince(hud.lastKeyChange) > 0.3 else { return }
                hud.showVolume()
            }
        }
    }

    // MARK: - Battery

    private func installBatteryWatcher() {
        lastPower = Self.powerState()
        guard let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { SystemHUDs.current?.powerChanged() }
        }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        batterySource = source
    }

    private func powerChanged() {
        guard let now = Self.powerState() else { return }
        defer { lastPower = now }
        guard Self.isOn(Self.batteryKey), let before = lastPower else { return }
        if let message = Self.powerMessage(before: before, now: now) {
            show(NotchTransient(id: "battery", systemImage: message.symbol, text: message.text, tint: message.tint, duration: 2.5))
        }
    }

    /// What changed worth showing: plugged in / unplugged, or dropping to 20% / 10% on battery.
    static func powerMessage(before: (onAC: Bool, percent: Int), now: (onAC: Bool, percent: Int))
        -> (symbol: String, text: String, tint: Color)? {
        if now.onAC != before.onAC {
            return now.onAC
                ? ("battery.100percent.bolt", "\(now.percent)%", .green)
                : (batterySymbol(now.percent), "\(now.percent)%", .white)
        }
        if !now.onAC, let threshold = [20, 10].first(where: { now.percent <= $0 && before.percent > $0 }) {
            return (threshold == 10 ? "battery.0percent" : "battery.25percent", "\(now.percent)% left", threshold == 10 ? .red : .orange)
        }
        return nil
    }

    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private static func powerState() -> (onAC: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (onAC, Int((Double(current) / Double(max) * 100).rounded()))
        }
        return nil
    }

    // MARK: - Headphones

    private func installBluetoothWatcher() {
        guard Self.isOn(Self.bluetoothKey) else { return }
        bluetoothWatchStarted = Date()
        bluetoothNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    /// IOBluetooth calls this on its own queue (not the main thread), and right after registering once for every
    /// device that's already connected. Read what's needed here, then hop to the main thread.
    @objc nonisolated private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Audio devices only (headphones, speakers); keyboards and mice reconnect too often to be news.
        guard device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) else { return }
        let name = device.name ?? "Headphones"
        DispatchQueue.main.async {
            MainActor.assumeIsolated { SystemHUDs.current?.headphonesConnected(name) }
        }
    }

    private func headphonesConnected(_ name: String) {
        // The burst for devices already connected when NotchMan starts isn't news.
        guard Self.isOn(Self.bluetoothKey), Date().timeIntervalSince(bluetoothWatchStarted) > Self.launchBurst else { return }
        show(NotchTransient(id: "bluetooth", systemImage: Self.headphonesSymbol(name), text: name, tint: .white, duration: 2.5))
    }

    static let launchBurst: TimeInterval = 3

    static func headphonesSymbol(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        return "headphones"
    }
}
