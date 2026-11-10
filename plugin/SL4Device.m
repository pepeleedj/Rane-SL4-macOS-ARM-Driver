/*
 * SL4Device.m — Complete Self-Contained CoreAudio HAL Driver for Rane SL 4
 *
 * Drives the Rane SL 4 USB 2.0 DJ audio interface directly from inside the
 * CoreAudio HAL plugin (coreaudiod) using Apple's modern IOUSBHost framework.
 * No external daemon, no kernel extension, no root helper required.
 *
 * Capabilities:
 *   - 10-channel 24-bit (32-bit container) / 48 & 44.1 kHz Isochronous USB Audio
 *   - Implicit-feedback packet pacing from Capture to Playback
 *   - Automatic USB Audio / Analog Thru switching on StartIO / StopIO (HID 0x41)
 *   - Full HID Command/Response + Unsolicited Report Queue ('sl4h', 'sl4s', 'sl4q')
 *     for Serato DJ Pro (SL4Api.framework) and Control Panel
 *   - Automatic USB Hotplug detection (plug / unplug at any time)
 */

#import <Foundation/Foundation.h>
#import <CoreAudio/AudioServerPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <os/log.h>
#include <stdatomic.h>

#define VID          0x1cc5
#define PID          0x000f
#define IF_PLAY      1
#define IF_CAP       2
#define IF_HID       3
#define EP_PLAY      0x06    /* IF1 alt1: isochronous OUT, asynchronous, bInterval 1 */
#define EP_CAP       0x82    /* IF2 alt1: isochronous IN, implicit feedback, bInterval 1 */
#define EP_HID_OUT   0x01
#define EP_HID_IN    0x81

#define NCH          10
#define FRAME_BYTES  40      /* 10 ch * 4 bytes (24-bit left-justified in 32-bit int) */
#define PKT_MAX      280     /* wMaxPacketSize of EP 0x06/0x82: 7 frames * 40 bytes per microframe */
#define PKT_BUF_MAX  720     /* max buffer stride per microframe */
#define HEARTBEAT_MS 100
#define IN_SAFETY_44  176    /* input safety offset in frames at 44.1 kHz (~4.0 ms) */
#define OUT_SAFETY_44 132    /* output safety offset in frames at 44.1 kHz (~3.0 ms, with late-write) */
#define LAT_IN_44     23     /* input latency in frames at 44.1 kHz (~0.5 ms) */
#define LAT_OUT_44    66     /* output latency in frames at 44.1 kHz (~1.5 ms) */
#define ZTS_PERIOD    16384  /* ZeroTimeStampPeriod (>= 10923 required by CoreAudio HAL) */
#define CAP_PKTS     8       /* 1 ms per transfer */
#define CAP_NXF      64
#define PLAY_PKTS    8       /* 1 ms per transfer */
#define PLAY_NXF     64      /* 64 ms deep-scheduled playback queue with late writes from WriteMix */
#define RING_FRAMES  65536   /* ~1.36s @ 48kHz */
#define RING_MASK    (RING_FRAMES - 1)
#define FIFO_N       2048

/* Custom CoreAudio Property Selectors */
#define kSL4PropHIDCommand  'sl4h'   /* CFDataRef (64B cmd in -> 64B reply out) */
#define kSL4PropStatus      'sl4s'   /* CFDataRef (SL4StatusPacket out) */
#define kSL4PropUnsolQueue  'sl4q'   /* CFDataRef (pop queued 64B unsolicited HID reports) */
#define kSL4PropMeters      'sl4m'   /* CFDataRef (20 Float32 peaks: 10 in + 10 out) */

typedef struct {
    uint32_t connected;
    uint32_t streaming;
    uint32_t sample_rate;
    uint32_t version_maj;
    uint32_t version_min;
    uint8_t  serial[32];
    uint8_t  phono[4];       /* 1 = Phono, 0 = Line */
    uint8_t  thru[4];        /* 1 = Analog Thru, 0 = USB Audio */
    uint8_t  port_a;
    uint8_t  port_b;
    uint64_t cap_frames;
    uint64_t play_frames;
} SL4StatusPacket;

enum {
    kObjPlugIn    = kAudioObjectPlugInObject,
    kObjDevice    = 2,
    kObjStreamIn  = 3,
    kObjStreamOut = 4,
    kObjVolume    = 5,   /* master output volume (element 0) */
    kObjMute      = 6,   /* master output mute   (element 0) */
    kObjVolCh1    = 7,   /* Deck 1 Out L (element 1) */
    kObjVolCh2    = 8,   /* Deck 1 Out R (element 2) */
    kObjVolCh3    = 9,   /* Deck 2 Out L (element 3) */
    kObjVolCh4    = 10,  /* Deck 2 Out R (element 4) */
    kObjVolCh5    = 11,  /* Deck 3 Out L (element 5) */
    kObjVolCh6    = 12,  /* Deck 3 Out R (element 6) */
    kObjVolCh7    = 13,  /* Deck 4 Out L (element 7) */
    kObjVolCh8    = 14,  /* Deck 4 Out R (element 8) */
    kObjVolCh9    = 15,  /* Aux Out L    (element 9) */
    kObjVolCh10   = 16,  /* Aux Out R    (element 10) */
};

static os_log_t g_log;
#define LOG(fmt, ...) os_log(g_log, "[SL4] " fmt, ##__VA_ARGS__)

static AudioServerPlugInHostRef g_host = NULL;
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_hid_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_hout_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_unsol_mtx = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_cap_pkt_max = PKT_MAX;
static uint32_t g_play_pkt_max = PKT_MAX;

static Float64  g_sr = 48000.0;
static UInt32   g_io_clients = 0;
static _Atomic bool g_io_running = false;
static _Atomic bool g_hw_connected = false;
static uint32_t g_ref_count = 0;

/* Ring buffers (Float32 interleaved, NCH channels) */
static float g_in_ring[RING_FRAMES * NCH];
static float g_out_ring[RING_FRAMES * NCH];

/* Clock state */
static mach_timebase_info_data_t g_tb;
static _Atomic uint64_t g_anchor_host = 0;
static _Atomic uint64_t g_total_cap_frames = 0;
static _Atomic uint64_t g_total_play_frames = 0;
static _Atomic double   g_ticks_per_frame = 0;

/* Implicit feedback packet-size FIFO */
static int g_fifo[FIFO_N];
static _Atomic uint32_t g_fifo_w = 0;
static _Atomic uint32_t g_fifo_r = 0;
static uint32_t g_faccum = 0;

/* IOUSBHost state */
static dispatch_queue_t    g_q;
static IOUSBHostDevice    *g_dev;
static IOUSBHostInterface *g_play, *g_cap, *g_hid;
static IOUSBHostPipe      *g_ppipe, *g_cpipe, *g_hpipe_in, *g_hpipe_out;

/* Isoch transfer pools */
typedef struct {
    NSMutableData *buf;
    IOUSBHostIsochronousTransaction *tx;
} IsoXfer;
static IsoXfer g_cap_xf[CAP_NXF];
static IsoXfer g_play_xf[PLAY_NXF];
static uint64_t g_cap_frame = 0;
static uint64_t g_play_frame = 0;
static _Atomic int g_play_inflight = 0;

/* Deep-Schedule Late-Write Playback Ring */
#define DP_RING 256
#define DP_MASK (DP_RING - 1)
typedef struct {
    _Atomic uint64_t seq;
    uint64_t frame;
    uint64_t s0;
    uint32_t total;
    uint16_t pkt_n[PLAY_PKTS];
    uint32_t pkt_off[PLAY_PKTS];
    uint8_t *buf;
} dp_slot_t;
static dp_slot_t g_dp_sched[DP_RING];
static _Atomic uint64_t g_dp_newest_s0 = 0;
static _Atomic uint64_t g_dp_newest_frame = 0;
static _Atomic int g_dp_active = 0;
static _Atomic int g_dp_writers = 0;

static inline void pack_32lj(uint8_t *q, const float *fr) {
    for (int c = 0; c < NCH; c++) {
        float v = fr[c] > 1.0f ? 1.0f : fr[c] < -1.0f ? -1.0f : fr[c];
        int32_t raw32 = (int32_t)(v * 2147483392.0f);
        memcpy(q + c * 4, &raw32, 4);
    }
}

static void dp_write_frame(uint64_t s, const float *fr) {
    uint64_t nf = atomic_load_explicit(&g_dp_newest_frame, memory_order_acquire);
    uint64_t ns0 = atomic_load_explicit(&g_dp_newest_s0, memory_order_relaxed);
    if (!nf) return;
    int64_t ds = (int64_t)s - (int64_t)ns0;
    int64_t df = ds / 44;
    uint64_t start_f = (int64_t)nf + df - 4 > 0 ? (uint64_t)((int64_t)nf + df - 4) : 1;
    for (int step = 0; step < 12; step++) {
        uint64_t f = start_f + (uint64_t)step;
        dp_slot_t *sl = &g_dp_sched[f & DP_MASK];
        uint64_t q1 = atomic_load_explicit(&sl->seq, memory_order_acquire);
        if ((q1 & 1) || sl->frame != f) continue;
        uint64_t s0 = sl->s0;
        uint32_t tot = sl->total;
        uint8_t *buf = sl->buf;
        if (s >= s0 && s < s0 + tot && buf) {
            uint32_t rem = (uint32_t)(s - s0);
            for (int k = 0; k < PLAY_PKTS; k++) {
                uint16_t pn = sl->pkt_n[k];
                if (rem < pn) {
                    uint8_t *q = buf + sl->pkt_off[k] + rem * FRAME_BYTES;
                    pack_32lj(q, fr);
                    break;
                }
                rem -= pn;
            }
            return;
        }
        if (s0 > s + 64) break;
    }
}

