import AudioToolbox
import CoreAudio
import CoreGraphics
import Foundation

/// The default output device's volume and mute, through CoreAudio.
enum SystemVolume {
    static var device: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// 0…1, or nil when the device has no software volume (e.g. some HDMI outputs).
    static var level: Float? {
        guard let device else { return nil }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    static func setLevel(_ level: Float) -> Bool {
        guard let device else { return false }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = Float32(min(max(level, 0), 1))
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    static var isMuted: Bool {
        guard let device else { return false }
        var address = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device else { return false }
        var address = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// One step: 1/16 of the range, or 1/64 with ⌥⇧ (like macOS), snapped to the step grid.
    static func stepped(_ level: Float, up: Bool, fine: Bool) -> Float {
        let steps: Float = fine ? 64 : 16
        let current = (level * steps).rounded()
        return min(max((current + (up ? 1 : -1)) / steps, 0), 1)
    }

    static func symbol(level: Float, muted: Bool) -> String {
        if muted || level == 0 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// The built-in display's brightness, through the DisplayServices framework (private, loaded at runtime so a
/// missing symbol just turns the feature off).
enum SystemBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private struct Functions: @unchecked Sendable {
        let get: Get
        let set: Set
    }

    private static let functions: Functions? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return Functions(get: unsafeBitCast(get, to: Get.self), set: unsafeBitCast(set, to: Set.self))
    }()

    static var builtInDisplay: CGDirectDisplayID? {
        var count = UInt32(0)
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)
        return displays.first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var level: Float? {
        guard let functions, let display = builtInDisplay else { return nil }
        var value = Float(0)
        return functions.get(display, &value) == 0 ? value : nil
    }

    @discardableResult
    static func setLevel(_ level: Float) -> Bool {
        guard let functions, let display = builtInDisplay else { return false }
        return functions.set(display, min(max(level, 0), 1)) == 0
    }
}
