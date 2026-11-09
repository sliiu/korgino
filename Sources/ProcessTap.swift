import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// 通话时只抓通话软件的声音，并在抓的同时把它静音：耳机里只剩同传译音。
/// 通话软件就是把译音设备（如 BlackHole）当麦克风的那个程序，微信、腾讯会议、Zoom 都一样，不认名字。
/// 停止（或本 App 退出）后原声自动恢复，因为静音只在有人读这个 tap 时生效。
final class ProcessTapCapture: @unchecked Sendable {
    private let relayUID: String
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private let queue = DispatchQueue(label: "com.sliiu.Korgino.calltap", qos: .userInitiated)
    private var description: CATapDescription?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var timer: DispatchSourceTimer?
    private var tapped: Set<String> = []

    /// `relayUID`: the output device the translated voice goes to. Whoever listens to it is the call app.
    init(relayUID: String, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.relayUID = relayUID
        self.onBuffer = onBuffer
    }

    func start() throws {
        let ids = callBundleIDs()
        let desc = CATapDescription(monoMixdownOfProcesses: [])
        if #available(macOS 26.0, *) {
            desc.bundleIDs = ids
            desc.isProcessRestoreEnabled = true
        } else {
            // 26 之前没有 bundleIDs，只能用进程对象；restore 也没有，调用期间进程重启就断了。
            desc.processes = Self.processIDs(forBundleIDs: ids)
        }
        desc.uuid = UUID()
        desc.name = "Korgino call"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        description = desc
        tapped = Set(ids)

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else { throw TErr(String(format: L("无法抓取通话声音（%d）"), status)) }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw TErr(String(format: L("无法抓取通话声音（%d）"), status))
        }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Korgino Call Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        // The tap needs a clock. The output device it would have played on gives one.
        if let output = Self.defaultOutputUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            stop()
            throw TErr(String(format: L("无法抓取通话声音（%d）"), status))
        }
        aggregateID = device

        let deliver = onBuffer
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, input, _, _, _ in
            guard let wrapped = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  wrapped.frameLength > 0, let copy = wrapped.detachedCopy() else { return }
            deliver(copy)
        }
        guard status == noErr, let procID else {
            stop()
            throw TErr(String(format: L("无法抓取通话声音（%d）"), status))
        }
        status = AudioDeviceStart(device, procID)
        guard status == noErr else {
            stop()
            throw TErr(String(format: L("无法抓取通话声音（%d）"), status))
        }
        watchCallApps()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        // Let a look already under way finish before the tap it updates goes away.
        queue.sync {}
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        description = nil
    }

    // MARK: Processes

    /// A call app picks up the device only once the call begins, and some move their audio into a helper then.
    /// Neither changes anything the HAL notifies about, so look again every second.
    private func watchCallApps() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in self?.refresh() }
        source.resume()
        timer = source
    }

    private func refresh() {
        guard let desc = description, tapID != kAudioObjectUnknown else { return }
        let ids = callBundleIDs()
        guard !Set(ids).isSubset(of: tapped) else { return }
        tapped.formUnion(ids)
        if #available(macOS 26.0, *) {
            desc.bundleIDs = Array(tapped)
        } else {
            desc.processes = Self.processIDs(forBundleIDs: Array(tapped))
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var ref: CATapDescription? = desc
        _ = withUnsafeMutablePointer(to: &ref) { ptr in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription?>.size), ptr)
        }
    }

    /// Apps recording from the relay device, plus their helpers (bundle IDs under theirs), since the far side
    /// can play from a helper. Never this app: it writes to the relay device and does not listen to it.
    private func callBundleIDs() -> [String] { Self.callBundleIDs(relayUID: relayUID) }

    /// Whether a call is actually up right now: some app is recording from the relay device.
    /// A relay picked for a past call says nothing about this minute — with one still chosen but no call
    /// running, 系统声音 must keep listening to the whole machine, or a video in a browser is lost.
    static func callIsLive(relayUID: String) -> Bool { !callBundleIDs(relayUID: relayUID).isEmpty }

    private static func callBundleIDs(relayUID: String) -> [String] {
        guard let relay = Self.deviceID(uid: relayUID) else { return [] }
        let own = Bundle.main.bundleIdentifier ?? ""
        var owners: Set<String> = []
        var everyone: [String] = []
        for object in Self.processObjects() {
            guard let id = Self.string(object, kAudioProcessPropertyBundleID), id != own else { continue }
            everyone.append(id)
            if Self.uint(object, kAudioProcessPropertyIsRunningInput) != 0,
               Self.objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput).contains(relay) {
                owners.insert(id)
            }
        }
        var found = owners
        for id in everyone where owners.contains(where: { id.hasPrefix($0 + ".") }) {
            found.insert(id)
        }
        return Array(found)
    }

    /// 26 之前 tap 只认进程对象。名字一多（主程序 + 若干 helper）就得逐个查回来。
    private static func processIDs(forBundleIDs wanted: [String]) -> [AudioObjectID] {
        guard !wanted.isEmpty else { return [] }
        let set = Set(wanted)
        return processObjects().filter { object in
            guard let id = string(object, kAudioProcessPropertyBundleID) else { return false }
            return set.contains(id)
        }
    }

    private static func processObjects() -> [AudioObjectID] {
        objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    private static func deviceID(uid: String) -> AudioObjectID? {
        for id in objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
            where string(id, kAudioDevicePropertyDeviceUID) == uid {
            return id
        }
        return nil
    }

    private static func objects(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        let value = ref.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }
}
