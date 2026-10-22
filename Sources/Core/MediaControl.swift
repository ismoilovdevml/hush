// Media transport + system volume. These ride macOS/AVRCP, not the Sony control channel.
import AppKit
import CoreAudio

/// Synthetic media keys are posted through CGEvent, which macOS gates behind Accessibility.
/// The grant is tied to the code signature, so every ad-hoc rebuild invalidates it.
enum MediaKeyAuth {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func prompt() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

enum MediaKey: Int32 {
    case volumeUp = 0, volumeDown = 1, mute = 7, playPause = 16, next = 17, previous = 18

    func post() {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(down ? 0xa00 : 0xb00))
            let data1 = Int((rawValue << 16) | (down ? 0xa00 : 0xb00))
            guard let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                             modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                             context: nil, subtype: 8, data1: data1, data2: -1),
                  let cg = e.cgEvent else { continue }
            cg.post(tap: .cghidEventTap)
        }
    }
}

/// Reads and writes the real output-device volume through CoreAudio.
/// Shelling out to `osascript` per slider tick was both slow and out of step with the
/// system volume; this is the same property Control Center drives, so the two stay in sync.
/// Bluetooth outputs usually expose no "main" volume element, only the stereo channels,
/// so both cases are handled.
enum SystemVolume {
    static func address(_ selector: AudioObjectPropertySelector,
                                _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    /// Which elements actually carry a settable scalar volume on this device.
    static func elements(of dev: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var main = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(dev, &main) { return [kAudioObjectPropertyElementMain] }

        var pair = address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyElementMain)
        var channels: (UInt32, UInt32) = (1, 2)
        var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        _ = withUnsafeMutablePointer(to: &channels) {
            AudioObjectGetPropertyData(dev, &pair, 0, nil, &size, $0)
        }
        return [channels.0, channels.1]
    }

    static func get() -> Double {
        guard let dev = defaultOutputDevice() else { return 0 }
        var total: Float32 = 0, n = 0
        for el in elements(of: dev) {
            var addr = address(kAudioDevicePropertyVolumeScalar, el)
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr { total += v; n += 1 }
        }
        return n > 0 ? Double(total / Float32(n)) * 100 : 0
    }

    static func set(_ percent: Double) {
        guard let dev = defaultOutputDevice() else { return }
        var v = Float32(min(max(percent, 0), 100) / 100)
        let size = UInt32(MemoryLayout<Float32>.size)
        for el in elements(of: dev) {
            var addr = address(kAudioDevicePropertyVolumeScalar, el)
            guard AudioObjectHasProperty(dev, &addr) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { continue }
            AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &v)
        }
    }

    /// Fires when the volume is changed anywhere else (media keys, Control Center, another app).
    static func observe(_ changed: @escaping () -> Void) {
        observer = VolumeObserver(onChange: changed)
    }

    private static var observer: VolumeObserver?
}

/// Keeps a volume listener on whichever device is the default output *right now*.
///
/// Registering once at launch is not enough: unplugging the headphones makes a different
/// device the default, and a listener registered on the old device hears nothing about the
/// new one. That is why the slider stopped following the keyboard after a disconnect.
private final class VolumeObserver {
    private var device: AudioDeviceID?
    private var elements: [AudioObjectPropertyElement] = []
    private let onChange: () -> Void
    private lazy var volumeChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.onChange()
    }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange

        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, DispatchQueue.main
        ) { [weak self] _, _ in
            self?.rebind()
            self?.onChange()
        }
        rebind()
    }

    private func rebind() {
        if let old = device {
            for element in elements {
                var addr = SystemVolume.address(kAudioDevicePropertyVolumeScalar, element)
                _ = AudioObjectRemovePropertyListenerBlock(old, &addr, DispatchQueue.main, volumeChanged)
            }
        }
        device = SystemVolume.defaultOutputDevice()
        elements = device.map { SystemVolume.elements(of: $0) } ?? []
        guard let device else { return }
        for element in elements {
            var addr = SystemVolume.address(kAudioDevicePropertyVolumeScalar, element)
            _ = AudioObjectAddPropertyListenerBlock(device, &addr, DispatchQueue.main, volumeChanged)
        }
    }
}
