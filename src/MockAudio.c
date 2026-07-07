// SPDX-License-Identifier: MIT
//
// MockInput — a minimal virtual audio INPUT device for macOS.
//
// Why this exists: when AirPods (or any Bluetooth headset) are selected as the
// system microphone, macOS switches them from the high-quality A2DP codec to the
// low-quality mono SCO/HFP "phone call" codec, wrecking playback quality. The usual
// fix is to point the input at some *other* real mic — but a Mac Studio has no
// built-in mic. This driver creates a fake, always-silent input device you can
// select instead, so the AirPods stay in full-quality output mode.
//
// It is a CoreAudio Audio Server Plug-In (HAL plug-in). It publishes exactly one
// device with one input stream (48 kHz, stereo, Float32) that always reads silence.

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

// Logging goes to the unified log. Inspect with:
//   log stream --predicate 'subsystem == "com.poc.mockinput"'
// Never call this from the realtime IO path (DoIOOperation / GetZeroTimeStamp).
#define kLogSubsystem "com.poc.mockinput"
static os_log_t MockAudio_Log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create(kLogSubsystem, "driver"); });
    return log;
}
#define MOCK_LOG(fmt, ...) os_log(MockAudio_Log(), "[MockInput] " fmt, ##__VA_ARGS__)

#pragma mark Configuration

#define kDeviceName          "Mock Input"
#define kDeviceUID           "MockInput_UID"
#define kModelUID            "MockInput_Model"
#define kManufacturer        "PoC Audio"
#define kSampleRate          48000.0
#define kChannelsPerFrame    2
#define kBytesPerFrame       (kChannelsPerFrame * (UInt32)sizeof(Float32))
#define kRingBufferSize      19200  // zero-timestamp period, in frames

enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject,  // == 1
    kObjectID_Device        = 2,
    kObjectID_Stream_Input  = 3
};

#pragma mark Global State

static pthread_mutex_t          gStateMutex        = PTHREAD_MUTEX_INITIALIZER;
static UInt32                   gPlugIn_RefCount   = 0;
static AudioServerPlugInHostRef gPlugIn_Host       = NULL;

static UInt64                   gDevice_IOCount        = 0;   // # of clients doing IO
static Float64                  gDevice_HostTicksPerFrame = 0.0;
static UInt64                   gDevice_NumberTimeStamps  = 0;
static UInt64                   gDevice_AnchorHostTime    = 0;

#pragma mark Helpers

static AudioStreamBasicDescription MockAudio_Format(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate       = kSampleRate;
    f.mFormatID         = kAudioFormatLinearPCM;
    f.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
                          kAudioFormatFlagIsPacked;
    f.mBytesPerPacket   = kBytesPerFrame;
    f.mFramesPerPacket  = 1;
    f.mBytesPerFrame    = kBytesPerFrame;
    f.mChannelsPerFrame = kChannelsPerFrame;
    f.mBitsPerChannel   = 32;
    return f;
}

#pragma mark COM Boilerplate

static HRESULT MockAudio_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG   MockAudio_AddRef(void* inDriver);
static ULONG   MockAudio_Release(void* inDriver);
static OSStatus MockAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus MockAudio_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus MockAudio_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus MockAudio_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus MockAudio_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus MockAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus MockAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean  MockAudio_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus MockAudio_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus MockAudio_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus MockAudio_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus MockAudio_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus MockAudio_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus MockAudio_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus MockAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus MockAudio_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus MockAudio_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus MockAudio_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus MockAudio_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    MockAudio_QueryInterface,
    MockAudio_AddRef,
    MockAudio_Release,
    MockAudio_Initialize,
    MockAudio_CreateDevice,
    MockAudio_DestroyDevice,
    MockAudio_AddDeviceClient,
    MockAudio_RemoveDeviceClient,
    MockAudio_PerformDeviceConfigurationChange,
    MockAudio_AbortDeviceConfigurationChange,
    MockAudio_HasProperty,
    MockAudio_IsPropertySettable,
    MockAudio_GetPropertyDataSize,
    MockAudio_GetPropertyData,
    MockAudio_SetPropertyData,
    MockAudio_StartIO,
    MockAudio_StopIO,
    MockAudio_GetZeroTimeStamp,
    MockAudio_WillDoIOOperation,
    MockAudio_BeginIOOperation,
    MockAudio_DoIOOperation,
    MockAudio_EndIOOperation
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef        gDriverRef    = &gInterfacePtr;

// Factory referenced from Info.plist.
void* MockAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* MockAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

static HRESULT MockAudio_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gPlugIn_RefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(req);
    return result;
}

static ULONG MockAudio_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gPlugIn_RefCount < UINT32_MAX) ++gPlugIn_RefCount;
    ULONG r = gPlugIn_RefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static ULONG MockAudio_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gPlugIn_RefCount > 0) --gPlugIn_RefCount;
    ULONG r = gPlugIn_RefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

