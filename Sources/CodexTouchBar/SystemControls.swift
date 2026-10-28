import AppKit
import AudioToolbox
import MonitorCore
import TouchBarBridge

struct SystemControlFeedback {
    let control: ControlSwipe.Control
    let message: String
    let fraction: Double?
}

final class SystemControls {
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var display: CGDirectDisplayID = 0
    private var level: Float?
    private var control: ControlSwipe.Control?
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    func end() { level = nil; control = nil }

    func adjust(_ kind: ControlSwipe.Control, delta: Double) -> SystemControlFeedback {
        let message = adjustMessage(kind, delta: delta)
        return SystemControlFeedback(control: kind, message: message,
                                     fraction: message.hasSuffix("%") ? level.map(Double.init) : nil)
    }

    private func adjustMessage(_ kind: ControlSwipe.Control, delta: Double) -> String {
        let title = kind == .volume ? "音量" : "亮度"
        if control == nil {
            control = kind
            if kind == .volume {
                var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var size = UInt32(MemoryLayout<AudioObjectID>.size)
                guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return "音量不可调节" }
                var writable = DarwinBoolean(false)
                guard AudioObjectIsPropertySettable(device, &volumeAddress, &writable) == noErr, writable.boolValue else { return "当前音频设备不支持调节音量" }
                var value: Float = 0
                size = UInt32(MemoryLayout<Float>.size)
                if AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &value) == noErr, value.isFinite { level = value }
            } else {
                var value: Float = 0
                if CTBReadBrightness(&display, &value), value.isFinite { level = value }
            }
        }
        guard control == kind, let previous = level else { return "\(title)不可调节" }
        let value = min(1, max(kind == .brightness ? 0.05 : 0, previous + Float(delta)))
        if delta != 0 {
            let ok: Bool
            if kind == .volume {
                var currentDevice = AudioObjectID(kAudioObjectUnknown)
                var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var size = UInt32(MemoryLayout<AudioObjectID>.size)
                guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &currentDevice) == noErr, currentDevice == device else {
                    level = nil; return "音频设备已切换，请重新滑动"
                }
                var output = value
                ok = AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float>.size), &output) == noErr
            } else { ok = CTBWriteBrightness(display, value) }
            guard ok else { level = nil; return "\(title)调节失败" }
            level = value
        }
        return "\(title)  \(Int((value * 100).rounded()))%"
    }
}
