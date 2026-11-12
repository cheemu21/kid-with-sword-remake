// The device's microphone for a game's audio input streams (hle_audio.c, nn::audio's InputStream): 48 kHz mono PCM16 in a ring the capture fills and each open stream reads with a
// cursor of its own. The Legend of Zelda: Ocarina of Time (Switch 2) plays its ocarina by voice through two such streams. DM_MIC=1 (the iOS launcher's Microphone row) offers the
// microphone to the game; without it, or without permission or an app usage description, the host lists no input device as before
#pragma once
#include <stdint.h>

enum { DM_MIC_RATE = 48000, DM_MIC_RING = 1 << 16 };   // frames kept: about 1.4 s
int dm_mic_wanted(void);       // DM_MIC is on
int dm_mic_available(void);    // wanted, the app may ask for the microphone (its usage description) and the user has not refused it
void dm_mic_prepare(void);     // ask for the permission early (the iOS front end's audio session setup), so the game's first listing finds it decided
int dm_mic_retain(void);       // a stream started: capture runs while any is (0 when it cannot start)
void dm_mic_release(void);
uint64_t dm_mic_head(void);    // frames captured so far
int dm_mic_copy(uint64_t from, int16_t *dst, int n);   // n frames from frame `from` on (at most DM_MIC_RING behind the head); the frames copied
