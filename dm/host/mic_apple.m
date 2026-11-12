// The device's microphone for nn::audio's input streams (mic_apple.h): AVAudioEngine's input node, converted to 48 kHz mono PCM16 into a ring that hle_audio.c's streams read
#import "mic_apple.h"
#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include "dm.h"

static int16_t g_ring[DM_MIC_RING];
static _Atomic uint64_t g_head;   // frames written; the writer is the input tap's thread alone
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_users;               // started streams
static AVAudioEngine *g_engine;
static AVAudioConverter *g_conv;
static AVAudioFormat *g_out;      // 48 kHz mono float32: the converter's output, written into the ring as PCM16

int dm_mic_wanted(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_MIC"); v = e && atoi(e) != 0; } return v; }

// The app must say why it asks for the microphone: without NSMicrophoneUsageDescription the system ends a process that touches it (a test binary, a Mac app packed without it)
static int mic_described(void) { return [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSMicrophoneUsageDescription"] != nil; }

int dm_mic_available(void) {
    if (!dm_mic_wanted() || !mic_described()) return 0;
    if (@available(iOS 17.0, macOS 14.0, *)) return AVAudioApplication.sharedInstance.recordPermission != AVAudioApplicationRecordPermissionDenied;   // undecided: asked at the first start
    return 1;
}

void dm_mic_prepare(void) {
    if (!dm_mic_wanted() || !mic_described()) { if (dm_mic_wanted()) LOG("[RED] microphone: DM_MIC is on but the app has no microphone usage description: the game gets no input device"); return; }
    if (@available(iOS 17.0, macOS 14.0, *)) {
        if (AVAudioApplication.sharedInstance.recordPermission != AVAudioApplicationRecordPermissionUndetermined) {
            LOG("microphone: permission %s", AVAudioApplication.sharedInstance.recordPermission == AVAudioApplicationRecordPermissionGranted ? "granted" : "refused (Settings > Privacy > Microphone)"); return; }
        [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted) { LOG("microphone: permission %s", granted ? "granted" : "refused"); }];
    }
}

static void mic_write(const float *s, uint32_t n) {   // the tap's thread
    uint64_t h = atomic_load_explicit(&g_head, memory_order_relaxed);
    for (uint32_t i = 0; i < n; i++) { float v = s[i] * 32767.0f; g_ring[(h + i) & (DM_MIC_RING - 1)] = (int16_t)(v > 32767.0f ? 32767 : v < -32768.0f ? -32768 : v); }
    atomic_store_explicit(&g_head, h + n, memory_order_release);
}

static int mic_start(void) {   // g_mu held
    AVAudioEngine *e = [AVAudioEngine new];
    AVAudioInputNode *in = e.inputNode;
    AVAudioFormat *hw = [in outputFormatForBus:0];
    if (!hw || hw.sampleRate <= 0 || hw.channelCount == 0) { LOG("[RED] microphone: no input (the device has none, or the audio session cannot record)"); return 0; }
    g_out = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:DM_MIC_RATE channels:1 interleaved:NO];
    g_conv = [[AVAudioConverter alloc] initFromFormat:hw toFormat:g_out];
    if (!g_conv) { LOG("[RED] microphone: no converter from %.0f Hz x%u to 48 kHz mono", hw.sampleRate, (unsigned)hw.channelCount); return 0; }
    AVAudioConverter *conv = g_conv; AVAudioFormat *out = g_out;
    [in installTapOnBus:0 bufferSize:1024 format:hw block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        (void)when;
        AVAudioFrameCount cap = (AVAudioFrameCount)((double)buf.frameLength * DM_MIC_RATE / hw.sampleRate) + 16;
        AVAudioPCMBuffer *o = [[AVAudioPCMBuffer alloc] initWithPCMFormat:out frameCapacity:cap];
        __block BOOL given = NO;
        NSError *err = nil;
        [conv convertToBuffer:o error:&err withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *status) {
            (void)count; if (given) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
            given = YES; *status = AVAudioConverterInputStatus_HaveData; return buf; }];
        if (o.frameLength && o.floatChannelData) mic_write(o.floatChannelData[0], o.frameLength);
    }];
    NSError *err = nil;
    [e prepare];
    if (![e startAndReturnError:&err]) { [in removeTapOnBus:0]; LOG("[RED] microphone: the capture did not start: %s", err.localizedDescription.UTF8String); return 0; }
    g_engine = e;
    LOG("microphone: capturing (%.0f Hz x%u into 48 kHz mono PCM16)", hw.sampleRate, (unsigned)hw.channelCount);
    return 1;
}

int dm_mic_retain(void) {
    if (!dm_mic_available()) return 0;
    pthread_mutex_lock(&g_mu);
    int ok = g_users > 0 || mic_start();
    if (ok) g_users++;
    pthread_mutex_unlock(&g_mu);
    return ok;
}

void dm_mic_release(void) {
    pthread_mutex_lock(&g_mu);
    if (g_users > 0 && --g_users == 0 && g_engine) {
        [g_engine.inputNode removeTapOnBus:0]; [g_engine stop]; g_engine = nil; g_conv = nil;
        LOG("microphone: stopped");
    }
    pthread_mutex_unlock(&g_mu);
}

uint64_t dm_mic_head(void) { return atomic_load_explicit(&g_head, memory_order_acquire); }

int dm_mic_copy(uint64_t from, int16_t *dst, int n) {
    uint64_t h = dm_mic_head();
    if (from > h || h - from > DM_MIC_RING) return 0;
    if ((uint64_t)n > h - from) n = (int)(h - from);
    for (int i = 0; i < n; i++) dst[i] = g_ring[(from + i) & (DM_MIC_RING - 1)];
    return n;
}
