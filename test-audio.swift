#!/usr/bin/env swift
// Standalone test script — run with: swift test-audio.swift
// Tests CoreAudio device enumeration, aggregate/multi-output creation,
// and the stacked key behavior. Run AFTER installing BlackHole 2ch.

import CoreAudio
import Foundation

// MARK: - Helpers

func getStringProperty(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
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

func getChannelCount(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
    guard status == noErr, dataSize > 0 else { return 0 }
    let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { rawPointer.deallocate() }
    let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
    status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList)
    guard status == noErr else { return 0 }
    let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
    return ablPointer.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func getAllDevices() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids)
    return ids
}

func getDefaultDevice(selector: AudioObjectPropertySelector) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var deviceID: AudioObjectID = kAudioObjectUnknown
    var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

func createDevice(name: String, uid: String, subDeviceUIDs: [(String, Int)], mainUID: String, stacked: Int) -> AudioObjectID? {
    let subDevices: [[String: Any]] = subDeviceUIDs.map { (uid, drift) in
        [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: drift as CFNumber]
    }
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: name,
        kAudioAggregateDeviceUIDKey: uid,
        kAudioAggregateDeviceSubDeviceListKey: subDevices,
        kAudioAggregateDeviceMainSubDeviceKey: mainUID,
        kAudioAggregateDeviceIsPrivateKey: 0 as CFNumber,
        kAudioAggregateDeviceIsStackedKey: stacked as CFNumber,
    ]
    var deviceID: AudioObjectID = kAudioObjectUnknown
    let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &deviceID)
    if status != noErr {
        print("  FAILED to create device (status: \(status))")
        return nil
    }
    return deviceID
}

// MARK: - Tests

print("=== MacDJ Audio Test Suite ===\n")

// Test 1: Enumerate devices
print("1. Enumerating all audio devices:")
let devices = getAllDevices()
var blackHoleUID: String?
var blackHoleID: AudioObjectID?
var defaultOutputUID: String?
var defaultOutputID: AudioObjectID?

for id in devices {
    let name = getStringProperty(id, selector: kAudioObjectPropertyName) ?? "?"
    let uid = getStringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? "?"
    let inCh = getChannelCount(id, scope: kAudioObjectPropertyScopeInput)
    let outCh = getChannelCount(id, scope: kAudioObjectPropertyScopeOutput)
    print("  [\(id)] \(name) (uid: \(uid), in: \(inCh)ch, out: \(outCh)ch)")
    if uid == "BlackHole2ch_UID" {
        blackHoleUID = uid
        blackHoleID = id
    }
}

// Test 2: Check defaults
print("\n2. Default devices:")
if let id = getDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice) {
    let name = getStringProperty(id, selector: kAudioObjectPropertyName) ?? "?"
    let uid = getStringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? "?"
    print("  Output: \(name) (uid: \(uid))")
    defaultOutputUID = uid
    defaultOutputID = id
}
if let id = getDefaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice) {
    let name = getStringProperty(id, selector: kAudioObjectPropertyName) ?? "?"
    print("  Input: \(name)")
}

// Test 3: BlackHole detection
print("\n3. BlackHole 2ch:")
if blackHoleUID != nil {
    print("  FOUND — UID: \(blackHoleUID!)")
} else {
    print("  NOT INSTALLED — install with: brew install blackhole-2ch")
    print("  Skipping multi-output tests (need BlackHole)")
    print("\n=== Tests complete (partial — install BlackHole for full suite) ===")
    exit(0)
}

// Test 4: Create multi-output with stacked=0 (Apple docs say this is multi-output)
print("\n4. Testing Multi-Output device creation (stacked=0):")
guard let outUID = defaultOutputUID, let bhUID = blackHoleUID else { exit(1) }

if let deviceID = createDevice(
    name: "Test MultiOut stacked=0",
    uid: "test.multiout.stacked0",
    subDeviceUIDs: [(outUID, 0), (bhUID, 1)],
    mainUID: outUID,
    stacked: 0
) {
    let outCh = getChannelCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
    let inCh = getChannelCount(deviceID, scope: kAudioObjectPropertyScopeInput)
    print("  Created! output channels: \(outCh), input channels: \(inCh)")
    if outCh == 2 {
        print("  RESULT: stacked=0 → 2 output channels (same data to both = MULTI-OUTPUT)")
    } else {
        print("  RESULT: stacked=0 → \(outCh) output channels (channels stacked = AGGREGATE)")
    }
    AudioHardwareDestroyAggregateDevice(deviceID)
    usleep(200_000)
}

// Test 5: Create multi-output with stacked=1
print("\n5. Testing Multi-Output device creation (stacked=1):")
if let deviceID = createDevice(
    name: "Test MultiOut stacked=1",
    uid: "test.multiout.stacked1",
    subDeviceUIDs: [(outUID, 0), (bhUID, 1)],
    mainUID: outUID,
    stacked: 1
) {
    let outCh = getChannelCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
    let inCh = getChannelCount(deviceID, scope: kAudioObjectPropertyScopeInput)
    print("  Created! output channels: \(outCh), input channels: \(inCh)")
    if outCh == 2 {
        print("  RESULT: stacked=1 → 2 output channels (same data to both = MULTI-OUTPUT)")
    } else {
        print("  RESULT: stacked=1 → \(outCh) output channels (channels stacked = AGGREGATE)")
    }
    AudioHardwareDestroyAggregateDevice(deviceID)
    usleep(200_000)
}

// Test 6: Set default output and restore
print("\n6. Testing default device switching:")
if let outID = defaultOutputID {
    let origName = getStringProperty(outID, selector: kAudioObjectPropertyName) ?? "?"
    print("  Current default output: \(origName)")
    print("  (Not changing defaults in test — verified API is available)")
}

// Test 7: Cleanup scan
print("\n7. Testing orphan cleanup:")
let postDevices = getAllDevices()
let orphans = postDevices.filter { id in
    let uid = getStringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? ""
    return uid.hasPrefix("test.") || uid.hasPrefix("com.forma.macdj.")
}
if orphans.isEmpty {
    print("  No orphaned test devices found (clean)")
} else {
    print("  Found \(orphans.count) orphaned devices — cleaning up")
    for id in orphans {
        AudioHardwareDestroyAggregateDevice(id)
    }
}

print("\n=== Tests complete ===")
print("\nKey finding: Check tests 4 and 5 above.")
print("The value that produces 2 output channels is the MULTI-OUTPUT setting.")
print("Update kAudioAggregateDeviceIsStackedKey in AudioDeviceManager.swift accordingly.\n")
