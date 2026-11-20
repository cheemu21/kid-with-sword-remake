// mic_level.h unit test: the microphone's voice leveler on 48 kHz signals made here (a tone for humming or whistling, white noise for the room), read back through a model of Ocarina of
// Time's note gate (main+0x336e000: the RMS of each 512-frame PCM16 block in dBFS, main+0x336f090; a note starts at -32 dBFS on the main microphone). A quiet hum over a quiet room
// crosses the gate with the leveler and not without; the room alone, a hum lost in a noisy room, digital silence and a loud whistle pass untouched; a held note stays boosted; a
// background that rises (music, a fan) stops being boosted within the 2 s window; high reaches a hum that normal does not; off changes nothing
#include "../mic_level.h"
#include <stdio.h>
#include <stdlib.h>

enum { RATE = 48000, GAME_BLOCK = 512 };
#define GAME_GATE_DB (-32.0f)
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; printf("FAIL: %s\n", label); } } while (0)

static uint32_t rng = 12345;
static float noise(void) { rng = rng * 1664525u + 1013904223u; return ((float)(rng >> 8) / 8388608.0f - 1.0f) * 1.7320508f; }   // uniform, unit RMS
static float db_to_amp(float db) { return powf(10.0f, db / 20.0f); }

// A signal of segments: each so many seconds of a tone (RMS dBFS, or none) over noise (RMS dBFS, or none: digital silence)
typedef struct { float sec, tone_db, noise_db, hz; } seg;
#define NONE (-999.0f)
static float *make(const seg *sg, int nsg, int *len) {
    int n = 0; for (int i = 0; i < nsg; i++) n += (int)(sg[i].sec * RATE);
    float *s = calloc((size_t)n, sizeof *s); int k = 0; double ph = 0;
    for (int i = 0; i < nsg; i++) for (int j = 0; j < (int)(sg[i].sec * RATE); j++, k++) {
        float v = 0;
        if (sg[i].tone_db > NONE) { v += db_to_amp(sg[i].tone_db) * 1.4142136f * (float)sin(ph); ph += 2 * M_PI * sg[i].hz / RATE; }
        if (sg[i].noise_db > NONE) v += db_to_amp(sg[i].noise_db) * noise();
        s[k] = v;
    }
    *len = n; return s;
}
static void run(float *s, int n, const char *preset) {   // the capture's buffers: 1024 frames at a time, as the input tap gives them
    mic_level m; float b, g; mic_level_preset(preset, &b, &g); mic_level_init(&m, b, g);
    for (int i = 0; i < n; i += 1024) mic_level_run(&m, s + i, n - i < 1024 ? n - i : 1024);
}
// The game's level of its block holding frame `at` (PCM16 as mic_apple.m writes it, then RMS / 32768)
static float game_db(const float *s, int n, int at) {
    int b0 = at / GAME_BLOCK * GAME_BLOCK; double acc = 0;
    if (b0 + GAME_BLOCK > n) b0 = n - GAME_BLOCK;
    for (int i = b0; i < b0 + GAME_BLOCK; i++) { float v = s[i] * 32767.0f; int q = (int)(v > 32767 ? 32767 : v < -32768 ? -32768 : v); acc += (double)q * q; }
    double r = sqrt(acc / GAME_BLOCK) / 32768.0; return r > 0 ? 20.0f * (float)log10(r) : -200.0f;
}
// The share of the game's blocks between two times (s) that reach the gate, and the loudest of them
static float share_over(const float *s, int n, float t0, float t1, float *loudest) {
    int a = (int)(t0 * RATE) / GAME_BLOCK, z = (int)(t1 * RATE) / GAME_BLOCK, over = 0; *loudest = -200;
    for (int b = a; b < z; b++) { float d = game_db(s, n, b * GAME_BLOCK); over += d >= GAME_GATE_DB; if (d > *loudest) *loudest = d; }
    return z > a ? (float)over / (float)(z - a) : 0;
}
static int same(const float *a, const float *b, int n) { return !memcmp(a, b, (size_t)n * sizeof *a); }

