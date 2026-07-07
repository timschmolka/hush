// SPDX-License-Identifier: MIT
//
// Hush — a minimal virtual audio INPUT device for macOS, written in Swift.
//
// Why this exists: when AirPods (or any Bluetooth headset) are selected as the
// system microphone, macOS switches them from the high-quality A2DP codec to the
// low-quality mono SCO/HFP "phone call" codec, wrecking playback quality. The usual
// fix is to point the input at some *other* real mic — but a Mac Studio has no
// built-in mic. Hush adds a fake, always-silent input device you can select
// instead, so the AirPods stay in full-quality output mode.
//
// It is a CoreAudio Audio Server Plug-In (a userspace HAL driver — no kernel
// extension). It publishes one device with a single input stream (48 kHz, stereo,
// Float32) that always reads silence.
//
// Implementation notes:
//   * AudioServerPlugInDriverInterface is a C "COM" vtable. We build it from
//     non-capturing closures, which Swift bridges to `@convention(c)` function
//     pointers. All driver state therefore lives in globals.
//   * The realtime IO callbacks (DoIOOperation / GetZeroTimeStamp) touch only C
//     primitives and a lock held via a heap pointer — no ARC, no allocation.

import CoreAudio
import CoreAudio.AudioServerPlugIn
import Darwin
import Foundation
import os

// MARK: - Configuration

private let kDeviceName    = "Hush"
private let kDeviceUID     = "HushInput_UID"
private let kModelUID      = "HushInput_Model"
private let kManufacturer  = "Hush"
private let kSampleRate: Float64 = 48_000
private let kChannels: UInt32    = 2
private let kBytesPerFrame: UInt32 = kChannels * UInt32(MemoryLayout<Float32>.size)
private let kRingBufferSize: UInt32 = 19_200   // zero-timestamp period, in frames

private enum Obj {
    static let plugIn:      AudioObjectID = AudioObjectID(kAudioObjectPlugInObject) // == 1
    static let device:      AudioObjectID = 2
    static let streamInput: AudioObjectID = 3
}

private let gLog = Logger(subsystem: "com.timschmolka.hush", category: "driver")

// These live in AudioServerPlugIn.h / CFPlugInCOM.h as C macros that Swift can't
// import, so we recreate them here.
private let kIOOpReadInput: UInt32 = 0x7265_6164 // 'read'

private func makeUUID(_ s: String) -> CFUUID { CFUUIDCreateFromString(kCFAllocatorDefault, s as CFString) }
private let gTypeUUID        = makeUUID("443ABAB8-E7B3-491A-B985-BEB9187030DB") // kAudioServerPlugInTypeUUID
private let gDriverIfaceUUID = makeUUID("EEA5773D-CC43-49F1-8E00-8F96E7D23B17") // kAudioServerPlugInDriverInterfaceUUID
private let gIUnknownUUID    = makeUUID("00000000-0000-0000-C000-000000000046") // IUnknownUUID

// MARK: - Global State

// A lock kept behind a heap pointer so the realtime path never takes `&global`
// (which would trip Swift's exclusivity checks under contention).
private let gLock: UnsafeMutablePointer<os_unfair_lock> = {
    let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    p.initialize(to: os_unfair_lock())
    return p
}()
@inline(__always) private func lock()   { os_unfair_lock_lock(gLock) }
@inline(__always) private func unlock() { os_unfair_lock_unlock(gLock) }

private var gRefCount: UInt32 = 0
nonisolated(unsafe) private var gHost: AudioServerPlugInHostRef?

private var gIOCount: UInt64 = 0
private var gHostTicksPerFrame: Float64 = 0
private var gNumberTimeStamps: UInt64 = 0
private var gAnchorHostTime: UInt64 = 0

// MARK: - Format helpers

private func mockFormat() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: kSampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        mBytesPerPacket: kBytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: kBytesPerFrame,
        mChannelsPerFrame: kChannels,
        mBitsPerChannel: 32,
        mReserved: 0)
}