#pragma mark Lifecycle

static OSStatus MockAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gPlugIn_Host = inHost;
    MOCK_LOG("initialized (device \"%s\", %.0f Hz, %d ch)", kDeviceName, kSampleRate, kChannelsPerFrame);
    return noErr;
}

static OSStatus MockAudio_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* out) {
    (void)d;(void)desc;(void)c;(void)out;
    return kAudioHardwareUnsupportedOperationError;  // static device only
}
static OSStatus MockAudio_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) {
    (void)d;(void)o;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus MockAudio_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo* c) {
    (void)d;(void)o;(void)c; return noErr;
}
static OSStatus MockAudio_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo* c) {
    (void)d;(void)o;(void)c; return noErr;
}
static OSStatus MockAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void* i) {
    (void)d;(void)o;(void)a;(void)i; return noErr;
}
static OSStatus MockAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void* i) {
    (void)d;(void)o;(void)a;(void)i; return noErr;
}

#pragma mark Property Access

static Boolean MockAudio_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a) {
    (void)inDriver;(void)inClientPID;
    UInt32 dummy = 0;
    return MockAudio_GetPropertyDataSize(inDriver, inObjectID, inClientPID, a, 0, NULL, &dummy) == noErr;
}

static OSStatus MockAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a, Boolean* outSettable) {
    (void)inDriver;(void)inClientPID;
    switch (a->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyIsActive:
            *outSettable = true;  break;
        default:
            *outSettable = false; break;
    }
    (void)inObjectID;
    return noErr;
}