/* Output Volume / Mute (Master + 10 Channels) & Level Meters ('sl4m') */
#define VOL_MIN_DB (-64.0f)
#define VOL_MAX_DB   0.0f
static _Atomic float g_vol_scalar[11] = {
    1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f
};
static _Atomic float g_vol_applied[NCH] = {
    1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f
};
static _Atomic UInt32 g_vol_mute = 0;
static _Atomic float g_meter_peaks[NCH * 2];

static inline float vol_scalar_to_db(float s) {
    if (s <= 0.0f) return VOL_MIN_DB;
    if (s >= 1.0f) return VOL_MAX_DB;
    return VOL_MIN_DB + s * (VOL_MAX_DB - VOL_MIN_DB);
}
static inline float vol_db_to_scalar(float db) {
    if (db <= VOL_MIN_DB) return 0.0f;
    if (db >= VOL_MAX_DB) return 1.0f;
    return (db - VOL_MIN_DB) / (VOL_MAX_DB - VOL_MIN_DB);
}
static inline float vol_scalar_to_amp(float s) {
    if (s <= 0.0f) return 0.0f;
    if (s >= 1.0f) return 1.0f;
    return powf(10.0f, vol_scalar_to_db(s) / 20.0f);
}
static int vol_idx_for_obj(AudioObjectID o) {
    if (o == kObjVolume) return 0;
    if (o >= kObjVolCh1 && o <= kObjVolCh10) return (int)(o - kObjVolCh1 + 1);
    return -1;
}
static void vol_apply_frame(float *fr) {
    UInt32 muted = atomic_load_explicit(&g_vol_mute, memory_order_relaxed);
    float master = muted ? 0.0f : vol_scalar_to_amp(atomic_load_explicit(&g_vol_scalar[0], memory_order_relaxed));
    const float step = 1.0f / 220.0f;
    for (int ch = 0; ch < NCH; ch++) {
        float ch_amp = vol_scalar_to_amp(atomic_load_explicit(&g_vol_scalar[ch + 1], memory_order_relaxed));
        float target = master * ch_amp;
        float g = atomic_load_explicit(&g_vol_applied[ch], memory_order_relaxed);
        if (g != target) {
            g = g < target ? fminf(g + step, target) : fmaxf(g - step, target);
            atomic_store_explicit(&g_vol_applied[ch], g, memory_order_relaxed);
        }
        fr[ch] *= g;
    }
}
static void meter_update(int base, const float *fr) {
    for (int c = 0; c < NCH; c++) {
        float a = fabsf(fr[c]);
        float prev = atomic_load_explicit(&g_meter_peaks[base + c], memory_order_relaxed);
        if (a > prev) atomic_store_explicit(&g_meter_peaks[base + c], a, memory_order_relaxed);
    }
}

/* HID state */
static NSMutableData *g_hbuf_in;
static _Atomic uint32_t g_seq = 1;
static dispatch_semaphore_t g_hid_sem;
static uint8_t  g_wait_cmd = 0;
static uint32_t g_wait_seq = 0;
static uint8_t  g_reply_buf[64];
static uint8_t  g_last_cmd_in[64];
static uint8_t  g_last_cmd_reply[64];
static _Atomic int g_pending_sr = 48000;
static SL4StatusPacket g_st;

/* 0x37 heartbeat (8 random challenge bytes, the box answers with 8 derived bytes) */
static dispatch_source_t g_hb_timer;
static uint32_t g_hb_seq;

/* Unsolicited HID packet ring buffer for SL4Api callbacks */
#define UNSOL_Q_MAX 64
static uint8_t  g_unsol_q[UNSOL_Q_MAX][64];
static uint32_t g_unsol_w = 0;
static uint32_t g_unsol_r = 0;

/* IOKit Hotplug watcher */
static IONotificationPortRef g_notify_port = NULL;
static io_iterator_t g_added_iter = 0;
static io_iterator_t g_removed_iter = 0;

static void unsol_push(const uint8_t pkt[64]) {
    pthread_mutex_lock(&g_unsol_mtx);
    if (g_unsol_w - g_unsol_r < UNSOL_Q_MAX) {
        memcpy(g_unsol_q[g_unsol_w % UNSOL_Q_MAX], pkt, 64);
        g_unsol_w++;
    }
    pthread_mutex_unlock(&g_unsol_mtx);
}

static void push_sr_unsol(int sr) {
    uint8_t pkt[64] = {0};
    pkt[0] = 0x49;
    pkt[5] = (uint8_t)((sr >> 16) & 0xFF);
    pkt[6] = (uint8_t)((sr >> 8) & 0xFF);
    pkt[7] = (uint8_t)(sr & 0xFF);
    unsol_push(pkt);
}

/* ============================================================================
 * USB & HID Engine
 * ============================================================================ */

static void hb_read(void) {
    if (!g_hpipe_in || !g_hbuf_in) return;
    [g_hpipe_in enqueueIORequestWithData:g_hbuf_in completionTimeout:0 error:nil completionHandler:^(IOReturn s, NSUInteger n) {
        if (s == kIOReturnSuccess && n > 0) {
            const uint8_t *b = g_hbuf_in.bytes;
            uint32_t rseq = 0;
            memcpy(&rseq, b + 1, 4);
            if (g_wait_cmd && b[0] == g_wait_cmd && (g_wait_seq == 0 || rseq == g_wait_seq)) {
                memcpy(g_reply_buf, b, 64);
                g_wait_cmd = 0;
                dispatch_semaphore_signal(g_hid_sem);
            } else if (b[0] == 0x37 && rseq == g_hb_seq) {
                /* reply to our own heartbeat: not a notification for clients */
            } else {
                /* Unsolicited notification from SL4 hardware */
                if (b[0] == 0x40) {
                    uint8_t len = b[5];
                    if (len > 58) len = 58;
                    for (uint8_t i = 0; i + 2 < len; i += 3) {
                        uint8_t st = b[6 + i];
                        uint8_t note = b[6 + i + 1];
                        uint8_t vel = b[6 + i + 2];
                        int on = ((st & 0xF0) == 0x90) ? 1 : 0;
                        if (note >= 0x5C && note <= 0x5F) {
                            g_st.thru[note - 0x5C] = on;
                        } else if (note == 0x61 && vel < 4) {
                            g_st.phono[vel] = on;
                        }
                    }
                } else if (b[0] == 0x45) {
                    g_st.port_a = b[5];
                    g_st.port_b = b[6];
                }
                unsol_push(b);
            }
        }
        if (s != kIOReturnAborted && g_hpipe_in) hb_read();
    }];
}

static bool hid_cmd(uint8_t cmd, const uint8_t *pl, size_t plen, uint8_t *reply_out, uint32_t *seq_override) {
    if (!g_hpipe_out || !g_hid_sem) return false;
    pthread_mutex_lock(&g_hid_mtx);
    while (dispatch_semaphore_wait(g_hid_sem, DISPATCH_TIME_NOW) == 0) {}

    uint8_t buf[64] = {0};
    buf[0] = cmd;
    uint32_t seq = seq_override ? *seq_override : g_seq++;
    memcpy(buf + 1, &seq, 4);
    if (pl && plen > 0 && plen <= 59) memcpy(buf + 5, pl, plen);

    g_wait_cmd = (cmd >= 0x40) ? 0 : cmd;
    g_wait_seq = seq;

    NSMutableData *d = [NSMutableData dataWithBytes:buf length:64];
    NSUInteger sent = 0;
    NSError *e = nil;
    pthread_mutex_lock(&g_hout_mtx);
    [g_hpipe_out sendIORequestWithData:d bytesTransferred:&sent completionTimeout:0 error:&e];
    pthread_mutex_unlock(&g_hout_mtx);

    bool ok = true;
    if (g_wait_cmd != 0) {
        if (dispatch_semaphore_wait(g_hid_sem, dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC)) == 0) {
            if (reply_out) memcpy(reply_out, g_reply_buf, 64);
        } else {
            g_wait_cmd = 0;
            ok = false;
        }
    } else if (reply_out) {
        memset(reply_out, 0, 64);
        reply_out[0] = cmd;
        memcpy(reply_out + 1, &seq, 4);
    }
    pthread_mutex_unlock(&g_hid_mtx);
    return ok;
}

static void refresh_hw_status(void) {
    uint8_t r[64];
    if (hid_cmd(0x10, NULL, 0, r, NULL)) {
        g_st.version_maj = r[5];
        g_st.version_min = r[6];
    }
    if (hid_cmd(0x04, NULL, 0, r, NULL)) {
        for (int i = 0; i < 31; i++) {
            uint16_t ch = r[5 + i*2] | (r[6 + i*2] << 8);
            if (!ch || ch > 127) { g_st.serial[i] = 0; break; }
            g_st.serial[i] = (uint8_t)ch;
        }
    }
    uint8_t req_ports[1] = {0};
    if (hid_cmd(0x45, req_ports, 1, r, NULL)) {
        g_st.port_a = r[5];
        g_st.port_b = r[6];
    }
}

static void send_hw_samplerate(int sr) {
    uint8_t pl[2] = { (uint8_t)((sr >> 8) & 0xFF), (uint8_t)(sr & 0xFF) };
    hid_cmd(0x31, pl, 2, NULL, NULL);
    push_sr_unsol(sr);
}