@inline(__always)
private func write<T>(_ value: T, _ outData: UnsafeMutableRawPointer?, _ outSize: UnsafeMutablePointer<UInt32>?) {
    outData?.storeBytes(of: value, as: T.self)
    outSize?.pointee = UInt32(MemoryLayout<T>.size)
}

@inline(__always)
private func writeString(_ s: String, _ outData: UnsafeMutableRawPointer?, _ outSize: UnsafeMutablePointer<UInt32>?) {
    let ref = Unmanaged.passRetained(s as CFString).toOpaque()
    outData?.storeBytes(of: ref, as: UnsafeMutableRawPointer.self)
    outSize?.pointee = UInt32(MemoryLayout<UnsafeMutableRawPointer>.size)
}

// MARK: - Interface vtable

private let gInterface: UnsafeMutablePointer<AudioServerPlugInDriverInterface> = {
    let p = UnsafeMutablePointer<AudioServerPlugInDriverInterface>.allocate(capacity: 1)
    p.initialize(to: makeInterface())
    return p
}()

private let gDriverRef: UnsafeMutablePointer<UnsafeMutablePointer<AudioServerPlugInDriverInterface>?> = {
    let pp = UnsafeMutablePointer<UnsafeMutablePointer<AudioServerPlugInDriverInterface>?>.allocate(capacity: 1)
    pp.initialize(to: gInterface)
    return pp
}()

private func makeInterface() -> AudioServerPlugInDriverInterface {
    AudioServerPlugInDriverInterface(
        _reserved: nil,
        QueryInterface: { (driver, uuid, outInterface) in HushQueryInterface(driver, uuid, outInterface) },
        AddRef:  { _ in lock(); if gRefCount < UInt32.max { gRefCount += 1 }; let r = gRefCount; unlock(); return r },
        Release: { _ in lock(); if gRefCount > 0 { gRefCount -= 1 }; let r = gRefCount; unlock(); return r },
        Initialize: { (_, host) in
            gHost = host
            gLog.info("Hush initialized (device \"\(kDeviceName, privacy: .public)\", \(kSampleRate) Hz, \(kChannels) ch)")
            return noErr
        },
        CreateDevice: { _, _, _, _ in kAudioHardwareUnsupportedOperationError },
        DestroyDevice: { _, _ in kAudioHardwareUnsupportedOperationError },
        AddDeviceClient: { _, _, _ in noErr },
        RemoveDeviceClient: { _, _, _ in noErr },
        PerformDeviceConfigurationChange: { _, _, _, _ in noErr },
        AbortDeviceConfigurationChange: { _, _, _, _ in noErr },
        HasProperty: { (_, obj, _, addr) in DarwinBoolean(HushHasProperty(obj, addr)) },
        IsPropertySettable: { (_, obj, _, addr, outSettable) in HushIsSettable(obj, addr, outSettable) },
        GetPropertyDataSize: { (_, obj, _, addr, _, _, outSize) in HushGetPropertyDataSize(obj, addr, outSize) },
        GetPropertyData: { (_, obj, _, addr, _, qd, inSize, outSize, outData) in
            HushGetPropertyData(obj, addr, qd, inSize, outSize, outData)
        },
        SetPropertyData: { (_, obj, _, addr, _, _, inSize, inData) in
            HushSetPropertyData(obj, addr, inSize, inData)
        },
        StartIO: { (_, device, _) in HushStartIO(device) },
        StopIO:  { (_, device, _) in HushStopIO(device) },
        GetZeroTimeStamp: { (_, device, _, outSampleTime, outHostTime, outSeed) in
            HushGetZeroTimeStamp(device, outSampleTime, outHostTime, outSeed)
        },
        WillDoIOOperation: { (_, _, _, opID, outWillDo, outWillDoInPlace) in
            let willDo = (opID == kIOOpReadInput)
            outWillDo.pointee = DarwinBoolean(willDo)
            outWillDoInPlace.pointee = DarwinBoolean(true)
            return noErr
        },
        BeginIOOperation: { _, _, _, _, _, _ in noErr },
        DoIOOperation: { (_, _, _, _, opID, frameSize, _, ioMainBuffer, _) in
            if opID == kIOOpReadInput, let buf = ioMainBuffer {
                memset(buf, 0, Int(frameSize) * Int(kBytesPerFrame))
            }
            return noErr
        },
        EndIOOperation: { _, _, _, _, _, _ in noErr })
}