int main(void) {
    float lo;
    {   // a quiet hum (-45 dBFS, 220 Hz) for 0.6 s in a quiet room (-62 dBFS)
        seg sg[] = {{1.0f, NONE, -62, 0}, {0.6f, -45, -62, 220}, {1.0f, NONE, -62, 0}}; int n;
        float *raw = make(sg, 3, &n), *s = malloc((size_t)n * sizeof *s); memcpy(s, raw, (size_t)n * sizeof *s);
        CHECK("without the leveler the game misses the hum", share_over(raw, n, 1.0f, 1.6f, &lo) == 0);
        run(s, n, "normal");
        CHECK("with it the game hears the hum from 20 ms on", share_over(s, n, 1.02f, 1.6f, &lo) == 1.0f);
        CHECK("brought near -20 dBFS and no further", lo < -19.0f && lo > -23.0f);
        CHECK("the room before it stays under the game's release level (-52)", share_over(s, n, 0, 1.0f, &lo) == 0 && lo < -52.0f);
        CHECK("and the room after it, from 10 ms on", share_over(s, n, 1.611f, 2.6f, &lo) == 0 && lo < -52.0f);
        CHECK("nothing clipped", ({ int ok = 1; for (int i = 0; i < n; i++) ok &= fabsf(s[i]) < 0.5f; ok; }));
        free(raw); free(s);
    }
    {   // a whistle (1.2 kHz) held 1.5 s: still boosted at its end (the background does not climb onto it)
        seg sg[] = {{1.0f, NONE, -60, 0}, {1.5f, -42, -60, 1200}, {0.5f, NONE, -60, 0}}; int n;
        float *s = make(sg, 3, &n); run(s, n, "normal");
        CHECK("a held whistle stays boosted to its end", share_over(s, n, 1.02f, 2.5f, &lo) == 1.0f);
        free(s);
    }
    {   // a noisy room (-40 dBFS) and a hum only 4 dB over it: not boosted, the samples as captured
        seg sg[] = {{1.0f, NONE, -40, 0}, {0.6f, -36, -40, 220}, {0.5f, NONE, -40, 0}}; int n;
        float *raw = make(sg, 3, &n), *s = malloc((size_t)n * sizeof *s); memcpy(s, raw, (size_t)n * sizeof *s);
        run(s, n, "normal");
        CHECK("a hum within the margin over a noisy room is left as it is", same(raw, s, n));
        free(raw); free(s);
    }
    {   // a loud whistle (-15 dBFS) is never turned down
        seg sg[] = {{0.5f, NONE, -60, 0}, {0.5f, -15, -60, 1500}}; int n;
        float *raw = make(sg, 2, &n), *s = malloc((size_t)n * sizeof *s); memcpy(s, raw, (size_t)n * sizeof *s);
        run(s, n, "normal");
        CHECK("a loud whistle passes untouched", same(raw, s, n));
        free(raw); free(s);
    }
    {   // music that starts and stays (-45 dBFS of noise over a -65 dBFS room) stops being boosted within the 2 s window
        seg sg[] = {{1.0f, NONE, -65, 0}, {4.0f, NONE, -45, 0}}; int n;
        float *raw = make(sg, 2, &n), *s = malloc((size_t)n * sizeof *s); memcpy(s, raw, (size_t)n * sizeof *s);
        run(s, n, "normal");
        int from = (int)(3.3f * RATE);
        CHECK("a background that stays is learned within the window", same(raw + from, s + from, n - from));
        free(raw); free(s);
    }
    {   // the capture's first buffers are digital silence: the room after them is not boosted
        seg sg[] = {{0.1f, NONE, NONE, 0}, {1.0f, NONE, -60, 0}}; int n;
        float *raw = make(sg, 2, &n), *s = malloc((size_t)n * sizeof *s); memcpy(s, raw, (size_t)n * sizeof *s);
        run(s, n, "normal");
        CHECK("silence first, then the room: the room passes untouched", same(raw, s, n));
        free(raw); free(s);
    }
    {   // high reaches a hum normal does not (-60 dBFS over a -75 dBFS room); off leaves everything as captured
        seg sg[] = {{1.0f, NONE, -75, 0}, {0.6f, -60, -75, 330}, {0.5f, NONE, -75, 0}}; int n;
        float *raw = make(sg, 3, &n), *s = malloc((size_t)n * sizeof *s);
        memcpy(s, raw, (size_t)n * sizeof *s); run(s, n, "normal");
        CHECK("normal: a -60 dBFS hum stays under the gate", share_over(s, n, 1.02f, 1.6f, &lo) == 0);
        memcpy(s, raw, (size_t)n * sizeof *s); run(s, n, "high");
        CHECK("high: the game hears it", share_over(s, n, 1.02f, 1.6f, &lo) == 1.0f);
        CHECK("high: the room stays under -52", share_over(s, n, 0, 1.0f, &lo) == 0 && lo < -52.0f);
        memcpy(s, raw, (size_t)n * sizeof *s); run(s, n, "off");
        CHECK("off: the samples as captured", same(raw, s, n));
        free(raw); free(s);
    }
    {   // the setting's values
        float b, g;
        CHECK("unset is normal", mic_level_preset(NULL, &b, &g) && !strcmp(mic_level_preset(NULL, &b, &g), "normal") && b == 24 && g == 12);
        CHECK("high", !strcmp(mic_level_preset("high", &b, &g), "high") && b == 36 && g == 8);
        CHECK("off boosts nothing", !strcmp(mic_level_preset("off", &b, &g), "off") && b == 0);
        CHECK("another value is reported, and normal", mic_level_preset("loud", &b, &g) == NULL && b == 24);
    }
    printf("t_mic_level: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
