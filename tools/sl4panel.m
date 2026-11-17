// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * sl4panel.m — Rane SL 4 status and control from the command line
 *
 * Works while CoreAudio / Serato is streaming: everything goes through the SL4Device HAL plug-in
 * ('sl4s' status, 'sl4h' commands, 'sl4i' input safety offset), which holds the box.
 *
 *   sl4panel [status]           the box's and the driver's state
 *   sl4panel usb|thru [1-4]     each deck's (or one deck's) output: USB audio or analog thru
 *   sl4panel rate               the sample rate (chosen on the box; the computer cannot set it)
 *   sl4panel safety [ms]        the input safety offset setting
 *
 * The SL 4's LINE/PHONO switches are not reported to the computer, so they are not shown.
 */
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import "SL4Passthrough.h"
#include "SL4Status.h"   /* the driver's status packet ('sl4s') */

#ifndef SL4_VERSION
#define SL4_VERSION  "1.4.0"
#endif
#define kSL4PropStatus      'sl4s'
#define kSL4PropInSafety    'sl4i'

#define SL4_VENDOR_ID       0x1cc5
#define SL4_PRODUCT_ID      0x000f    /* the SL 4 */
#define SL4_PRODUCT_ID_ALT  0x0010    /* the same box after 0x1a (alternate product ID) */
#define SL4_BCD_BOOT        0x9900    /* bcdDevice of a box in its firmware updater */

#define SL4_DECKS           4
#define SL4_CMD_HIDI        0x41      /* [5] message length, [6..] MIDI bytes; reply 0x41 = queued, 0xFE = refused */
#define SL4_MIDI_NOTE_OFF   0x80      /* channel 1: a deck's thru off (USB audio) */
#define SL4_MIDI_NOTE_ON    0x90      /* channel 1: a deck's thru on (analog thru) */
#define SL4_NOTE_THRU_DECK1 0x5C      /* decks 1-4: notes 0x5C-0x5F */

/* ANSI colours for warnings, used only when stdout is a terminal. */
static const char *warn_on(void)  { return isatty(STDOUT_FILENO) ? "\033[31m" : ""; }
static const char *warn_off(void) { return isatty(STDOUT_FILENO) ? "\033[0m" : ""; }

/* An SL 4 in the USB registry, under either product ID. The driver only lists its device while a box
   is attached, so this tells "no box" from "driver not loaded". Sets *boot_mode if the box is in its
   firmware updater (bcdDevice 0x9900). */
static bool sl4_on_usb(bool *boot_mode) {
    const int pids[] = { SL4_PRODUCT_ID, SL4_PRODUCT_ID_ALT };
    for (size_t i = 0; i < sizeof pids / sizeof pids[0]; i++) {
        /* Match USB devices with the SL 4's vendor and product IDs. */
        CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
        if (!m) return false;
        int v = SL4_VENDOR_ID, p = pids[i];
        CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
        CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
        CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
        CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
        CFRelease(vn); CFRelease(pn);
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
        if (!svc) continue;
        /* Found: read its bcdDevice to tell the firmware updater from running firmware. */
        int bcd = 0;
        CFTypeRef r = IORegistryEntryCreateCFProperty(svc, CFSTR(kUSBDeviceReleaseNumber), NULL, 0);
        if (r) {
            if (CFGetTypeID(r) == CFNumberGetTypeID()) CFNumberGetValue(r, kCFNumberIntType, &bcd);
            CFRelease(r);
        }
        *boot_mode = bcd == SL4_BCD_BOOT;
        IOObjectRelease(svc);
        return true;
    }
    return false;
}

/* A deck number on the command line, 1-4, as an index 0-3; -1 if it isn't one. */
static int deck_index(const char *arg) {
    char *end = NULL;
    long n = strtol(arg, &end, 10);
    return (end && *end == 0 && n >= 1 && n <= SL4_DECKS) ? (int)n - 1 : -1;
}

/* Switch one deck's thru with a Hidi message (0x41): Note On of its note = analog thru, Note Off = USB
   audio, channel 1, velocity 0. True if the box queued it. */
static bool set_thru(AudioObjectID dev, int deck, bool thru) {
    uint8_t req[SL4_REPORT] = { SL4_CMD_HIDI }, reply[SL4_REPORT];
    req[5] = 3;
    req[6] = thru ? SL4_MIDI_NOTE_ON : SL4_MIDI_NOTE_OFF;
    req[7] = (uint8_t)(SL4_NOTE_THRU_DECK1 + deck);
    req[8] = 0;
    return sl4h_command(dev, req, reply);
}

