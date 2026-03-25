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

    // MARK: - Device Enumeration

    func refreshDevices() {
        allDevices = Self.enumerateAllDevices()
    }

    var inputDevices: [DeviceInfo] {
        allDevices.filter { $0.hasInput && !$0.uid.hasPrefix(MacDJConstants.uidPrefix) && $0.name != MacDJConstants.blackHoleName }
    }

    var outputDevices: [DeviceInfo] {
        allDevices.filter { $0.hasOutput && !$0.uid.hasPrefix(MacDJConstants.uidPrefix) && $0.name != MacDJConstants.blackHoleName }
    }

    func findDevice(byUID uid: String) -> AudioObjectID? {
        allDevices.first(where: { $0.uid == uid })?.id
    }

    // MARK: - Default Device Queries

    func getDefaultOutputDevice() -> AudioObjectID? {
        Self.getDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
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

    // MARK: - Set Default Devices

    func setDefaultOutput(_ deviceID: AudioObjectID) throws {
        try Self.setDefaultDevice(deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    func setDefaultInput(_ deviceID: AudioObjectID) throws {
        try Self.setDefaultDevice(deviceID, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    // MARK: - Create Multi-Output Device
    // Sends the SAME audio to both speakers and BlackHole

    func createMultiOutputDevice(outputUID: String) throws -> AudioObjectID {
        // Hardware output FIRST (clock source), BlackHole second with drift compensation
        let subDevices: [[String: Any]] = [
            [
                kAudioSubDeviceUIDKey: outputUID,
                kAudioSubDeviceDriftCompensationKey: 0 as CFNumber,
            ],
            [
                kAudioSubDeviceUIDKey: MacDJConstants.blackHoleUID,
                kAudioSubDeviceDriftCompensationKey: 1 as CFNumber,
            ],
        ]

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: MacDJConstants.multiOutputName,
            kAudioAggregateDeviceUIDKey: MacDJConstants.multiOutputUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: 0 as CFNumber,
            kAudioAggregateDeviceIsStackedKey: 1 as CFNumber,  // 1 = multi-output (verified empirically)
        ]

        var deviceID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr else {
            throw MacDJError.deviceCreationFailed(status)
        }
        refreshDevices()
        return deviceID
    }

    // MARK: - Destroy Devices

    func destroyDevice(_ deviceID: AudioObjectID) {
        guard deviceID != kAudioObjectUnknown else { return }
        AudioHardwareDestroyAggregateDevice(deviceID)
        refreshDevices()
    }

    /// Remove any MacDJ devices left over from a previous crash
    func cleanupOrphanedDevices() {
        let devices = Self.enumerateAllDevices()
        for device in devices where device.uid.hasPrefix(MacDJConstants.uidPrefix) {
            AudioHardwareDestroyAggregateDevice(device.id)
        }
        refreshDevices()
    }

    // MARK: - Device Change Listener

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

    // MARK: - Static Helpers

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

        let hasInput = getChannelCount(deviceID, scope: kAudioObjectPropertyScopeInput) > 0
        let hasOutput = getChannelCount(deviceID, scope: kAudioObjectPropertyScopeOutput) > 0

        return DeviceInfo(
            id: deviceID,
            uid: uid,
            name: name,
            hasInput: hasInput,
            hasOutput: hasOutput
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
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return nil }
        return value as String
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

        // AudioBufferList is variable-size, so allocate exact byte count
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

    private static func setDefaultDevice(
        _ deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &mutableID
        )
        guard status == noErr else {
            throw MacDJError.propertyError(status)
        }
    }
}
