/*
 * sl4panel.m — Rane SL 4 Hardware Control Panel CLI
 *
 * Works seamlessly even while CoreAudio (coreaudiod) / Serato is streaming
 * by routing commands through the SL4Device CoreAudio HAL PlugIn ('sl4h' / 'sl4s').
 */
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

#define kSL4PropHIDCommand  'sl4h'
#define kSL4PropStatus      'sl4s'

typedef struct {
    uint32_t connected;
    uint32_t streaming;
    uint32_t sample_rate;
    uint32_t version_maj;
    uint32_t version_min;
    uint8_t  serial[32];
    uint8_t  phono[4];
    uint8_t  thru[4];
    uint8_t  port_a;
    uint8_t  port_b;
    uint64_t cap_frames;
    uint64_t play_frames;
} SL4StatusPacket;

static AudioObjectID find_hal_device(void) {
    AudioObjectPropertyAddress a = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef uid = CFSTR("com.rane.sl4.hal.device");
    AudioObjectID devID = kAudioObjectUnknown;
    UInt32 sz = sizeof(devID);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &sz, &devID);
    return (st == noErr) ? devID : kAudioObjectUnknown;
}

static bool send_hidi(AudioObjectID dev, uint8_t st_byte, uint8_t note, uint8_t vel) {
    uint8_t req[64] = {0};
    req[0] = 0x41;
    uint32_t seq = 1;
    memcpy(req + 1, &seq, 4);
    req[5] = 0x03;
    req[6] = st_byte;
    req[7] = note;
    req[8] = vel;
    AudioObjectPropertyAddress a = { kSL4PropHIDCommand, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef inData = CFDataCreate(kCFAllocatorDefault, req, 64);
    OSStatus s = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(CFDataRef), &inData);
    CFRelease(inData);
    if (s == noErr) {
        CFDataRef outData = NULL;
        UInt32 sz = sizeof(CFDataRef);
        if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &outData) == noErr && outData) {
            CFRelease(outData);
            return true;
        }
    }
    return false;
}

static void print_status(AudioObjectID dev) {
    AudioObjectPropertyAddress a = { kSL4PropStatus, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) != noErr || !d) {
        printf("Error: Could not read SL 4 status from CoreAudio HAL.\n");
        return;
    }
    SL4StatusPacket s;
    memcpy(&s, CFDataGetBytePtr(d), sizeof(s));
    CFRelease(d);

    printf("==================================================\n");
    printf("  Rane SL 4 — Hardware & CoreAudio Status\n");
    printf("==================================================\n");
    printf("  USB Connected : %s\n", s.connected ? "YES" : "NO");
    printf("  Streaming I/O : %s\n", s.streaming ? "ACTIVE" : "IDLE");
    printf("  Sample Rate   : %u Hz\n", s.sample_rate);
    printf("  Firmware Ver  : %u.%02u\n", s.version_maj, s.version_min);
    printf("  Serial Number : %s\n", s.serial[0] ? (const char *)s.serial : "N/A");
    for (int i = 0; i < 4; i++) {
        printf("  Deck %d Input  : %s  |  Mode: %s\n", i + 1,
               s.phono[i] ? "PHONO" : "LINE ",
               s.thru[i]  ? "ANALOG THRU" : "USB AUDIO");
    }
    printf("  Captured Frms : %llu\n", s.cap_frames);
    printf("  Playback Frms : %llu\n", s.play_frames);
    printf("==================================================\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        AudioObjectID dev = find_hal_device();
        if (dev == kAudioObjectUnknown) {
            printf("Error: SL 4 CoreAudio HAL driver not loaded in coreaudiod.\n");
            return 1;
        }
        if (argc < 2 || strcmp(argv[1], "status") == 0) {
            print_status(dev);
            return 0;
        }
        if (strcmp(argv[1], "thru") == 0) {
            for (int i = 0; i < 4; i++) send_hidi(dev, 0x90, (uint8_t)(0x5C + i), 0x00);
            printf("Enabled Analog Feed-Thru on Decks 1-4.\n");
        } else if (strcmp(argv[1], "usb") == 0) {
            for (int i = 0; i < 4; i++) send_hidi(dev, 0x80, (uint8_t)(0x5C + i), 0x00);
            printf("Enabled USB Audio (Feed-Thru Off) on Decks 1-4.\n");
        } else if (strcmp(argv[1], "phono") == 0) {
            for (int i = 0; i < 4; i++) send_hidi(dev, 0x90, 0x61, (uint8_t)i);
            printf("Set Decks 1-4 to PHONO level.\n");
        } else if (strcmp(argv[1], "line") == 0) {
            for (int i = 0; i < 4; i++) send_hidi(dev, 0x80, 0x61, (uint8_t)i);
            printf("Set Decks 1-4 to LINE level.\n");
        } else if (strcmp(argv[1], "sr") == 0 && argc >= 3) {
            Float64 sr = atof(argv[2]);
            AudioObjectPropertyAddress a = {
                kAudioDevicePropertyNominalSampleRate,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(Float64), &sr);
            printf("Set Sample Rate to %.0f Hz.\n", sr);
        } else {
            printf("Usage: sl4panel [status | usb | thru | phono | line | sr 44100|48000]\n");
        }
    }
    return 0;
}
