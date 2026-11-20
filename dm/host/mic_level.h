// The microphone's voice leveler: mic_apple.m runs it on the capture (48 kHz mono float) before the game's input streams read it, so quiet humming and whistling reach the level a game's
// own voice detection waits for. The Legend of Zelda: Ocarina of Time (0400486024DEC000, v131072) measures the RMS of each 512-frame block in dBFS (main+0x336f090) and starts a note when
// that crosses a fixed -32 dBFS on the main microphone (releasing at -52), or 3-20 dB over a background it learns on the true raw device (main+0x336e000; its flag, main+0xf480c0's
// second argument, picks the stream). The Switch 2's microphones meet a fixed -32 dBFS at a normal distance; the iPhone's and the Mac's built-in ones, read at unity gain, left quiet
// humming well under it. The leveler learns the background as the quietest 5 ms block of the last 2 s (minimum statistics: a held note does not lift it, a fan or music that stays does
// within 2 s), and only a block that stands a margin over it, two blocks running, is boosted toward -20 dBFS by at most the preset's boost; everything else, the background included,
// passes at unity, and a loud signal is never turned down. The gain for a block follows the level of the block before it (causal), ramped across the block. Pure C: t_mic_level tests it
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>

enum {
    MIC_LEVEL_BLOCK = 240,   // 5 ms at 48 kHz: the leveler measures and decides once a block
    MIC_LEVEL_SUB = 50,      // blocks to a part of the background's window (250 ms)
    MIC_LEVEL_PARTS = 8,     // the background's window: 8 parts, 2 s
    MIC_LEVEL_OPEN = 2,      // blocks over the threshold, running, before the gate opens (10 ms: a click is not boosted)
};
#define MIC_LEVEL_TARGET_DB (-20.0f)   // where a boosted block is brought: 12 dB over Ocarina of Time's note gate, a whistle's peaks still 17 dB under full scale
#define MIC_LEVEL_CLOSE_DB 4.0f        // hysteresis: an open gate closes once a block falls this far under the opening threshold
#define MIC_LEVEL_SILENT_DB (-100.0f)  // a block this quiet is digital silence (the capture's first buffers): it teaches the background nothing

typedef struct {
    float boost_db, margin_db;         // the most a block is raised; how far over the background it must be. 0 boost: the leveler is off and passes the samples untouched
    float floor_db;                    // the background: the quietest block of the window (INFINITY until a block was heard)
    float part_min[MIC_LEVEL_PARTS]; int part, part_n;
    float gain, gain_to, step;         // linear gain applied now, the gain the current block ramps to, and the change per sample
    double acc; int n;                 // the block being measured (input, before the gain)
    int above, open;
    float loudest_db; uint32_t blocks, boosted;   // since the last mic_level_take_stats
} mic_level;

// DM_MIC_BOOST, the launcher's Mic Sensitivity: off (the samples as captured, as before the leveler), normal (the default) or high. NULL for another value (the caller says so; normal)
static inline const char *mic_level_preset(const char *v, float *boost_db, float *margin_db) {
    if (v && !strcmp(v, "off")) { *boost_db = 0; *margin_db = 0; return "off"; }
    if (v && !strcmp(v, "high")) { *boost_db = 36; *margin_db = 8; return "high"; }
    *boost_db = 24; *margin_db = 12;
    return !v || !*v || !strcmp(v, "normal") ? "normal" : NULL;
}

static inline void mic_level_init(mic_level *m, float boost_db, float margin_db) {
    memset(m, 0, sizeof *m);
    m->boost_db = boost_db; m->margin_db = margin_db;
    m->floor_db = INFINITY; m->gain = m->gain_to = 1.0f; m->loudest_db = -INFINITY;
    for (int i = 0; i < MIC_LEVEL_PARTS; i++) m->part_min[i] = INFINITY;
}

static inline void mic_level_decide(mic_level *m, float db) {   // one block measured: the background, the gate, and the gain for the next block
    if (db > MIC_LEVEL_SILENT_DB) {
        if (db < m->part_min[m->part]) m->part_min[m->part] = db;
        if (++m->part_n == MIC_LEVEL_SUB) { m->part = (m->part + 1) % MIC_LEVEL_PARTS; m->part_min[m->part] = INFINITY; m->part_n = 0; }   // the oldest part leaves the window
        float f = INFINITY;
        for (int i = 0; i < MIC_LEVEL_PARTS; i++) if (m->part_min[i] < f) f = m->part_min[i];
        m->floor_db = f;
    }
    float thr = m->floor_db + m->margin_db;
    int heard = db > MIC_LEVEL_SILENT_DB && m->floor_db < INFINITY;
    m->above = heard && db >= thr ? m->above + 1 : 0;
    m->open = m->open ? heard && db >= thr - MIC_LEVEL_CLOSE_DB : m->above >= MIC_LEVEL_OPEN;
    float g_db = 0;
    if (m->open) { g_db = MIC_LEVEL_TARGET_DB - db; if (g_db > m->boost_db) g_db = m->boost_db; if (g_db < 0) g_db = 0; }
    m->gain_to = g_db == 0 ? 1.0f : powf(10.0f, g_db / 20.0f);
    m->step = (m->gain_to - m->gain) / MIC_LEVEL_BLOCK;
    m->blocks++; m->boosted += m->open && g_db > 0;
    if (db > m->loudest_db) m->loudest_db = db;
}

static inline void mic_level_run(mic_level *m, float *s, int n) {   // in place
    if (m->boost_db <= 0) return;
    for (int i = 0; i < n; i++) {
        float x = s[i];
        m->acc += (double)x * x;
        if (m->gain != 1.0f || m->step != 0) { float y = x * m->gain; s[i] = y > 1.0f ? 1.0f : y < -1.0f ? -1.0f : y; m->gain += m->step; }
        if (++m->n == MIC_LEVEL_BLOCK) {
            double ms = m->acc / MIC_LEVEL_BLOCK;
            m->acc = 0; m->n = 0; m->gain = m->gain_to;
            mic_level_decide(m, ms > 0 ? (float)(10.0 * log10(ms)) : -200.0f);
        }
    }
}

// What the leveler did since the last call (mic_apple.m logs it): blocks measured, blocks boosted, the loudest block, the background now
static inline void mic_level_take_stats(mic_level *m, uint32_t *blocks, uint32_t *boosted, float *loudest_db, float *floor_db) {
    *blocks = m->blocks; *boosted = m->boosted; *loudest_db = m->loudest_db; *floor_db = m->floor_db;
    m->blocks = m->boosted = 0; m->loudest_db = -INFINITY;
}