/* The driver's status ('sl4s'); a shorter packet (an older driver) is zero-filled. */
static bool read_status(AudioObjectID dev, SL4StatusPacket *s) {
    AudioObjectPropertyAddress a = { kSL4PropStatus, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef d = NULL;
    UInt32 sz = sizeof(d);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &d) != noErr || !d) return false;
    memset(s, 0, sizeof *s);
    CFIndex n = CFDataGetLength(d);
    memcpy(s, CFDataGetBytePtr(d), (size_t)(n < (CFIndex)sizeof *s ? n : (CFIndex)sizeof *s));
    CFRelease(d);
    return true;
}

static const char *rate_name(uint32_t hz) {
    return hz == 48000 ? "48 kHz" : hz == 96000 ? "96 kHz" : "?";
}

static const char *port_name(uint8_t port) {
    return port == 1 ? "A" : port == 2 ? "B" : "?";
}

static void print_status(AudioObjectID dev) {
    /* Read the driver's status ('sl4s'). */
    SL4StatusPacket s;
    if (!read_status(dev, &s)) {
        printf("Error: Could not read SL 4 status from CoreAudio HAL.\n");
        return;
    }

    /* Print it; a box in its firmware updater has no other status to show. */
    printf("==================================================\n");
    printf("  Rane SL 4 — Hardware & CoreAudio Status\n");
    printf("==================================================\n");
    printf("  USB Connected : %s\n", s.connected ? "YES" : "NO");
    printf("  Driver Build  : %s\n", s.debug_build ? "DEBUG" : "release");
    if (s.boot_mode) {
        printf("  Firmware      : %sNOT RUNNING — the box is in its firmware updater%s\n", warn_on(), warn_off());
        printf("                  it passes no audio until its firmware is written again\n");
        printf("==================================================\n");
        return;
    }
    printf("  Streaming I/O : %s\n", s.streaming ? "ACTIVE" : "IDLE");
    printf("  Sample Rate   : %u Hz (the device's)\n", s.sample_rate);
    /* The box's own rate (0x4A), asked now; the driver's last-known one if the box doesn't answer. */
    uint32_t box_hz = 0;
    if (!(s.connected && sl4h_rate(dev, &box_hz))) box_hz = s.box_rate;
    if (box_hz) printf("  Box Rate      : %u Hz%s\n", box_hz, box_hz == s.sample_rate ? "" : " (the device is following it)");
    else        printf("  Box Rate      : not known\n");
    /* The firmware, flagged if it is older than the newest Rane released. */
    bool known = s.version_maj || s.version_min;
    bool old = known && (s.version_maj < SL4_FIRMWARE_CURRENT_MAJOR ||
                         (s.version_maj == SL4_FIRMWARE_CURRENT_MAJOR && s.version_min < SL4_FIRMWARE_CURRENT_MINOR));
    if (!known)   printf("  Firmware Ver  : not known\n");
    else if (old) printf("  Firmware Ver  : %s%u.%02u (older than %d.%02d, the current firmware)%s\n", warn_on(), s.version_maj, s.version_min,
                         SL4_FIRMWARE_CURRENT_MAJOR, SL4_FIRMWARE_CURRENT_MINOR, warn_off());
    else          printf("  Firmware Ver  : %u.%02u\n", s.version_maj, s.version_min);
    printf("  Serial Number : %s\n", s.serial[0] ? (const char *)s.serial : "N/A");
    printf("  USB Link      : %s%s%s\n", s.usb_link == 1 ? warn_on() : "",
           s.usb_link == 2 ? "high speed" : s.usb_link == 1 ? "FULL SPEED (no audio: use a USB 2.0 port)" : "not known",
           s.usb_link == 1 ? warn_off() : "");
    /* The box's two USB ports: which one this Mac is on, and whether a computer is on the other. */
    printf("  USB Port      : %s\n", port_name(s.port_a));
    printf("  Other Port    : %s%s\n", s.port_b ? "a computer is connected on " : "no computer",
           s.port_b ? port_name(s.port_b) : "");
    for (int k = 0; k < SL4_DECKS; k++)
        printf("  Deck %d        : %s\n", k + 1, s.thru[k] ? "ANALOG THRU" : "USB AUDIO");
    printf("  Note 0x60     : %s\n", s.note60 == 1 ? "on" : s.note60 == 0 ? "off" : "not known");
    printf("  Captured Frms : %llu\n", s.cap_frames);
    printf("  Playback Frms : %llu\n", s.play_frames);
    if (s.in_safety_us) {
        printf("  Input Safety  : %g ms\n", s.in_safety_us / 1000.0);
        printf("  Early Read    : %s\n", s.early_read == 1 ? "working" : s.early_read == 2 ? "NOT WORKING (use an input safety offset of 8 ms)" : "not judged yet");
        printf("  Input Dropouts: %llu\n", s.in_dropouts);
        printf("  USB Hubs      : %u%s\n", s.hub_depth, s.hub_depth ? "" : " (connected directly)");
    }
    printf("==================================================\n");
}