static void set_usb_switches(bool usb_mode) {
    /* SL4 uses Hidi Note Off (0x80 = USB Audio / Thru Off) and Note On (0x90 = Analog Thru On)
       via HID command 0x41 on notes 0x5C..0x5F (Decks 1..4) */
    uint8_t status_byte = usb_mode ? 0x80 : 0x90;
    for (int i = 0; i < 4; i++) {
        uint8_t pl[4] = { 0x03, status_byte, (uint8_t)(0x5C + i), 0x00 };
        hid_cmd(0x41, pl, 4, NULL, NULL);
        g_st.thru[i] = usb_mode ? 0 : 1;
        uint8_t notify[64] = {0};
        notify[0] = 0x40;
        notify[5] = 0x03;
        notify[6] = status_byte | 0x01;
        notify[7] = (uint8_t)(0x5C + i);
        notify[8] = 0x00;
        unsol_push(notify);
    }
}

/* Heartbeat. Like the SL 2 and SL 3, the SL 4 answers command 0x37 (8 challenge bytes -> 8
   derived bytes) and keeps its decks on USB audio only while this traffic flows.
   Runs on g_q every HEARTBEAT_MS while streaming. */
static void hb_tick(void) {
    if (!atomic_load(&g_io_running) || !g_hpipe_out) return;
    uint8_t buf[64] = {0};
    buf[0] = 0x37;
    g_hb_seq = g_seq++;
    memcpy(buf + 1, &g_hb_seq, 4);
    arc4random_buf(buf + 5, 8);
    NSMutableData *d = [NSMutableData dataWithBytes:buf length:64];
    pthread_mutex_lock(&g_hout_mtx);
    [g_hpipe_out enqueueIORequestWithData:d completionTimeout:0 error:nil completionHandler:^(IOReturn s, NSUInteger n) { (void)s; (void)n; }];
    pthread_mutex_unlock(&g_hout_mtx);
}

static void hb_start(void) {
    if (g_hb_timer || !g_q) return;
    g_hb_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_q);
    dispatch_source_set_timer(g_hb_timer, dispatch_time(DISPATCH_TIME_NOW, 0), HEARTBEAT_MS * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_hb_timer, ^{ hb_tick(); });
    dispatch_resume(g_hb_timer);
}

static void hb_stop(void) {
    if (!g_hb_timer) return;
    dispatch_source_cancel(g_hb_timer);
    g_hb_timer = nil;
}

static IOUSBHostPipe *copy_isoch_pipe(IOUSBHostInterface *intf, uint8_t dir, uint8_t fallback1, uint8_t fallback2, uint32_t *out_mps) {
    const IOUSBConfigurationDescriptor *cfg = intf.configurationDescriptor;
    const IOUSBInterfaceDescriptor *ifd = intf.interfaceDescriptor;
    if (cfg && ifd) {
        const IOUSBEndpointDescriptor *ep = NULL;
        while ((ep = IOUSBGetNextEndpointDescriptor(cfg, ifd, (const IOUSBDescriptorHeader *)ep)) != NULL) {
            if (IOUSBGetEndpointDirection(ep) == dir && IOUSBGetEndpointType(ep) == kIOUSBEndpointTypeIsochronous) {
                NSError *e = nil;
                IOUSBHostPipe *p = [intf copyPipeWithAddress:ep->bEndpointAddress error:&e];
                if (p) {
                    uint32_t mps = OSSwapLittleToHostInt16(ep->wMaxPacketSize) & 0x7FF;
                    if (mps >= FRAME_BYTES && mps <= PKT_BUF_MAX && out_mps) *out_mps = mps;
                    return p;
                }
            }
        }
    }
    NSError *e = nil;
    IOUSBHostPipe *p = [intf copyPipeWithAddress:fallback1 error:&e];
    if (p) return p;
    return [intf copyPipeWithAddress:fallback2 error:&e];
}

/* ============================================================================
 * Isochronous Audio Streaming (Capture + Implicit-Feedback Playback)
 * ============================================================================ */

static void clk_update(int frames, uint64_t hw_time) {
    if (!frames) return;
    uint64_t now = (hw_time > 0) ? hw_time : mach_absolute_time();
    uint64_t prev = atomic_fetch_add_explicit(&g_total_cap_frames, frames, memory_order_relaxed);
    if (prev == 0) {
        atomic_store_explicit(&g_anchor_host, now, memory_order_release);
    } else if ((prev / 2048) != ((prev + frames) / 2048)) {
        uint64_t a = atomic_load_explicit(&g_anchor_host, memory_order_relaxed);
        double elapsed = (double)(now - a);
        double measured = elapsed / (double)(prev + frames);
        double nom = ((1e9 / g_sr) * (double)g_tb.denom) / (double)g_tb.numer;
        if (measured > nom * 0.90 && measured < nom * 1.10) {
            double cur = atomic_load_explicit(&g_ticks_per_frame, memory_order_relaxed);
            atomic_store_explicit(&g_ticks_per_frame, 0.995 * cur + 0.005 * measured, memory_order_relaxed);
        }
    }
}

static void play_submit(int idx) {
    if (!atomic_load(&g_io_running) || !g_ppipe) return;
    IsoXfer *xf = &g_play_xf[idx];
    uint8_t *buf = xf->buf.mutableBytes;
    IOUSBHostIsochronousTransaction *tx = xf->tx;
    uint64_t f = g_play_frame;
    g_play_frame += PLAY_PKTS / 8;

    int total_frames = 0;
    int pkt_n[PLAY_PKTS];
    for (int k = 0; k < PLAY_PKTS; k++) {
        int n;
        uint32_t r = atomic_load_explicit(&g_fifo_r, memory_order_relaxed);
        uint32_t w = atomic_load_explicit(&g_fifo_w, memory_order_acquire);
        if (r < w) {
            n = g_fifo[r % FIFO_N];
            atomic_store_explicit(&g_fifo_r, r + 1, memory_order_release);
        } else {
            uint32_t sr8 = (uint32_t)g_sr;
            g_faccum += sr8;
            n = g_faccum / 8000;
            g_faccum %= 8000;
        }
        if (n < 4) n = 5;
        if ((uint32_t)(n * FRAME_BYTES) > g_play_pkt_max) n = g_play_pkt_max / FRAME_BYTES;
        pkt_n[k] = n;
        total_frames += n;
    }

    uint64_t rp0 = atomic_fetch_add_explicit(&g_total_play_frames, total_frames, memory_order_acq_rel);
    uint64_t rp = rp0;
    dp_slot_t *sl = &g_dp_sched[f & DP_MASK];
    atomic_fetch_add_explicit(&sl->seq, 1, memory_order_release);
    sl->frame = f;
    sl->s0 = rp0;
    sl->total = (uint32_t)total_frames;
    sl->buf = buf;

    for (int k = 0; k < PLAY_PKTS; k++) {
        int n = pkt_n[k];
        uint32_t off = (uint32_t)(k * g_play_pkt_max);
        sl->pkt_n[k] = (uint16_t)n;
        sl->pkt_off[k] = off;
        tx[k] = (IOUSBHostIsochronousTransaction){
            .requestCount = (uint32_t)(n * FRAME_BYTES),
            .offset = off
        };

        uint8_t *dst = buf + off;
        for (int s = 0; s < n; s++) {
            uint32_t ridx = ((uint32_t)(rp & RING_MASK)) * NCH;
            uint8_t *q = dst + s * FRAME_BYTES;
            float fr[NCH];
            for (int c = 0; c < NCH; c++) {
                fr[c] = g_out_ring[ridx + c];
                g_out_ring[ridx + c] = 0.0f;
            }
            pack_32lj(q, fr);
            rp++;
        }
    }
    atomic_fetch_add_explicit(&sl->seq, 1, memory_order_release);
    atomic_store_explicit(&g_dp_newest_s0, rp0, memory_order_relaxed);
    atomic_store_explicit(&g_dp_newest_frame, f, memory_order_release);

    atomic_fetch_add(&g_play_inflight, 1);
    NSError *e = nil;
    BOOL queued = [g_ppipe enqueueIORequestWithData:xf->buf
                      transactionList:tx
                  transactionListCount:PLAY_PKTS
                      firstFrameNumber:f
                               options:IOUSBHostIsochronousTransferOptionsNone
                                 error:&e
                     completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
        (void)done;
        atomic_fetch_sub(&g_play_inflight, 1);
        if (atomic_load(&g_io_running) && st != kIOReturnAborted) {
            play_submit(idx);
        }
    }];
    if (!queued) atomic_fetch_sub(&g_play_inflight, 1);
}

