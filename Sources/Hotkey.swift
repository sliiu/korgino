import AppKit
import Carbon.HIToolbox
import SwiftUI

extension HotkeySpec {
    var menuModifierMask: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbonModifiers & 4096 != 0 { f.insert(.control) }
        if carbonModifiers & 2048 != 0 { f.insert(.option) }
        if carbonModifiers & 512 != 0 { f.insert(.shift) }
        if carbonModifiers & 256 != 0 { f.insert(.command) }
        return f
    }

    /// 从一次按键读出一组快捷键。只有修饰键的按下返回 nil。
    static func from(event: NSEvent) -> HotkeySpec? {
        guard event.type == .keyDown else { return nil }
        let code = Int(event.keyCode)
        // Ignore pure modifiers
        let modOnly: Set<Int> = [
            kVK_Shift, kVK_RightShift, kVK_Control, kVK_RightControl,
            kVK_Option, kVK_RightOption, kVK_Command, kVK_RightCommand,
            kVK_CapsLock, kVK_Function,
        ]
        if modOnly.contains(code) { return nil }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= 4096 }
        if flags.contains(.option) { mods |= 2048 }
        if flags.contains(.shift) { mods |= 512 }
        if flags.contains(.command) { mods |= 256 }
        // Global hotkeys need at least one modifier
        guard mods != 0 else { return nil }
        return HotkeySpec(keyCode: UInt32(code), carbonModifiers: mods)
    }

    /// Character for NSMenuItem.keyEquivalent (lowercase letter / digit / symbol).
    var menuKeyEquivalent: String {
        Self.menuChar(keyCode)
    }
}

/// Click to record a key combo (Esc cancels recording).
struct HotkeyRecorderButton<Accessory: View>: View {
    let action: HotkeyAction
    @Binding var enabled: Bool
    @Binding var spec: HotkeySpec
    var conflictWarning: String?
    var showsToggle: Bool
    var onChange: (HotkeySpec) -> Void
    var accessory: () -> Accessory

    @State private var recording = false

    init(
        action: HotkeyAction,
        enabled: Binding<Bool>,
        spec: Binding<HotkeySpec>,
        conflictWarning: String?,
        showsToggle: Bool = true,
        onChange: @escaping (HotkeySpec) -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.action = action
        self._enabled = enabled
        self._spec = spec
        self.conflictWarning = conflictWarning
        self.showsToggle = showsToggle
        self.onChange = onChange
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                if showsToggle {
                    Toggle(action.title, isOn: $enabled)
                        .toggleStyle(CheckToggleStyle())
                } else {
                    Text(action.title)
                }
                accessory()
                Spacer(minLength: 12)
                recordButton
                    .disabled(!enabled)
                    .background(
                        HotkeyCaptureRepresentable(isRecording: $recording) { event in
                            if event.keyCode == UInt16(kVK_Escape) {
                                recording = false
                                return
                            }
                            if let next = HotkeySpec.from(event: event) {
                                spec = next
                                onChange(next)
                                recording = false
                            }
                        }
                    )
                if enabled {
                    IconButton(icon: .back, help: String(format: L("恢复默认（%@）"), String(describing: action.default.display))) {
                        let d = action.default
                        spec = d
                        onChange(d)
                        recording = false
                    }
                    .disabled(spec == action.default)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: SettingsChrome.rowMinHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
            if let w = conflictWarning, !w.isEmpty, enabled {
                HStack(spacing: 6) {
                    Circle().fill(Theme.attention).frame(width: 6, height: 6)
                    Text(w)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 36)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }
            }
        }
    }

    /// 没开的行右边是一行蓝字，开着的行是键帽。
    private var recordButton: some View {
        Button {
            recording.toggle()
        } label: {
            if !enabled {
                Text(L("录制快捷键"))
                    .font(Theme.TypeScale.label)
                    .foregroundStyle(Color.accentColor)
            } else {
                Group {
                    if recording {
                        Text(L("按下快捷键…"))
                    } else {
                        HStack(spacing: 1) {
                            ForEach(Array(spec.keys.enumerated()), id: \.offset) { _, key in
                                Text(key)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(Theme.TypeScale.label)
                .foregroundStyle(recording ? Color.accentColor : Color.primary)
                .padding(.horizontal, 8)
                .frame(minWidth: 34, minHeight: 22)
                .background(
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .fill(Theme.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 0, y: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Invisible NSView that installs a local key-down monitor while recording.
private struct HotkeyCaptureRepresentable: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.parent = self
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.setRecording(isRecording)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var parent: HotkeyCaptureRepresentable?
        private var monitor: Any?

        func setRecording(_ on: Bool) {
            if on {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.parent?.onKey(event)
                    // Swallow so the combo doesn't go elsewhere while recording
                    return nil
                }
            } else if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}
