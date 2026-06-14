import CoreAudio
import Foundation

@MainActor
final class AudioDeviceManager {
    private(set) var allDevices: [DeviceInfo] = []
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    var onDevicesChanged: (() -> Void)?

    init() {
        refreshDevices()
    }

    func refreshDevices() {
        allDevices = Self.enumerateAllDevices()
    }

    var inputDevices: [DeviceInfo] {
        allDevices.filter { $0.hasInput && !$0.uid.hasPrefix(MicRelayConstants.uidPrefix) && $0.uid != MicRelayConstants.blackHoleUID }
    }

    var outputDevices: [DeviceInfo] {
        allDevices.filter { $0.hasOutput && !$0.uid.hasPrefix(MicRelayConstants.uidPrefix) }
    }

    var blackHoleDevice: DeviceInfo? {
        allDevices.first { $0.uid == MicRelayConstants.blackHoleUID }
    }

    func findDevice(byUID uid: String) -> AudioObjectID? {
        allDevices.first(where: { $0.uid == uid })?.id
    }

    func cleanupOrphanedMicRelayDevices() {
        for device in Self.enumerateAllDevices() where device.uid.hasPrefix(MicRelayConstants.uidPrefix) {
            AudioHardwareDestroyAggregateDevice(device.id)
        }
        refreshDevices()
    }

    func getDefaultInputDevice() -> AudioObjectID? {
        Self.getDefaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    func getDeviceUID(for deviceID: AudioObjectID) -> String? {
        Self.getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    func getDeviceName(for deviceID: AudioObjectID) -> String? {
        Self.getStringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    func startListeningForDeviceChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshDevices()
                self?.onDevicesChanged?()
            }
        }
        deviceChangeListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    func stopListeningForDeviceChanges() {
        guard let block = deviceChangeListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        deviceChangeListenerBlock = nil
    }

    private static func enumerateAllDevices() -> [DeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { buildDeviceInfo($0) }
    }

    private static func buildDeviceInfo(_ deviceID: AudioObjectID) -> DeviceInfo? {
        guard let uid = getStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
              let name = getStringProperty(deviceID, selector: kAudioObjectPropertyName)
        else { return nil }

        return DeviceInfo(
            id: deviceID,
            uid: uid,
            name: name,
            hasInput: getChannelCount(deviceID, scope: kAudioObjectPropertyScopeInput) > 0,
            hasOutput: getChannelCount(deviceID, scope: kAudioObjectPropertyScopeOutput) > 0
        )
    }

    private static func getStringProperty(
        _ deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let rawValue = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<CFString?>.size,
            alignment: MemoryLayout<CFString?>.alignment
        )
        defer { rawValue.deallocate() }
        rawValue.initializeMemory(as: CFString?.self, repeating: nil, count: 1)
        defer { rawValue.assumingMemoryBound(to: CFString?.self).deinitialize(count: 1) }

        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawValue)
        guard status == noErr else { return nil }
        return rawValue.load(as: CFString?.self) as String?
    }

    private static func getChannelCount(
        _ deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList)
        guard status == noErr else { return 0 }

        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        return ablPointer.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func getDefaultDevice(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