static int usage(void) {
    printf("Usage: sl4panel [status | usb [1-4] | thru [1-4] | rate | safety [ms]]\n");
    return 2;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 2 && (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-v") == 0)) {
            printf("sl4panel %s\n", SL4_VERSION);
            return 0;
        }
        /* Find the driver's device; without it, say whether a box is attached at all. */
        AudioObjectID dev = sl4h_find_device();
        if (dev == kAudioObjectUnknown) {
            bool boot_mode = false;
            if (!sl4_on_usb(&boot_mode))
                printf("No SL 4 connected.\n");
            else if (boot_mode)
                printf("The SL 4 is in its firmware updater: it passes no audio until its firmware is written again.\n");
            else
                printf("Error: an SL 4 is connected, but the SL 4 CoreAudio driver is not loaded in coreaudiod.\n");
            return 1;
        }
        /* No command, or "status": print the status. */
        if (argc < 2 || strcmp(argv[1], "status") == 0) {
            print_status(dev);
            return 0;
        }
        if (strcmp(argv[1], "usb") == 0 || strcmp(argv[1], "thru") == 0) {
            /* "usb" / "thru" [deck]: each deck's (or one deck's) thru, notes 0x5C-0x5F. */
            int only = argc >= 3 ? deck_index(argv[2]) : -1;
            if (argc >= 3 && only < 0) return usage();
            bool thru = strcmp(argv[1], "thru") == 0;
            for (int k = 0; k < SL4_DECKS; k++) {
                if (only >= 0 && k != only) continue;
                if (!set_thru(dev, k, thru)) { printf("Error: the box did not take the command.\n"); return 1; }
                printf("Deck %d: %s\n", k + 1, thru ? "analog thru" : "USB audio");
            }
        } else if (strcmp(argv[1], "rate") == 0 || strcmp(argv[1], "sr") == 0) {
            /* "rate": show it. The SL 4 chooses its rate itself; the driver follows it. */
            SL4StatusPacket s;
            uint32_t hz = 0;
            if (!sl4h_rate(dev, &hz) && read_status(dev, &s)) hz = s.box_rate;
            printf("Sample rate: %s. The rate is chosen on the SL 4 (48 or 96 kHz); the computer cannot set it.\n", rate_name(hz));
            if (argc >= 3) return 1;
        } else if (strcmp(argv[1], "safety") == 0) {
            /* "safety [ms]": the input safety offset setting. The driver takes it only with nothing
               streaming, and sets the device up again with it (about half a second). */
            AudioObjectPropertyAddress a = { kSL4PropInSafety, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            if (argc >= 3) {
                int us = (int)lround(atof(argv[2]) * 1000.0);
                CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &us);
                OSStatus e = AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof n, &n);
                CFRelease(n);
                if (e) {
                    printf("Refused (error %d): the setting must be 0.5 to 20 ms, with nothing streaming.\n", (int)e);
                    return 1;
                }
                printf("Input safety offset setting: %g ms.\n", us / 1000.0);
            } else {
                CFNumberRef n = NULL;
                UInt32 sz = sizeof n;
                int us = 0;
                if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &n) || !n) {
                    printf("This driver has no input safety offset setting.\n");
                    return 1;
                }
                CFNumberGetValue(n, kCFNumberIntType, &us);
                CFRelease(n);
                printf("Input safety offset setting: %g ms.\n", us / 1000.0);
            }
        } else {
            return usage();
        }
    }
    return 0;
}