// MARK: - Factory (entry point named in Info.plist)

@_cdecl("HushCreate")
public func HushCreate(_ allocator: CFAllocator?, _ requestedTypeUUID: CFUUID?) -> UnsafeMutableRawPointer? {
    guard let requested = requestedTypeUUID,
          CFEqual(requested, gTypeUUID) else { return nil }
    return UnsafeMutableRawPointer(gDriverRef)
}

// MARK: - COM

private func HushQueryInterface(_ driver: UnsafeMutableRawPointer?,
                                _ uuid: CFUUIDBytes,
                                _ outInterface: UnsafeMutablePointer<LPVOID?>?) -> HRESULT {
    guard driver == UnsafeMutableRawPointer(gDriverRef), let outInterface else {
        return HRESULT(kAudioHardwareBadObjectError)
    }
    let requested = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, uuid)
    if CFEqual(requested, gDriverIfaceUUID) || CFEqual(requested, gIUnknownUUID) {
        lock(); if gRefCount < UInt32.max { gRefCount += 1 }; unlock()
        outInterface.pointee = UnsafeMutableRawPointer(gDriverRef)
        return HRESULT(0) // S_OK
    }
    return HRESULT(bitPattern: 0x8000_0004) // E_NOINTERFACE
}

// MARK: - Property access

private func HushHasProperty(_ obj: AudioObjectID, _ addr: UnsafePointer<AudioObjectPropertyAddress>?) -> Bool {
    var size: UInt32 = 0
    return HushGetPropertyDataSize(obj, addr, &size) == noErr
}

private func HushIsSettable(_ obj: AudioObjectID,
                            _ addr: UnsafePointer<AudioObjectPropertyAddress>?,
                            _ outSettable: UnsafeMutablePointer<DarwinBoolean>?) -> OSStatus {
    guard let sel = addr?.pointee.mSelector else { return kAudioHardwareBadObjectError }
    switch sel {
    case kAudioDevicePropertyNominalSampleRate,
         kAudioStreamPropertyVirtualFormat,
         kAudioStreamPropertyPhysicalFormat,
         kAudioStreamPropertyIsActive:
        outSettable?.pointee = true
    default:
        outSettable?.pointee = false
    }
    return noErr
}