static void cap_submit(int idx) {
    if (!atomic_load(&g_io_running) || !g_cpipe) return;
    IsoXfer *xf = &g_cap_xf[idx];
    IOUSBHostIsochronousTransaction *tx = xf->tx;
    uint64_t f = g_cap_frame;
    g_cap_frame += CAP_PKTS / 8;

    for (int k = 0; k < CAP_PKTS; k++) {
        tx[k] = (IOUSBHostIsochronousTransaction){
            .requestCount = g_cap_pkt_max,
            .offset = (uint32_t)(k * g_cap_pkt_max)
        };
    }

    NSError *e = nil;
    [g_cpipe enqueueIORequestWithData:xf->buf
                      transactionList:tx
                  transactionListCount:CAP_PKTS
                      firstFrameNumber:f
                               options:IOUSBHostIsochronousTransferOptionsNone
                                 error:&e
                     completionHandler:^(IOReturn st, IOUSBHostIsochronousTransaction *done) {
        if (!atomic_load(&g_io_running) || st == kIOReturnAborted) return;
        const uint8_t *b = xf->buf.bytes;
        uint64_t wp = atomic_load_explicit(&g_total_cap_frames, memory_order_relaxed);
        int got = 0;
        uint64_t ts = 0;

        for (int k = 0; k < CAP_PKTS; k++) {
            if (done[k].status != kIOReturnSuccess || done[k].completeCount > g_cap_pkt_max) continue;
            int n = done[k].completeCount / FRAME_BYTES;
            if (n >= 4) {
                uint32_t w = atomic_load_explicit(&g_fifo_w, memory_order_relaxed);
                uint32_t r = atomic_load_explicit(&g_fifo_r, memory_order_acquire);
                if (w - r < FIFO_N) {
                    g_fifo[w % FIFO_N] = n;
                    atomic_store_explicit(&g_fifo_w, w + 1, memory_order_release);
                }
            }
            if (n > 0) {
                if (!ts) ts = done[k].timeStamp;
                const uint8_t *p = b + k * g_cap_pkt_max;
                for (int s = 0; s < n; s++) {
                    const uint8_t *q = p + s * FRAME_BYTES;
                    float *fr = &g_in_ring[(( wp + got ) & RING_MASK) * NCH];
                    for (int c = 0; c < NCH; c++) {
                        int32_t raw32 = 0;
                        memcpy(&raw32, q + c * 4, 4);
                        int32_t s24 = raw32 >> 8;
                        fr[c] = (float)s24 * (1.0f / 8388608.0f);
                    }
                    meter_update(0, fr);
                    got++;
                }
            }
        }
        if (got > 0) clk_update(got, ts);

        if (atomic_load(&g_play_inflight) == 0 &&
            (atomic_load(&g_fifo_w) - atomic_load(&g_fifo_r)) >= 2 * PLAY_PKTS) {
            g_play_frame = [g_dev frameNumberWithTime:NULL] + 2;
            for (int j = 0; j < PLAY_NXF; j++) play_submit(j);
        }
        cap_submit(idx);
    }];
}

/* ============================================================================
 * USB Open / Close Lifecycle
 * ============================================================================ */

static io_service_t find_sl4_service(void) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    if (!m) return IO_OBJECT_NULL;
    int v = VID, p = PID;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), pn);
    CFRelease(vn); CFRelease(pn);
    return IOServiceGetMatchingService(kIOMainPortDefault, m);
}

static bool usb_ensure_hid(void) {
    if (g_dev && g_hid && g_hpipe_in && g_hpipe_out) return true;
    io_service_t svc = find_sl4_service();
    if (!svc) return false;

    NSError *e = nil;
    if (!g_q) {
        dispatch_queue_attr_t qa = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        g_q = dispatch_queue_create("com.rane.sl4.usb", qa);
    }
    if (!g_hid_sem) g_hid_sem = dispatch_semaphore_create(0);

    g_dev = [[IOUSBHostDevice alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
    IOObjectRelease(svc);
    if (!g_dev) { LOG("Failed to open IOUSBHostDevice: %{public}@", e); return false; }
    [g_dev configureWithValue:1 matchInterfaces:YES error:&e];

    io_iterator_t it = 0;
    IORegistryEntryGetChildIterator(g_dev.ioService, kIOServicePlane, &it);
    io_service_t ch;
    while ((ch = IOIteratorNext(it))) {
        CFNumberRef n = IORegistryEntryCreateCFProperty(ch, CFSTR("bInterfaceNumber"), kCFAllocatorDefault, 0);
        if (n) {
            int idx = -1;
            CFNumberGetValue(n, kCFNumberIntType, &idx);
            CFRelease(n);
            if (idx == IF_HID) {
                g_hid = [[IOUSBHostInterface alloc] initWithIOService:ch options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
            }
        }
        IOObjectRelease(ch);
    }
    IOObjectRelease(it);

    if (g_hid) {
        g_hpipe_out = [g_hid copyPipeWithAddress:EP_HID_OUT error:&e];
        g_hpipe_in  = [g_hid copyPipeWithAddress:EP_HID_IN error:&e];
        g_hbuf_in   = [NSMutableData dataWithLength:64];
        hb_read();
        refresh_hw_status();
        atomic_store(&g_hw_connected, true);
        return true;
    }
    return false;
}

static bool usb_open_all(void) {
    if (!usb_ensure_hid()) return false;
    NSError *e = nil;

    io_iterator_t it = 0;
    IORegistryEntryGetChildIterator(g_dev.ioService, kIOServicePlane, &it);
    io_service_t ch;
    while ((ch = IOIteratorNext(it))) {
        CFNumberRef n = IORegistryEntryCreateCFProperty(ch, CFSTR("bInterfaceNumber"), kCFAllocatorDefault, 0);
        if (n) {
            int idx = -1;
            CFNumberGetValue(n, kCFNumberIntType, &idx);
            CFRelease(n);
            if (idx == IF_PLAY && !g_play) g_play = [[IOUSBHostInterface alloc] initWithIOService:ch options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
            if (idx == IF_CAP  && !g_cap)  g_cap  = [[IOUSBHostInterface alloc] initWithIOService:ch options:IOUSBHostObjectInitOptionsNone queue:g_q error:&e interestHandler:nil];
        }
        IOObjectRelease(ch);
    }
    IOObjectRelease(it);

    if (!g_play || !g_cap) {
        LOG("Failed to claim Play/Cap interfaces");
        return false;
    }

    send_hw_samplerate((int)g_sr);

    g_play_pkt_max = PKT_MAX;
    g_cap_pkt_max  = PKT_MAX;

    [g_play selectAlternateSetting:1 error:&e];
    g_ppipe = copy_isoch_pipe(g_play, kIOUSBEndpointDirectionOut, EP_PLAY, 0x02, &g_play_pkt_max);

    [g_cap selectAlternateSetting:1 error:&e];
    g_cpipe = copy_isoch_pipe(g_cap, kIOUSBEndpointDirectionIn, EP_CAP, 0x86, &g_cap_pkt_max);

    if (!g_ppipe || !g_cpipe) {
        LOG("Failed to open Isoch pipes");
        return false;
    }

    for (int i = 0; i < CAP_NXF; i++) {
        if (!g_cap_xf[i].buf) g_cap_xf[i].buf = [NSMutableData dataWithLength:CAP_PKTS * PKT_BUF_MAX];
        if (!g_cap_xf[i].tx)  g_cap_xf[i].tx  = calloc(CAP_PKTS, sizeof(IOUSBHostIsochronousTransaction));
    }
    for (int i = 0; i < PLAY_NXF; i++) {
        if (!g_play_xf[i].buf) g_play_xf[i].buf = [NSMutableData dataWithLength:PLAY_PKTS * PKT_BUF_MAX];
        if (!g_play_xf[i].tx)  g_play_xf[i].tx  = calloc(PLAY_PKTS, sizeof(IOUSBHostIsochronousTransaction));
    }

    set_usb_switches(true);
    hb_start();

    memset(g_in_ring, 0, sizeof(g_in_ring));
    memset(g_out_ring, 0, sizeof(g_out_ring));
    memset(g_dp_sched, 0, sizeof(g_dp_sched));
    atomic_store(&g_dp_newest_s0, 0);
    atomic_store(&g_dp_newest_frame, 0);
    atomic_store(&g_dp_active, 1);
    atomic_store(&g_fifo_w, 0);
    atomic_store(&g_fifo_r, 0);
    atomic_store(&g_play_inflight, 0);
    g_faccum = 0;

    double nom = ((1e9 / g_sr) * (double)g_tb.denom) / (double)g_tb.numer;
    atomic_store(&g_ticks_per_frame, nom);
    atomic_store(&g_anchor_host, mach_absolute_time());
    atomic_store(&g_total_cap_frames, 0);
    atomic_store(&g_total_play_frames, 0);

    atomic_store(&g_io_running, true);
    g_cap_frame = [g_dev frameNumberWithTime:NULL] + 2;
    for (int i = 0; i < CAP_NXF; i++) cap_submit(i);

    LOG("Streaming started on Rane SL 4 (%.0f Hz)", g_sr);
    return true;
}

static void usb_stop_streaming(void) {
    if (!atomic_exchange(&g_io_running, false)) return;
    atomic_store_explicit(&g_dp_active, 0, memory_order_release);
    while (atomic_load_explicit(&g_dp_writers, memory_order_acquire) > 0) {
        usleep(50);
    }
    hb_stop();
    if (g_cpipe) [g_cpipe abortWithError:nil];
    if (g_ppipe) [g_ppipe abortWithError:nil];
    if (g_cap)   [g_cap selectAlternateSetting:0 error:nil];
    if (g_play)  [g_play selectAlternateSetting:0 error:nil];
    set_usb_switches(false);
    g_cpipe = nil; g_ppipe = nil;
    g_cap = nil;   g_play = nil;
    LOG("Streaming stopped; Analog Thru restored");
}

static void usb_close_all(void) {
    usb_stop_streaming();
    if (g_hpipe_in)  [g_hpipe_in abortWithError:nil];
    if (g_hpipe_out) [g_hpipe_out abortWithError:nil];
    g_hpipe_in = nil; g_hpipe_out = nil;
    if (g_hid)  { [g_hid destroy]; g_hid = nil; }
    if (g_dev)  { [g_dev destroy]; g_dev = nil; }
    atomic_store(&g_hw_connected, false);
}

static void notify_alive_changed(void) {
    if (!g_host) return;
    AudioObjectPropertyAddress dev_addr = {
        kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    g_host->PropertiesChanged(g_host, kObjDevice, 1, &dev_addr);
    AudioObjectPropertyAddress plug_addrs[2] = {
        { kAudioPlugInPropertyDeviceList,   kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
    };
    g_host->PropertiesChanged(g_host, kObjPlugIn, 2, plug_addrs);
}

static void on_usb_added(void *refcon, io_iterator_t iter) {
    (void)refcon;
    io_service_t s;
    bool found = false;
    while ((s = IOIteratorNext(iter))) { IOObjectRelease(s); found = true; }
    if (found) {
        LOG("Rane SL 4 USB connected");
        for (int attempt = 0; attempt < 5; attempt++) {
            pthread_mutex_lock(&g_mutex);
            bool ok = usb_ensure_hid();
            pthread_mutex_unlock(&g_mutex);
            if (ok) break;
            usleep(100000);
        }
        notify_alive_changed();
    }
}

static void on_usb_removed(void *refcon, io_iterator_t iter) {
    io_service_t s;
    bool removed = false;
    while ((s = IOIteratorNext(iter))) { IOObjectRelease(s); removed = true; }
    if (removed) {
        LOG("Rane SL 4 USB disconnected");
        pthread_mutex_lock(&g_mutex);
        usb_close_all();
        pthread_mutex_unlock(&g_mutex);
        notify_alive_changed();
    }
}

static void start_hotplug_monitor(void) {
    dispatch_queue_t hq = dispatch_queue_create("com.rane.sl4.hotplug", DISPATCH_QUEUE_SERIAL);
    g_notify_port = IONotificationPortCreate(kIOMainPortDefault);
    IONotificationPortSetDispatchQueue(g_notify_port, hq);

    int v = VID, p = PID;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);

    CFMutableDictionaryRef m1 = IOServiceMatching(kIOUSBDeviceClassName);
    CFDictionarySetValue(m1, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m1, CFSTR(kUSBProductID), pn);
    IOServiceAddMatchingNotification(g_notify_port, kIOFirstMatchNotification, m1, on_usb_added, NULL, &g_added_iter);
    on_usb_added(NULL, g_added_iter);

    CFMutableDictionaryRef m2 = IOServiceMatching(kIOUSBDeviceClassName);
    CFDictionarySetValue(m2, CFSTR(kUSBVendorID), vn);
    CFDictionarySetValue(m2, CFSTR(kUSBProductID), pn);
    IOServiceAddMatchingNotification(g_notify_port, kIOTerminatedNotification, m2, on_usb_removed, NULL, &g_removed_iter);
    while (IOIteratorNext(g_removed_iter)) {}

    CFRelease(vn); CFRelease(pn);
}

/* ============================================================================
 * CoreAudio AudioServerPlugIn Interface
 * ============================================================================ */

static HRESULT SL4_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    CFUUIDRef iunk = IUnknownUUID;
    CFUUIDRef p2 = kAudioServerPlugInDriverInterfaceUUID;
    if (CFEqual(req, iunk) || CFEqual(req, p2)) {
        CFRelease(req);
        g_ref_count++;
        *outInterface = inDriver;
        return kAudioHardwareNoError;
    }
    CFRelease(req);
    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG SL4_AddRef(void *inDriver) { return ++g_ref_count; }
static ULONG SL4_Release(void *inDriver) { return g_ref_count > 0 ? --g_ref_count : 0; }

static OSStatus SL4_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    g_log = os_log_create("com.rane.sl4", "HAL");
    g_host = inHost;
    mach_timebase_info(&g_tb);
    double nom = ((1e9 / g_sr) * (double)g_tb.denom) / (double)g_tb.numer;
    atomic_store(&g_ticks_per_frame, nom);
    start_hotplug_monitor();
    LOG("SL4Device AudioServerPlugIn Initialized");
    return kAudioHardwareNoError;
}

static OSStatus SL4_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *ci, AudioObjectID *outID) { (void)d; (void)desc; (void)ci; (void)outID; return kAudioHardwareUnsupportedOperationError; }
static OSStatus SL4_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) { (void)d; (void)id; return kAudioHardwareUnsupportedOperationError; }
static OSStatus SL4_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci) { (void)d; (void)id; (void)ci; return kAudioHardwareNoError; }
static OSStatus SL4_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci) { (void)d; (void)id; (void)ci; return kAudioHardwareNoError; }