static OSStatus MockAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a, UInt32 qds, const void* qd, UInt32* outSize) {
    (void)inDriver;(void)inClientPID;(void)qds;(void)qd;

    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass:   *outSize = sizeof(AudioClassID);   return noErr;
            case kAudioObjectPropertyClass:       *outSize = sizeof(AudioClassID);   return noErr;
            case kAudioObjectPropertyOwner:       *outSize = sizeof(AudioObjectID);  return noErr;
            case kAudioObjectPropertyManufacturer:*outSize = sizeof(CFStringRef);    return noErr;
            case kAudioObjectPropertyOwnedObjects:*outSize = sizeof(AudioObjectID);  return noErr;
            case kAudioPlugInPropertyDeviceList:  *outSize = sizeof(AudioObjectID);  return noErr;
            case kAudioPlugInPropertyTranslateUIDToDevice: *outSize = sizeof(AudioObjectID); return noErr;
            case kAudioPlugInPropertyResourceBundle:       *outSize = sizeof(CFStringRef);   return noErr;
        }
        break;
    case kObjectID_Device:
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass:   *outSize = sizeof(AudioClassID);  return noErr;
            case kAudioObjectPropertyClass:       *outSize = sizeof(AudioClassID);  return noErr;
            case kAudioObjectPropertyOwner:       *outSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyName:        *outSize = sizeof(CFStringRef);   return noErr;
            case kAudioObjectPropertyManufacturer:*outSize = sizeof(CFStringRef);   return noErr;
            case kAudioObjectPropertyOwnedObjects:*outSize = sizeof(AudioObjectID); return noErr;
            case kAudioDevicePropertyDeviceUID:   *outSize = sizeof(CFStringRef);   return noErr;
            case kAudioDevicePropertyModelUID:    *outSize = sizeof(CFStringRef);   return noErr;
            case kAudioDevicePropertyTransportType:*outSize = sizeof(UInt32);       return noErr;
            case kAudioDevicePropertyRelatedDevices:*outSize = sizeof(AudioObjectID); return noErr;
            case kAudioDevicePropertyClockDomain: *outSize = sizeof(UInt32);        return noErr;
            case kAudioDevicePropertyDeviceIsAlive:*outSize = sizeof(UInt32);       return noErr;
            case kAudioDevicePropertyDeviceIsRunning:*outSize = sizeof(UInt32);     return noErr;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:      *outSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:*outSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyLatency:     *outSize = sizeof(UInt32);        return noErr;
            case kAudioDevicePropertyStreams:     *outSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyControlList:  *outSize = 0;                    return noErr;
            case kAudioDevicePropertySafetyOffset:*outSize = sizeof(UInt32);        return noErr;
            case kAudioDevicePropertyNominalSampleRate:*outSize = sizeof(Float64);  return noErr;
            case kAudioDevicePropertyAvailableNominalSampleRates:*outSize = sizeof(AudioValueRange); return noErr;
            case kAudioDevicePropertyIsHidden:    *outSize = sizeof(UInt32);        return noErr;
            case kAudioDevicePropertyPreferredChannelsForStereo:*outSize = 2*sizeof(UInt32); return noErr;
            case kAudioDevicePropertyPreferredChannelLayout:*outSize = sizeof(AudioChannelLayout); return noErr;
            case kAudioDevicePropertyZeroTimeStampPeriod:*outSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyIcon:        *outSize = sizeof(CFURLRef);      return noErr;
        }
        break;
    case kObjectID_Stream_Input:
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass:   *outSize = sizeof(AudioClassID);  return noErr;
            case kAudioObjectPropertyClass:       *outSize = sizeof(AudioClassID);  return noErr;
            case kAudioObjectPropertyOwner:       *outSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyOwnedObjects:*outSize = 0;                     return noErr;
            case kAudioStreamPropertyIsActive:    *outSize = sizeof(UInt32);        return noErr;
            case kAudioStreamPropertyDirection:   *outSize = sizeof(UInt32);        return noErr;
            case kAudioStreamPropertyTerminalType:*outSize = sizeof(UInt32);        return noErr;
            case kAudioStreamPropertyStartingChannel:*outSize = sizeof(UInt32);     return noErr;
            case kAudioStreamPropertyLatency:     *outSize = sizeof(UInt32);        return noErr;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:*outSize = sizeof(AudioStreamBasicDescription); return noErr;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:*outSize = sizeof(AudioStreamRangedDescription); return noErr;
        }
        break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus MockAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a, UInt32 qds, const void* qd, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)inDriver;(void)inClientPID;(void)qds;

    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID*)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:     *(AudioClassID*)outData = kAudioPlugInClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:     *(AudioObjectID*)outData = kAudioObjectUnknown; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyManufacturer: *(CFStringRef*)outData = CFSTR(kManufacturer); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                if (inDataSize >= sizeof(AudioObjectID)) { *(AudioObjectID*)outData = kObjectID_Device; *outDataSize = sizeof(AudioObjectID); }
                else { *outDataSize = 0; }
                return noErr;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                CFStringRef uid = *(CFStringRef*)qd;
                *(AudioObjectID*)outData = CFEqual(uid, CFSTR(kDeviceUID)) ? kObjectID_Device : kAudioObjectUnknown;
                *outDataSize = sizeof(AudioObjectID); return noErr;
            }
            case kAudioPlugInPropertyResourceBundle: *(CFStringRef*)outData = CFSTR(""); *outDataSize = sizeof(CFStringRef); return noErr;
        }
        break;
    case kObjectID_Device:
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID*)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:     *(AudioClassID*)outData = kAudioDeviceClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:     *(AudioObjectID*)outData = kObjectID_PlugIn;   *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyName:        *(CFStringRef*)outData = CFSTR(kDeviceName);   *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyManufacturer:*(CFStringRef*)outData = CFSTR(kManufacturer); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams:
                if ((a->mScope == kAudioObjectPropertyScopeOutput)) { *outDataSize = 0; return noErr; }
                if (inDataSize >= sizeof(AudioObjectID)) { *(AudioObjectID*)outData = kObjectID_Stream_Input; *outDataSize = sizeof(AudioObjectID); }
                else { *outDataSize = 0; }
                return noErr;
            case kAudioDevicePropertyDeviceUID: *(CFStringRef*)outData = CFSTR(kDeviceUID); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyModelUID:  *(CFStringRef*)outData = CFSTR(kModelUID);  *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyTransportType: *(UInt32*)outData = kAudioDeviceTransportTypeVirtual; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyRelatedDevices: *(AudioObjectID*)outData = kObjectID_Device; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioDevicePropertyClockDomain: *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceIsAlive: *(UInt32*)outData = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceIsRunning: {
                pthread_mutex_lock(&gStateMutex);
                *(UInt32*)outData = (gDevice_IOCount > 0) ? 1 : 0;
                pthread_mutex_unlock(&gStateMutex);
                *outDataSize = sizeof(UInt32); return noErr;
            }
            case kAudioDevicePropertyDeviceCanBeDefaultDevice: *(UInt32*)outData = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *(UInt32*)outData = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyLatency:     *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioObjectPropertyControlList:  *outDataSize = 0; return noErr;
            case kAudioDevicePropertySafetyOffset:*(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyNominalSampleRate: *(Float64*)outData = kSampleRate; *outDataSize = sizeof(Float64); return noErr;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange r = { kSampleRate, kSampleRate };
                *(AudioValueRange*)outData = r; *outDataSize = sizeof(AudioValueRange); return noErr;
            }
            case kAudioDevicePropertyIsHidden: *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                UInt32* p = (UInt32*)outData; p[0] = 1; p[1] = 2; *outDataSize = 2*sizeof(UInt32); return noErr;
            }
            case kAudioDevicePropertyPreferredChannelLayout: {
                AudioChannelLayout* l = (AudioChannelLayout*)outData;
                memset(l, 0, sizeof(AudioChannelLayout));
                l->mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
                *outDataSize = sizeof(AudioChannelLayout); return noErr;
            }
            case kAudioDevicePropertyZeroTimeStampPeriod: *(UInt32*)outData = kRingBufferSize; *outDataSize = sizeof(UInt32); return noErr;
        }
        break;
    case kObjectID_Stream_Input:
        switch (a->mSelector) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID*)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:     *(AudioClassID*)outData = kAudioStreamClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:     *(AudioObjectID*)outData = kObjectID_Device;   *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return noErr;
            case kAudioStreamPropertyIsActive:  *(UInt32*)outData = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyDirection: *(UInt32*)outData = 1; *outDataSize = sizeof(UInt32); return noErr;  // 1 = input
            case kAudioStreamPropertyTerminalType: *(UInt32*)outData = kAudioStreamTerminalTypeMicrophone; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyStartingChannel: *(UInt32*)outData = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyLatency:   *(UInt32*)outData = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *(AudioStreamBasicDescription*)outData = MockAudio_Format(); *outDataSize = sizeof(AudioStreamBasicDescription); return noErr;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                AudioStreamRangedDescription* rd = (AudioStreamRangedDescription*)outData;
                rd->mFormat = MockAudio_Format();
                rd->mSampleRateRange.mMinimum = kSampleRate;
                rd->mSampleRateRange.mMaximum = kSampleRate;
                *outDataSize = sizeof(AudioStreamRangedDescription); return noErr;
            }
        }
        break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus MockAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a, UInt32 qds, const void* qd, UInt32 inDataSize, const void* inData) {
    (void)inDriver;(void)inObjectID;(void)inClientPID;(void)qds;(void)qd;(void)inDataSize;
    // The device is fixed-format; accept the one supported value, reject others.
    switch (a->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            return (*(const Float64*)inData == kSampleRate) ? noErr : kAudioHardwareIllegalOperationError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)inData;
            return (f->mSampleRate == kSampleRate && f->mChannelsPerFrame == kChannelsPerFrame) ? noErr : kAudioHardwareIllegalOperationError;
        }
        case kAudioStreamPropertyIsActive:
            return noErr;
    }
    return kAudioHardwareUnknownPropertyError;
}