private func HushGetPropertyDataSize(_ obj: AudioObjectID,
                                     _ addr: UnsafePointer<AudioObjectPropertyAddress>?,
                                     _ outSize: UnsafeMutablePointer<UInt32>?) -> OSStatus {
    guard let a = addr?.pointee else { return kAudioHardwareBadObjectError }
    let sel = a.mSelector
    let ptr = UInt32(MemoryLayout<UnsafeMutableRawPointer>.size)

    func set(_ v: UInt32) -> OSStatus { outSize?.pointee = v; return noErr }

    switch obj {
    case Obj.plugIn:
        switch sel {
        case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass: return set(UInt32(MemoryLayout<AudioClassID>.size))
        case kAudioObjectPropertyOwner, kAudioObjectPropertyOwnedObjects,
             kAudioPlugInPropertyDeviceList, kAudioPlugInPropertyTranslateUIDToDevice:
            return set(UInt32(MemoryLayout<AudioObjectID>.size))
        case kAudioObjectPropertyManufacturer, kAudioPlugInPropertyResourceBundle: return set(ptr)
        default: break
        }
    case Obj.device:
        switch sel {
        case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass: return set(UInt32(MemoryLayout<AudioClassID>.size))
        case kAudioObjectPropertyOwner, kAudioObjectPropertyOwnedObjects,
             kAudioDevicePropertyStreams, kAudioDevicePropertyRelatedDevices:
            if sel == kAudioDevicePropertyStreams || sel == kAudioObjectPropertyOwnedObjects,
               a.mScope == kAudioObjectPropertyScopeOutput { return set(0) }
            return set(UInt32(MemoryLayout<AudioObjectID>.size))
        case kAudioObjectPropertyName, kAudioObjectPropertyManufacturer,
             kAudioDevicePropertyDeviceUID, kAudioDevicePropertyModelUID: return set(ptr)
        case kAudioDevicePropertyTransportType, kAudioDevicePropertyClockDomain,
             kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceIsRunning,
             kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
             kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset,
             kAudioDevicePropertyIsHidden, kAudioDevicePropertyZeroTimeStampPeriod:
            return set(UInt32(MemoryLayout<UInt32>.size))
        case kAudioObjectPropertyControlList: return set(0)
        case kAudioDevicePropertyNominalSampleRate: return set(UInt32(MemoryLayout<Float64>.size))
        case kAudioDevicePropertyAvailableNominalSampleRates: return set(UInt32(MemoryLayout<AudioValueRange>.size))
        case kAudioDevicePropertyPreferredChannelsForStereo: return set(UInt32(2 * MemoryLayout<UInt32>.size))
        case kAudioDevicePropertyPreferredChannelLayout: return set(UInt32(MemoryLayout<AudioChannelLayout>.size))
        default: break
        }
    case Obj.streamInput:
        switch sel {
        case kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass: return set(UInt32(MemoryLayout<AudioClassID>.size))
        case kAudioObjectPropertyOwner: return set(UInt32(MemoryLayout<AudioObjectID>.size))
        case kAudioObjectPropertyOwnedObjects: return set(0)
        case kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection,
             kAudioStreamPropertyTerminalType, kAudioStreamPropertyStartingChannel,
             kAudioStreamPropertyLatency:
            return set(UInt32(MemoryLayout<UInt32>.size))
        case kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat:
            return set(UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        case kAudioStreamPropertyAvailableVirtualFormats, kAudioStreamPropertyAvailablePhysicalFormats:
            return set(UInt32(MemoryLayout<AudioStreamRangedDescription>.size))
        default: break
        }
    default: break
    }
    return kAudioHardwareUnknownPropertyError
}

private func HushGetPropertyData(_ obj: AudioObjectID,
                                 _ addr: UnsafePointer<AudioObjectPropertyAddress>?,
                                 _ qualData: UnsafeRawPointer?,
                                 _ inDataSize: UInt32,
                                 _ outSize: UnsafeMutablePointer<UInt32>?,
                                 _ outData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let a = addr?.pointee else { return kAudioHardwareBadObjectError }
    let sel = a.mSelector

    switch obj {
    case Obj.plugIn:
        switch sel {
        case kAudioObjectPropertyBaseClass: write(AudioClassID(kAudioObjectClassID), outData, outSize); return noErr
        case kAudioObjectPropertyClass: write(AudioClassID(kAudioPlugInClassID), outData, outSize); return noErr
        case kAudioObjectPropertyOwner: write(AudioObjectID(kAudioObjectUnknown), outData, outSize); return noErr
        case kAudioObjectPropertyManufacturer: writeString(kManufacturer, outData, outSize); return noErr
        case kAudioObjectPropertyOwnedObjects, kAudioPlugInPropertyDeviceList:
            if inDataSize >= UInt32(MemoryLayout<AudioObjectID>.size) { write(Obj.device, outData, outSize) }
            else { outSize?.pointee = 0 }
            return noErr
        case kAudioPlugInPropertyTranslateUIDToDevice:
            let uid = qualData?.load(as: CFString.self)
            let match = (uid != nil) && CFEqual(uid!, kDeviceUID as CFString)
            write(match ? Obj.device : AudioObjectID(kAudioObjectUnknown), outData, outSize)
            return noErr
        case kAudioPlugInPropertyResourceBundle: writeString("", outData, outSize); return noErr
        default: break
        }
    case Obj.device:
        switch sel {
        case kAudioObjectPropertyBaseClass: write(AudioClassID(kAudioObjectClassID), outData, outSize); return noErr
        case kAudioObjectPropertyClass: write(AudioClassID(kAudioDeviceClassID), outData, outSize); return noErr
        case kAudioObjectPropertyOwner: write(Obj.plugIn, outData, outSize); return noErr
        case kAudioObjectPropertyName: writeString(kDeviceName, outData, outSize); return noErr
        case kAudioObjectPropertyManufacturer: writeString(kManufacturer, outData, outSize); return noErr
        case kAudioObjectPropertyOwnedObjects, kAudioDevicePropertyStreams:
            if a.mScope == kAudioObjectPropertyScopeOutput { outSize?.pointee = 0; return noErr }
            if inDataSize >= UInt32(MemoryLayout<AudioObjectID>.size) { write(Obj.streamInput, outData, outSize) }
            else { outSize?.pointee = 0 }
            return noErr
        case kAudioDevicePropertyDeviceUID: writeString(kDeviceUID, outData, outSize); return noErr
        case kAudioDevicePropertyModelUID: writeString(kModelUID, outData, outSize); return noErr
        case kAudioDevicePropertyTransportType: write(UInt32(kAudioDeviceTransportTypeVirtual), outData, outSize); return noErr
        case kAudioDevicePropertyRelatedDevices: write(Obj.device, outData, outSize); return noErr
        case kAudioDevicePropertyClockDomain: write(UInt32(0), outData, outSize); return noErr
        case kAudioDevicePropertyDeviceIsAlive: write(UInt32(1), outData, outSize); return noErr
        case kAudioDevicePropertyDeviceIsRunning:
            lock(); let running: UInt32 = gIOCount > 0 ? 1 : 0; unlock()
            write(running, outData, outSize); return noErr
        case kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            write(UInt32(1), outData, outSize); return noErr
        case kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyIsHidden:
            write(UInt32(0), outData, outSize); return noErr
        case kAudioObjectPropertyControlList: outSize?.pointee = 0; return noErr
        case kAudioDevicePropertyNominalSampleRate: write(kSampleRate, outData, outSize); return noErr
        case kAudioDevicePropertyAvailableNominalSampleRates:
            write(AudioValueRange(mMinimum: kSampleRate, mMaximum: kSampleRate), outData, outSize); return noErr
        case kAudioDevicePropertyPreferredChannelsForStereo:
            outData?.storeBytes(of: UInt32(1), toByteOffset: 0, as: UInt32.self)
            outData?.storeBytes(of: UInt32(2), toByteOffset: MemoryLayout<UInt32>.size, as: UInt32.self)
            outSize?.pointee = UInt32(2 * MemoryLayout<UInt32>.size); return noErr
        case kAudioDevicePropertyPreferredChannelLayout:
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            write(layout, outData, outSize); return noErr
        case kAudioDevicePropertyZeroTimeStampPeriod: write(kRingBufferSize, outData, outSize); return noErr
        default: break
        }
    case Obj.streamInput:
        switch sel {
        case kAudioObjectPropertyBaseClass: write(AudioClassID(kAudioObjectClassID), outData, outSize); return noErr
        case kAudioObjectPropertyClass: write(AudioClassID(kAudioStreamClassID), outData, outSize); return noErr
        case kAudioObjectPropertyOwner: write(Obj.device, outData, outSize); return noErr
        case kAudioObjectPropertyOwnedObjects: outSize?.pointee = 0; return noErr
        case kAudioStreamPropertyIsActive: write(UInt32(1), outData, outSize); return noErr
        case kAudioStreamPropertyDirection: write(UInt32(1), outData, outSize); return noErr // 1 = input
        case kAudioStreamPropertyTerminalType: write(UInt32(kAudioStreamTerminalTypeMicrophone), outData, outSize); return noErr
        case kAudioStreamPropertyStartingChannel: write(UInt32(1), outData, outSize); return noErr
        case kAudioStreamPropertyLatency: write(UInt32(0), outData, outSize); return noErr
        case kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat:
            write(mockFormat(), outData, outSize); return noErr
        case kAudioStreamPropertyAvailableVirtualFormats, kAudioStreamPropertyAvailablePhysicalFormats:
            let ranged = AudioStreamRangedDescription(
                mFormat: mockFormat(),
                mSampleRateRange: AudioValueRange(mMinimum: kSampleRate, mMaximum: kSampleRate))
            write(ranged, outData, outSize); return noErr
        default: break
        }
    default: break
    }
    return kAudioHardwareUnknownPropertyError
}

private func HushSetPropertyData(_ obj: AudioObjectID,
                                 _ addr: UnsafePointer<AudioObjectPropertyAddress>?,
                                 _ inDataSize: UInt32,
                                 _ inData: UnsafeRawPointer?) -> OSStatus {
    guard let sel = addr?.pointee.mSelector else { return kAudioHardwareBadObjectError }
    switch sel {
    case kAudioDevicePropertyNominalSampleRate:
        let rate = inData?.load(as: Float64.self) ?? 0
        return rate == kSampleRate ? noErr : kAudioHardwareIllegalOperationError
    case kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat:
        guard let f = inData?.load(as: AudioStreamBasicDescription.self) else { return kAudioHardwareIllegalOperationError }
        return (f.mSampleRate == kSampleRate && f.mChannelsPerFrame == kChannels) ? noErr : kAudioHardwareIllegalOperationError
    case kAudioStreamPropertyIsActive:
        return noErr
    default:
        return kAudioHardwareUnknownPropertyError
    }
}

// MARK: - IO

private func HushStartIO(_ device: AudioObjectID) -> OSStatus {
    guard device == Obj.device else { return kAudioHardwareBadObjectError }
    lock()
    if gIOCount == 0 {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let hostClockFrequency = (Float64(tb.denom) / Float64(tb.numer)) * 1.0e9
        gHostTicksPerFrame = hostClockFrequency / kSampleRate
        gNumberTimeStamps = 0
        gAnchorHostTime = mach_absolute_time()
    }
    gIOCount += 1
    unlock()
    return noErr
}

private func HushStopIO(_ device: AudioObjectID) -> OSStatus {
    guard device == Obj.device else { return kAudioHardwareBadObjectError }
    lock(); if gIOCount > 0 { gIOCount -= 1 }; unlock()
    return noErr
}

private func HushGetZeroTimeStamp(_ device: AudioObjectID,
                                  _ outSampleTime: UnsafeMutablePointer<Float64>?,
                                  _ outHostTime: UnsafeMutablePointer<UInt64>?,
                                  _ outSeed: UnsafeMutablePointer<UInt64>?) -> OSStatus {
    guard device == Obj.device else { return kAudioHardwareBadObjectError }
    lock()
    let currentHostTime = mach_absolute_time()
    let hostTicksPerRingBuffer = gHostTicksPerFrame * Float64(kRingBufferSize)
    let nextTicks = Float64(gNumberTimeStamps + 1) * hostTicksPerRingBuffer
    let nextHostTime = gAnchorHostTime + UInt64(nextTicks)
    if currentHostTime >= nextHostTime { gNumberTimeStamps += 1 }
    outSampleTime?.pointee = Float64(gNumberTimeStamps * UInt64(kRingBufferSize))
    outHostTime?.pointee = gAnchorHostTime + UInt64(Float64(gNumberTimeStamps) * hostTicksPerRingBuffer)
    outSeed?.pointee = 1
    unlock()
    return noErr
}