static void apply_sample_rate_change(int sr) {
    if (sr != 44100 && sr != 48000) return;
    g_sr = (Float64)sr;
    double nom = ((1e9 / g_sr) * (double)g_tb.denom) / (double)g_tb.numer;
    atomic_store(&g_ticks_per_frame, nom);
    pthread_mutex_lock(&g_mutex);
    if (usb_ensure_hid()) send_hw_samplerate(sr);
    pthread_mutex_unlock(&g_mutex);
    if (g_host) {
        AudioObjectPropertyAddress da = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        g_host->PropertiesChanged(g_host, kObjDevice, 1, &da);
        AudioObjectPropertyAddress sa[2] = {
            { kAudioStreamPropertyVirtualFormat,  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            { kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
        };
        g_host->PropertiesChanged(g_host, kObjStreamIn, 2, sa);
        g_host->PropertiesChanged(g_host, kObjStreamOut, 2, sa);
    }
}

static OSStatus SL4_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) {
    (void)d; (void)id; (void)info;
    if (action == 1) {
        apply_sample_rate_change(atomic_load(&g_pending_sr));
    }
    return kAudioHardwareNoError;
}
static OSStatus SL4_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) { (void)d; (void)id; (void)action; (void)info; return kAudioHardwareNoError; }

static Boolean SL4_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr) {
    (void)d; (void)pid;
    if (!addr) return false;
    AudioObjectPropertySelector s = addr->mSelector;
    AudioObjectPropertyScope sc = addr->mScope;

    if (oid == kObjPlugIn) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyResourceBundle:
                return true;
        }
        return false;
    }
    if (oid == kObjDevice) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyModelName:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertyStreams:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyIcon:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyPreferredChannelsForStereo:
            case kAudioDevicePropertyPreferredChannelLayout:
            case kAudioObjectPropertyElementName:
            case kSL4PropHIDCommand:
            case kSL4PropStatus:
            case kSL4PropUnsolQueue:
            case kSL4PropMeters:
            case kAudioObjectPropertyCustomPropertyInfoList:
                return true;
        }
        return false;
    }
    if (oid == kObjStreamIn || oid == kObjStreamOut) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                return true;
        }
        return false;
    }
    if (vol_idx_for_obj(oid) >= 0) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioControlPropertyScope:
            case kAudioControlPropertyElement:
            case kAudioLevelControlPropertyScalarValue:
            case kAudioLevelControlPropertyDecibelValue:
            case kAudioLevelControlPropertyDecibelRange:
            case kAudioLevelControlPropertyConvertScalarToDecibels:
            case kAudioLevelControlPropertyConvertDecibelsToScalar:
                return true;
        }
        return false;
    }
    if (oid == kObjMute) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioControlPropertyScope:
            case kAudioControlPropertyElement:
            case kAudioBooleanControlPropertyValue:
                return true;
        }
        return false;
    }
    (void)sc;
    return false;
}