#pragma mark IO

static OSStatus MockAudio_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (gDevice_IOCount == 0) {
        struct mach_timebase_info tb; mach_timebase_info(&tb);
        Float64 hostClockFrequency = ((Float64)tb.denom / (Float64)tb.numer) * 1.0e9;
        gDevice_HostTicksPerFrame = hostClockFrequency / kSampleRate;
        gDevice_NumberTimeStamps  = 0;
        gDevice_AnchorHostTime    = mach_absolute_time();
    }
    ++gDevice_IOCount;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus MockAudio_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gDevice_IOCount > 0) --gDevice_IOCount;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus MockAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    UInt64 currentHostTime = mach_absolute_time();
    Float64 hostTicksPerRingBuffer = gDevice_HostTicksPerFrame * (Float64)kRingBufferSize;
    Float64 nextTicks = (Float64)(gDevice_NumberTimeStamps + 1) * hostTicksPerRingBuffer;
    UInt64 nextHostTime = gDevice_AnchorHostTime + (UInt64)nextTicks;
    if (currentHostTime >= nextHostTime) {
        ++gDevice_NumberTimeStamps;
    }
    *outSampleTime = (Float64)(gDevice_NumberTimeStamps * kRingBufferSize);
    *outHostTime   = gDevice_AnchorHostTime + (UInt64)((Float64)gDevice_NumberTimeStamps * hostTicksPerRingBuffer);
    *outSeed       = 1;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus MockAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inDriver;(void)inDeviceObjectID;(void)inClientID;
    Boolean willDo = false, inPlace = true;
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput: willDo = true; break;
    }
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = inPlace;
    return noErr;
}

static OSStatus MockAudio_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 fc, const AudioServerPlugInIOCycleInfo* i) {
    (void)d;(void)o;(void)c;(void)op;(void)fc;(void)i; return noErr;
}

static OSStatus MockAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)inDriver;(void)inDeviceObjectID;(void)inStreamObjectID;(void)inClientID;(void)inIOCycleInfo;(void)ioSecondaryBuffer;
    // The mock input is always silent: zero-fill whatever the client is about to read.
    if (inOperationID == kAudioServerPlugInIOOperationReadInput && ioMainBuffer != NULL) {
        memset(ioMainBuffer, 0, (size_t)inIOBufferFrameSize * kBytesPerFrame);
    }
    return noErr;
}

static OSStatus MockAudio_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 fc, const AudioServerPlugInIOCycleInfo* i) {
    (void)d;(void)o;(void)c;(void)op;(void)fc;(void)i; return noErr;
}
