import AppKit
import Carbon.HIToolbox

/// The system-wide shortcut that opens the notch from anywhere. Carbon's hot keys need no Accessibility
/// permission (unlike a global key monitor) and swallow the keystroke so it doesn't reach the front app.
@MainActor
final class HotKey {
    enum Preset: String, CaseIterable, Identifiable {
        case optionSpace, controlSpace, commandShiftSpace, optionN, off

        var id: String { rawValue }

        var title: String {
            switch self {
            case .optionSpace: "⌥ Space"
            case .controlSpace: "⌃ Space"
            case .commandShiftSpace: "⇧⌘ Space"
            case .optionN: "⌥ N"
            case .off: "Off"
            }
        }

        fileprivate var keyCode: UInt32 {
            self == .optionN ? UInt32(kVK_ANSI_N) : UInt32(kVK_Space)
        }

        fileprivate var modifiers: UInt32 {
            switch self {
            case .optionSpace, .optionN: UInt32(optionKey)
            case .controlSpace: UInt32(controlKey)
            case .commandShiftSpace: UInt32(cmdKey | shiftKey)
            case .off: 0
            }
        }
    }

    static let defaultsKey = "globalHotKey"

    static var preset: Preset {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Preset.init) ?? .optionSpace
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registered: Preset?
    private let action: @MainActor () -> Void

    /// Carbon calls back through a C function with no context, so the live instance is kept here.
    nonisolated(unsafe) private static var current: HotKey?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        Self.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.current?.action() } }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// Registers the shortcut chosen in Settings (cheap to call again; only re-registers on change).
    func update() {
        let preset = Self.preset
        guard preset != registered else { return }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = preset
        guard preset != .off else { return }
        let id = EventHotKeyID(signature: OSType(0x4E_4D_41_4E), id: 1)  // "NMAN"
        RegisterEventHotKey(preset.keyCode, preset.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