static OSStatus SL4_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, Boolean *outSettable) {
    (void)d; (void)pid;
    *outSettable = false;
    if (oid == kObjDevice && (addr->mSelector == kAudioDevicePropertyNominalSampleRate || addr->mSelector == kSL4PropHIDCommand)) {
        *outSettable = true;
    } else if ((oid == kObjStreamIn || oid == kObjStreamOut) &&
               (addr->mSelector == kAudioStreamPropertyVirtualFormat || addr->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        *outSettable = true;
    } else if (vol_idx_for_obj(oid) >= 0 &&
               (addr->mSelector == kAudioLevelControlPropertyScalarValue || addr->mSelector == kAudioLevelControlPropertyDecibelValue)) {
        *outSettable = true;
    } else if (oid == kObjMute && addr->mSelector == kAudioBooleanControlPropertyValue) {
        *outSettable = true;
    }
    return kAudioHardwareNoError;
}

static void fill_asbd(AudioStreamBasicDescription *a, Float64 sr) {
    memset(a, 0, sizeof(*a));
    a->mSampleRate       = sr;
    a->mFormatID         = kAudioFormatLinearPCM;
    a->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    a->mBytesPerPacket   = NCH * sizeof(Float32);
    a->mFramesPerPacket  = 1;
    a->mBytesPerFrame    = NCH * sizeof(Float32);
    a->mChannelsPerFrame = NCH;
    a->mBitsPerChannel   = 32;
}

static OSStatus SL4_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qsz, const void *qd, UInt32 *outSize) {
    (void)d; (void)pid; (void)qsz; (void)qd;
    AudioObjectPropertySelector s = addr->mSelector;
    AudioObjectPropertyScope sc = addr->mScope;

    if (oid == kObjPlugIn) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner: *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyResourceBundle: *outSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                *outSize = (atomic_load(&g_hw_connected) || g_io_clients > 0) ? sizeof(AudioObjectID) : 0;
                return 0;
            case kAudioPlugInPropertyTranslateUIDToDevice: *outSize = sizeof(AudioObjectID); return 0;
        }
    }
    if (oid == kObjDevice) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner: *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyModelName:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioObjectPropertyElementName: *outSize = sizeof(CFStringRef); return 0;
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod: *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyRelatedDevices: *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyOwnedObjects:
                if (sc == kAudioObjectPropertyScopeInput) *outSize = sizeof(AudioObjectID);
                else if (sc == kAudioObjectPropertyScopeOutput) *outSize = 13 * sizeof(AudioObjectID);
                else *outSize = 14 * sizeof(AudioObjectID);
                return 0;
            case kAudioDevicePropertyStreams:
                if (sc == kAudioObjectPropertyScopeInput || sc == kAudioObjectPropertyScopeOutput) *outSize = sizeof(AudioObjectID);
                else *outSize = 2 * sizeof(AudioObjectID);
                return 0;
            case kAudioObjectPropertyControlList:
                *outSize = (sc == kAudioObjectPropertyScopeInput) ? 0 : 12 * sizeof(AudioObjectID);
                return 0;
            case kAudioDevicePropertyNominalSampleRate: *outSize = sizeof(Float64); return 0;
            case kAudioDevicePropertyAvailableNominalSampleRates: *outSize = 2 * sizeof(AudioValueRange); return 0;
            case kAudioDevicePropertyPreferredChannelsForStereo: *outSize = 2 * sizeof(UInt32); return 0;
            case kAudioDevicePropertyPreferredChannelLayout:
                *outSize = offsetof(AudioChannelLayout, mChannelDescriptions) + NCH * sizeof(AudioChannelDescription);
                return 0;
            case kSL4PropHIDCommand:
            case kSL4PropStatus:
            case kSL4PropUnsolQueue:
            case kSL4PropMeters: *outSize = sizeof(CFDataRef); return 0;
            case kAudioObjectPropertyCustomPropertyInfoList: *outSize = 4 * sizeof(AudioServerPlugInCustomPropertyInfo); return 0;
        }
    }
    if (oid == kObjStreamIn || oid == kObjStreamOut) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner: *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyName: *outSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency: *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: *outSize = sizeof(AudioStreamBasicDescription); return 0;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: *outSize = 2 * sizeof(AudioStreamRangedDescription); return 0;
        }
    }
    if (vol_idx_for_obj(oid) >= 0) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass: *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner: *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
            case kAudioControlPropertyScope:
            case kAudioControlPropertyElement: *outSize = sizeof(UInt32); return 0;
            case kAudioLevelControlPropertyScalarValue:
            case kAudioLevelControlPropertyDecibelValue:
            case kAudioLevelControlPropertyConvertScalarToDecibels:
            case kAudioLevelControlPropertyConvertDecibelsToScalar: *outSize = sizeof(Float32); return 0;
            case kAudioLevelControlPropertyDecibelRange: *outSize = sizeof(AudioValueRange); return 0;
        }
    }
    if (oid == kObjMute) {
        switch (s) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass: *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner: *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
            case kAudioControlPropertyScope:
            case kAudioControlPropertyElement:
            case kAudioBooleanControlPropertyValue: *outSize = sizeof(UInt32); return 0;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SL4_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qsz, const void *qd, UInt32 inSize, UInt32 *outSize, void *outData) {
    (void)d; (void)pid; (void)qsz;
    AudioObjectPropertySelector s = addr->mSelector;
    AudioObjectPropertyScope sc = addr->mScope;

    if (oid == kObjPlugIn) {
        switch (s) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID*)outData = kAudioObjectClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyClass: *(AudioClassID*)outData = kAudioPlugInClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner: *(AudioObjectID*)outData = kAudioObjectUnknown; *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyManufacturer: *(CFStringRef*)outData = CFSTR("Rane Corporation"); *outSize = sizeof(CFStringRef); return 0;
            case kAudioPlugInPropertyResourceBundle: *(CFStringRef*)outData = CFSTR(""); *outSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                if ((atomic_load(&g_hw_connected) || g_io_clients > 0) && inSize >= sizeof(AudioObjectID)) {
                    *(AudioObjectID*)outData = kObjDevice;
                    *outSize = sizeof(AudioObjectID);
                } else {
                    *outSize = 0;
                }
                return 0;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                CFStringRef u = *(CFStringRef*)qd;
                *(AudioObjectID*)outData = (u && CFEqual(u, CFSTR("com.rane.sl4.hal.device")) && (atomic_load(&g_hw_connected) || g_io_clients > 0)) ? kObjDevice : kAudioObjectUnknown;
                *outSize = sizeof(AudioObjectID);
                return 0;
            }
        }
    }

    if (oid == kObjDevice) {
        switch (s) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID*)outData = kAudioObjectClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyClass: *(AudioClassID*)outData = kAudioDeviceClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner: *(AudioObjectID*)outData = kObjPlugIn; *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyName: *(CFStringRef*)outData = CFSTR("SL 4"); *outSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyManufacturer: *(CFStringRef*)outData = CFSTR("Rane Corporation"); *outSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyModelName: *(CFStringRef*)outData = CFSTR("Rane SL 4"); *outSize = sizeof(CFStringRef); return 0;
            case kAudioDevicePropertyDeviceUID: *(CFStringRef*)outData = CFSTR("com.rane.sl4.hal.device"); *outSize = sizeof(CFStringRef); return 0;
            case kAudioDevicePropertyModelUID: *(CFStringRef*)outData = CFSTR("com.rane.sl4.hal.model"); *outSize = sizeof(CFStringRef); return 0;
            case kAudioDevicePropertyTransportType: *(UInt32*)outData = kAudioDeviceTransportTypeUSB; *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyRelatedDevices: *(AudioObjectID*)outData = kObjDevice; *outSize = sizeof(AudioObjectID); return 0;
            case kAudioDevicePropertyClockDomain: *(UInt32*)outData = 0x52414E34; *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyDeviceIsAlive: *(UInt32*)outData = (atomic_load(&g_hw_connected) || g_io_clients > 0) ? 1 : 0; *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyDeviceIsRunning: *(UInt32*)outData = (g_io_clients > 0) ? 1 : 0; *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *(UInt32*)outData = 1; *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyLatency:
                *(UInt32*)outData = (sc == kAudioObjectPropertyScopeInput)
                                  ? (UInt32)llround(LAT_IN_44 * g_sr / 44100.0)
                                  : (UInt32)llround(LAT_OUT_44 * g_sr / 44100.0);
                *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertySafetyOffset:
                *(UInt32*)outData = (sc == kAudioObjectPropertyScopeInput)
                                  ? (UInt32)llround(IN_SAFETY_44 * g_sr / 44100.0)
                                  : (UInt32)llround(OUT_SAFETY_44 * g_sr / 44100.0);
                *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyIsHidden: *(UInt32*)outData = 0; *outSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyZeroTimeStampPeriod: *(UInt32*)outData = ZTS_PERIOD; *outSize = sizeof(UInt32); return 0;
            case kAudioObjectPropertyOwnedObjects: {
                static const AudioObjectID inObjs[1] = { kObjStreamIn };
                static const AudioObjectID outObjs[13] = {
                    kObjStreamOut, kObjVolume, kObjMute,
                    kObjVolCh1, kObjVolCh2, kObjVolCh3, kObjVolCh4, kObjVolCh5,
                    kObjVolCh6, kObjVolCh7, kObjVolCh8, kObjVolCh9, kObjVolCh10
                };
                static const AudioObjectID allObjs[14] = {
                    kObjStreamIn, kObjStreamOut, kObjVolume, kObjMute,
                    kObjVolCh1, kObjVolCh2, kObjVolCh3, kObjVolCh4, kObjVolCh5,
                    kObjVolCh6, kObjVolCh7, kObjVolCh8, kObjVolCh9, kObjVolCh10
                };
                const AudioObjectID *src = allObjs;
                UInt32 cnt = 14;
                if (sc == kAudioObjectPropertyScopeInput) { src = inObjs; cnt = 1; }
                else if (sc == kAudioObjectPropertyScopeOutput) { src = outObjs; cnt = 13; }
                UInt32 n = inSize / sizeof(AudioObjectID);
                if (n > cnt) n = cnt;
                memcpy(outData, src, n * sizeof(AudioObjectID));
                *outSize = n * sizeof(AudioObjectID);
                return 0;
            }
            case kAudioDevicePropertyStreams: {
                AudioObjectID *ids = (AudioObjectID*)outData;
                if (sc == kAudioObjectPropertyScopeInput) { ids[0] = kObjStreamIn; *outSize = sizeof(AudioObjectID); }
                else if (sc == kAudioObjectPropertyScopeOutput) { ids[0] = kObjStreamOut; *outSize = sizeof(AudioObjectID); }
                else { ids[0] = kObjStreamIn; ids[1] = kObjStreamOut; *outSize = 2 * sizeof(AudioObjectID); }
                return 0;
            }
            case kAudioObjectPropertyControlList: {
                if (sc == kAudioObjectPropertyScopeInput) { *outSize = 0; return 0; }
                static const AudioObjectID ctrls[12] = {
                    kObjVolume, kObjMute,
                    kObjVolCh1, kObjVolCh2, kObjVolCh3, kObjVolCh4, kObjVolCh5,
                    kObjVolCh6, kObjVolCh7, kObjVolCh8, kObjVolCh9, kObjVolCh10
                };
                UInt32 n = inSize / sizeof(AudioObjectID);
                if (n > 12) n = 12;
                memcpy(outData, ctrls, n * sizeof(AudioObjectID));
                *outSize = n * sizeof(AudioObjectID);
                return 0;
            }
            case kAudioDevicePropertyNominalSampleRate: *(Float64*)outData = g_sr; *outSize = sizeof(Float64); return 0;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange *r = (AudioValueRange*)outData;
                r[0].mMinimum = 44100.0; r[0].mMaximum = 44100.0;
                r[1].mMinimum = 48000.0; r[1].mMaximum = 48000.0;
                *outSize = 2 * sizeof(AudioValueRange);
                return 0;
            }
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                UInt32 *c = (UInt32*)outData; c[0] = 1; c[1] = 2; *outSize = 2 * sizeof(UInt32); return 0;
            }
            case kAudioDevicePropertyPreferredChannelLayout: {
                AudioChannelLayout *l = (AudioChannelLayout*)outData;
                l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                l->mChannelBitmap = 0;
                l->mNumberChannelDescriptions = NCH;
                for (UInt32 i = 0; i < NCH; i++) {
                    l->mChannelDescriptions[i].mChannelLabel = kAudioChannelLabel_Discrete_0 + i;
                    l->mChannelDescriptions[i].mChannelFlags = 0;
                }
                *outSize = offsetof(AudioChannelLayout, mChannelDescriptions) + NCH * sizeof(AudioChannelDescription);
                return 0;
            }
            case kAudioObjectPropertyElementName: {
                static CFStringRef const inNames[10] = {
                    CFSTR("Deck 1 In L"), CFSTR("Deck 1 In R"),
                    CFSTR("Deck 2 In L"), CFSTR("Deck 2 In R"),
                    CFSTR("Deck 3 In L"), CFSTR("Deck 3 In R"),
                    CFSTR("Deck 4 In L"), CFSTR("Deck 4 In R"),
                    CFSTR("Aux In L"),    CFSTR("Aux In R")
                };
                static CFStringRef const outNames[10] = {
                    CFSTR("Deck 1 Out L"), CFSTR("Deck 1 Out R"),
                    CFSTR("Deck 2 Out L"), CFSTR("Deck 2 Out R"),
                    CFSTR("Deck 3 Out L"), CFSTR("Deck 3 Out R"),
                    CFSTR("Deck 4 Out L"), CFSTR("Deck 4 Out R"),
                    CFSTR("Aux Out L"),    CFSTR("Aux Out R")
                };
                UInt32 el = addr->mElement;
                if (el >= 1 && el <= NCH) {
                    CFStringRef nm = (sc == kAudioObjectPropertyScopeInput) ? inNames[el-1] : outNames[el-1];
                    CFRetain(nm);
                    *(CFStringRef*)outData = nm;
                } else {
                    *(CFStringRef*)outData = CFSTR("");
                }
                *outSize = sizeof(CFStringRef);
                return 0;
            }
            case kAudioObjectPropertyCustomPropertyInfoList: {
                static const AudioServerPlugInCustomPropertyInfo all[4] = {
                    { kSL4PropHIDCommand, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                    { kSL4PropStatus,     kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                    { kSL4PropUnsolQueue, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                    { kSL4PropMeters,     kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
                };
                UInt32 n = inSize / sizeof(AudioServerPlugInCustomPropertyInfo);
                if (n > 4) n = 4;
                memcpy(outData, all, n * sizeof(AudioServerPlugInCustomPropertyInfo));
                *outSize = n * sizeof(AudioServerPlugInCustomPropertyInfo);
                return 0;
            }
            case kSL4PropHIDCommand: {
                pthread_mutex_lock(&g_mutex);
                *(CFDataRef*)outData = CFDataCreate(kCFAllocatorDefault, g_last_cmd_reply, 64);
                pthread_mutex_unlock(&g_mutex);
                *outSize = sizeof(CFDataRef);
                return 0;
            }
            case kSL4PropStatus: {
                pthread_mutex_lock(&g_mutex);
                usb_ensure_hid();
                g_st.connected = atomic_load(&g_hw_connected) ? 1 : 0;
                g_st.streaming = atomic_load(&g_io_running) ? 1 : 0;
                g_st.sample_rate = (uint32_t)g_sr;
                g_st.cap_frames = atomic_load(&g_total_cap_frames);
                g_st.play_frames = atomic_load(&g_total_play_frames);
                pthread_mutex_unlock(&g_mutex);
                *(CFDataRef*)outData = CFDataCreate(kCFAllocatorDefault, (const UInt8*)&g_st, sizeof(g_st));
                *outSize = sizeof(CFDataRef);
                return 0;
            }
            case kSL4PropUnsolQueue: {
                pthread_mutex_lock(&g_unsol_mtx);
                uint32_t count = g_unsol_w - g_unsol_r;
                if (count > UNSOL_Q_MAX) count = UNSOL_Q_MAX;
                CFMutableDataRef md = CFDataCreateMutable(kCFAllocatorDefault, count * 64);
                while (g_unsol_r < g_unsol_w) {
                    CFDataAppendBytes(md, g_unsol_q[g_unsol_r % UNSOL_Q_MAX], 64);
                    g_unsol_r++;
                }
                pthread_mutex_unlock(&g_unsol_mtx);
                *(CFDataRef*)outData = md;
                *outSize = sizeof(CFDataRef);
                return 0;
            }
            case kSL4PropMeters: {
                float peaks[NCH * 2];
                for (int i = 0; i < NCH * 2; i++) {
                    peaks[i] = atomic_exchange_explicit(&g_meter_peaks[i], 0.0f, memory_order_relaxed);
                }
                *(CFDataRef*)outData = CFDataCreate(kCFAllocatorDefault, (const UInt8*)peaks, sizeof(peaks));
                *outSize = sizeof(CFDataRef);
                return 0;
            }
        }
    }

    if (oid == kObjStreamIn || oid == kObjStreamOut) {
        switch (s) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID*)outData = kAudioObjectClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyClass: *(AudioClassID*)outData = kAudioStreamClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner: *(AudioObjectID*)outData = kObjDevice; *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyName:
                *(CFStringRef*)outData = (oid == kObjStreamIn) ? CFSTR("SL 4 Input Stream") : CFSTR("SL 4 Output Stream");
                *outSize = sizeof(CFStringRef); return 0;
            case kAudioStreamPropertyIsActive: *(UInt32*)outData = 1; *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyDirection: *(UInt32*)outData = (oid == kObjStreamIn) ? 1 : 0; *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyTerminalType:
                *(UInt32*)outData = (oid == kObjStreamIn) ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeSpeaker;
                *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyStartingChannel: *(UInt32*)outData = 1; *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyLatency:
                *(UInt32*)outData = (oid == kObjStreamIn)
                                  ? (UInt32)llround(LAT_IN_44 * g_sr / 44100.0)
                                  : (UInt32)llround(LAT_OUT_44 * g_sr / 44100.0);
                *outSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                fill_asbd((AudioStreamBasicDescription*)outData, g_sr);
                *outSize = sizeof(AudioStreamBasicDescription);
                return 0;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                AudioStreamRangedDescription *rd = (AudioStreamRangedDescription*)outData;
                fill_asbd(&rd[0].mFormat, 44100.0);
                rd[0].mSampleRateRange.mMinimum = 44100.0; rd[0].mSampleRateRange.mMaximum = 44100.0;
                fill_asbd(&rd[1].mFormat, 48000.0);
                rd[1].mSampleRateRange.mMinimum = 48000.0; rd[1].mSampleRateRange.mMaximum = 48000.0;
                *outSize = 2 * sizeof(AudioStreamRangedDescription);
                return 0;
            }
        }
    }

    int vidx = vol_idx_for_obj(oid);
    if (vidx >= 0) {
        switch (s) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID*)outData = kAudioLevelControlClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyClass: *(AudioClassID*)outData = kAudioVolumeControlClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner: *(AudioObjectID*)outData = kObjDevice; *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
            case kAudioControlPropertyScope: *(UInt32*)outData = kAudioObjectPropertyScopeOutput; *outSize = sizeof(UInt32); return 0;
            case kAudioControlPropertyElement: *(UInt32*)outData = (UInt32)vidx; *outSize = sizeof(UInt32); return 0;
            case kAudioLevelControlPropertyScalarValue:
                *(Float32*)outData = atomic_load_explicit(&g_vol_scalar[vidx], memory_order_relaxed);
                *outSize = sizeof(Float32); return 0;
            case kAudioLevelControlPropertyDecibelValue:
                *(Float32*)outData = vol_scalar_to_db(atomic_load_explicit(&g_vol_scalar[vidx], memory_order_relaxed));
                *outSize = sizeof(Float32); return 0;
            case kAudioLevelControlPropertyDecibelRange: {
                AudioValueRange *r = (AudioValueRange*)outData;
                r->mMinimum = VOL_MIN_DB; r->mMaximum = VOL_MAX_DB;
                *outSize = sizeof(AudioValueRange); return 0;
            }
            case kAudioLevelControlPropertyConvertScalarToDecibels:
                *(Float32*)outData = vol_scalar_to_db(*(Float32*)outData);
                *outSize = sizeof(Float32); return 0;
            case kAudioLevelControlPropertyConvertDecibelsToScalar:
                *(Float32*)outData = vol_db_to_scalar(*(Float32*)outData);
                *outSize = sizeof(Float32); return 0;
        }
    }

    if (oid == kObjMute) {
        switch (s) {
            case kAudioObjectPropertyBaseClass: *(AudioClassID*)outData = kAudioBooleanControlClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyClass: *(AudioClassID*)outData = kAudioMuteControlClassID; *outSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner: *(AudioObjectID*)outData = kObjDevice; *outSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
            case kAudioControlPropertyScope: *(UInt32*)outData = kAudioObjectPropertyScopeOutput; *outSize = sizeof(UInt32); return 0;
            case kAudioControlPropertyElement: *(UInt32*)outData = kAudioObjectPropertyElementMain; *outSize = sizeof(UInt32); return 0;
            case kAudioBooleanControlPropertyValue:
                *(UInt32*)outData = atomic_load_explicit(&g_vol_mute, memory_order_relaxed);
                *outSize = sizeof(UInt32); return 0;
        }
    }

    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SL4_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID oid, pid_t pid, const AudioObjectPropertyAddress *addr, UInt32 qsz, const void *qd, UInt32 inSize, const void *inData) {
    (void)d; (void)pid; (void)qsz; (void)qd;
    if (oid == kObjDevice && addr->mSelector == kSL4PropHIDCommand) {
        if (inSize == sizeof(CFDataRef) && inData) {
            CFDataRef cd = *(CFDataRef*)inData;
            if (cd && CFGetTypeID(cd) == CFDataGetTypeID() && CFDataGetLength(cd) <= 64) {
                pthread_mutex_lock(&g_mutex);
                memset(g_last_cmd_in, 0, 64);
                memcpy(g_last_cmd_in, CFDataGetBytePtr(cd), CFDataGetLength(cd));
                if (g_last_cmd_in[0] == 0x31 && CFDataGetLength(cd) >= 7) {
                    int sr = (g_last_cmd_in[5] << 8) | g_last_cmd_in[6];
                    if (sr == 44100 || sr == 48000) {
                        g_sr = (Float64)sr;
                        push_sr_unsol(sr);
                    }
                }
                usb_ensure_hid();
                memset(g_last_cmd_reply, 0, 64);
                uint32_t seq_in = 0;
                memcpy(&seq_in, g_last_cmd_in + 1, 4);
                hid_cmd(g_last_cmd_in[0], g_last_cmd_in + 5, 59, g_last_cmd_reply, seq_in ? &seq_in : NULL);
                pthread_mutex_unlock(&g_mutex);
            }
        }
        return 0;
    }
    if (oid == kObjDevice && addr->mSelector == kAudioDevicePropertyNominalSampleRate) {
        Float64 v = *(const Float64*)inData;
        if (v == 44100.0 || v == 48000.0) {
            atomic_store(&g_pending_sr, (int)v);
            if (g_host) {
                g_host->RequestDeviceConfigurationChange(g_host, kObjDevice, 1, NULL);
            } else {
                apply_sample_rate_change((int)v);
            }
        }
        return 0;
    }
    if ((oid == kObjStreamIn || oid == kObjStreamOut) &&
        (addr->mSelector == kAudioStreamPropertyVirtualFormat || addr->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        const AudioStreamBasicDescription *a = (const AudioStreamBasicDescription*)inData;
        if (a->mSampleRate == 44100.0 || a->mSampleRate == 48000.0) {
            atomic_store(&g_pending_sr, (int)a->mSampleRate);
            if (g_host) {
                g_host->RequestDeviceConfigurationChange(g_host, kObjDevice, 1, NULL);
            } else {
                apply_sample_rate_change((int)a->mSampleRate);
            }
        }
        return 0;
    }
    int vidx = vol_idx_for_obj(oid);
    if (vidx >= 0) {
        if (inSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 val = *(const Float32*)inData;
        Float32 sc = (addr->mSelector == kAudioLevelControlPropertyDecibelValue)
                   ? vol_db_to_scalar(val)
                   : (val < 0.0f ? 0.0f : (val > 1.0f ? 1.0f : val));
        atomic_store_explicit(&g_vol_scalar[vidx], sc, memory_order_relaxed);
        if (g_host) {
            AudioObjectPropertyAddress ca[2] = {
                { kAudioLevelControlPropertyScalarValue,  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
            };
            g_host->PropertiesChanged(g_host, oid, 2, ca);
        }
        return 0;
    }
    if (oid == kObjMute && addr->mSelector == kAudioBooleanControlPropertyValue) {
        if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        UInt32 m = (*(const UInt32*)inData) ? 1 : 0;
        atomic_store_explicit(&g_vol_mute, m, memory_order_relaxed);
        if (g_host) {
            AudioObjectPropertyAddress ca = { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            g_host->PropertiesChanged(g_host, kObjMute, 1, &ca);
        }
        return 0;
    }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SL4_StartIO(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid) {
    (void)d; (void)oid; (void)cid;
    pthread_mutex_lock(&g_mutex);
    if (g_io_clients == 0) {
        if (!usb_open_all()) {
            double nom = ((1e9 / g_sr) * (double)g_tb.denom) / (double)g_tb.numer;
            atomic_store(&g_ticks_per_frame, nom);
            atomic_store(&g_anchor_host, mach_absolute_time());
            atomic_store(&g_total_cap_frames, 0);
            atomic_store(&g_total_play_frames, 0);
        }
    }
    g_io_clients++;
    pthread_mutex_unlock(&g_mutex);
    return 0;
}

static OSStatus SL4_StopIO(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid) {
    (void)d; (void)oid; (void)cid;
    pthread_mutex_lock(&g_mutex);
    if (g_io_clients > 0) {
        g_io_clients--;
        if (g_io_clients == 0) usb_stop_streaming();
    }
    pthread_mutex_unlock(&g_mutex);
    return 0;
}

static OSStatus SL4_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)d; (void)oid; (void)cid;
    uint64_t anchor = atomic_load_explicit(&g_anchor_host, memory_order_acquire);
    double tpf = atomic_load_explicit(&g_ticks_per_frame, memory_order_relaxed);
    if (anchor == 0 || tpf <= 0) {
        anchor = mach_absolute_time();
        tpf = ((1e9 / g_sr) * (double)g_tb.denom) / (double)g_tb.numer;
    }
    uint64_t now = mach_absolute_time();
    double period_ticks = (double)ZTS_PERIOD * tpf;
    uint64_t periods = (now > anchor) ? (uint64_t)((double)(now - anchor) / period_ticks) : 0;

    *outSampleTime = (Float64)(periods * (uint64_t)ZTS_PERIOD);
    *outHostTime   = anchor + (uint64_t)((double)periods * period_ticks);
    *outSeed       = 1;
    return 0;
}

static OSStatus SL4_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid, UInt32 op, Boolean *outWillDo, Boolean *outIsInPlace) {
    (void)d; (void)oid; (void)cid;
    *outIsInPlace = true;
    *outWillDo = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix);
    return 0;
}

static OSStatus SL4_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) { (void)d; (void)oid; (void)cid; (void)op; (void)frames; (void)ci; return 0; }

