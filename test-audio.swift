#!/usr/bin/env swift
// Mic Relay audio probe.
//
// Usage:
//   swift test-audio.swift
//   swift test-audio.swift --tone-to-blackhole
//
// The tone mode writes a short generated tone to BlackHole 2ch. Select
// BlackHole 2ch as the microphone in a call app or recording app to verify
// that the virtual mic sink is receiving audio.

import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

let blackHoleUID = "BlackHole2ch_UID"

struct Device {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
}

func getStringProperty(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
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

func getChannelCount(_ deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
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

    return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) {
        $0 + Int($1.mNumberChannels)
    }
}

func allDevices() -> [Device] {
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

    return ids.compactMap { id in
        guard let uid = getStringProperty(id, selector: kAudioDevicePropertyDeviceUID),
              let name = getStringProperty(id, selector: kAudioObjectPropertyName)
        else { return nil }
        return Device(
            id: id,
            uid: uid,
            name: name,
            inputChannels: getChannelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: getChannelCount(id, scope: kAudioObjectPropertyScopeOutput)
        )
    }
}

func writeTone(to deviceID: AudioDeviceID) throws {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!
    final class PhaseBox: @unchecked Sendable {
        var phase = 0.0
    }
    let phaseBox = PhaseBox()

    let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let increment = 2.0 * Double.pi * 440.0 / 48_000.0
        for frame in 0..<Int(frameCount) {
            let sample = Float(sin(phaseBox.phase) * 0.18)
            phaseBox.phase += increment
            if phaseBox.phase > 2.0 * Double.pi {
                phaseBox.phase -= 2.0 * Double.pi
            }
            for bufferIndex in 0..<buffers.count {
                guard let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else { continue }
                data[frame] = sample
            }
        }
        return noErr
    }

    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: format)

    var mutableDeviceID = deviceID
    let status = AudioUnitSetProperty(
        engine.outputNode.audioUnit!,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &mutableDeviceID,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    try engine.start()
    print("Writing 440 Hz tone to BlackHole 2ch for 5 seconds...")
    Thread.sleep(forTimeInterval: 5)
    engine.stop()
}

let devices = allDevices()
print("=== Mic Relay Audio Probe ===")
for device in devices {
    print("[\(device.id)] \(device.name)")
    print("    uid: \(device.uid)")
    print("    input: \(device.inputChannels)ch, output: \(device.outputChannels)ch")
}

guard let blackHole = devices.first(where: { $0.uid == blackHoleUID }) else {
    print("\nBlackHole 2ch: NOT FOUND")
    print("Install with: brew install blackhole-2ch")
    exit(0)
}

print("\nBlackHole 2ch: FOUND")
print("    id: \(blackHole.id)")
print("    input: \(blackHole.inputChannels)ch, output: \(blackHole.outputChannels)ch")

if CommandLine.arguments.contains("--tone-to-blackhole") {
    do {
        try writeTone(to: blackHole.id)
        print("Tone test complete.")
    } catch {
        print("Tone test failed: \(error.localizedDescription)")
        exit(1)
    }
}