static OSStatus SL4_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID oid, AudioObjectID sid, UInt32 cid, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci, void *ioMain, void *ioSec) {
    (void)d; (void)oid; (void)sid; (void)cid; (void)ioSec;
    float *buf = (float*)ioMain;
    if (op == kAudioServerPlugInIOOperationReadInput) {
        uint64_t pos = (uint64_t)llround(ci->mInputTime.mSampleTime);
        for (UInt32 f = 0; f < frames; f++) {
            uint32_t idx = ((uint32_t)((pos + f) & RING_MASK)) * NCH;
            memcpy(buf + f * NCH, &g_in_ring[idx], NCH * sizeof(float));
        }
    } else if (op == kAudioServerPlugInIOOperationWriteMix) {
        uint64_t pos = (uint64_t)llround(ci->mOutputTime.mSampleTime);
        for (UInt32 f = 0; f < frames; f++) {
            float fr[NCH];
            memcpy(fr, buf + f * NCH, NCH * sizeof(float));
            vol_apply_frame(fr);
            meter_update(NCH, fr);
            uint32_t idx = ((uint32_t)((pos + f) & RING_MASK)) * NCH;
            memcpy(&g_out_ring[idx], fr, NCH * sizeof(float));
            if (atomic_load_explicit(&g_dp_active, memory_order_relaxed)) {
                atomic_fetch_add_explicit(&g_dp_writers, 1, memory_order_acquire);
                if (atomic_load_explicit(&g_dp_active, memory_order_relaxed))
                    dp_write_frame(pos + f, fr);
                atomic_fetch_sub_explicit(&g_dp_writers, 1, memory_order_release);
            }
        }
    }
    return 0;
}

static OSStatus SL4_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID oid, UInt32 cid, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *ci) { (void)d; (void)oid; (void)cid; (void)op; (void)frames; (void)ci; return 0; }

static AudioServerPlugInDriverInterface g_interface = {
    NULL,
    SL4_QueryInterface,
    SL4_AddRef,
    SL4_Release,
    SL4_Initialize,
    SL4_CreateDevice,
    SL4_DestroyDevice,
    SL4_AddDeviceClient,
    SL4_RemoveDeviceClient,
    SL4_PerformDeviceConfigurationChange,
    SL4_AbortDeviceConfigurationChange,
    SL4_HasProperty,
    SL4_IsPropertySettable,
    SL4_GetPropertyDataSize,
    SL4_GetPropertyData,
    SL4_SetPropertyData,
    SL4_StartIO,
    SL4_StopIO,
    SL4_GetZeroTimeStamp,
    SL4_WillDoIOOperation,
    SL4_BeginIOOperation,
    SL4_DoIOOperation,
    SL4_EndIOOperation
};

static AudioServerPlugInDriverInterface *g_driver_ptr = &g_interface;

__attribute__((visibility("default")))
void* SL4Device_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return &g_driver_ptr;
    }
    return NULL;
}
