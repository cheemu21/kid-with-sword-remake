// Opt-in player builds ignore saved diagnostic overrides while retaining the
// FPS/HUD, controller, language and normal launcher settings. The game profile
// and bundle still supply the renderer's required paths and compatibility keys.
#pragma once
#include <string.h>
static inline int dm_player_diagnostic_key(const char *key) {
    // Encoding placement changes scheduling, not diagnostics or launcher state.
    if(!strcmp(key,"DM_NVN_ENC_THREAD"))return 0;
    // Memory tuning a player may set in Documents/env.txt (L7.2): the texture saver's levels and the upload batch budget
    if(!strcmp(key,"DM_NVN_TEX_MIP_LEVELS")||!strcmp(key,"DM_NVN_UP_BATCH_MB")||!strcmp(key,"DM_NVN_PREREAD")||!strcmp(key,"DM_NVN_RES_TRICKLE_MB")||!strcmp(key,"DM_NVN_DEPTH_EQ_BIAS"))return 0;
    // Draw diagnostics a player can be asked to turn on in Documents/env.txt (L7.9 test: a mod's body that vanishes on some starts): solid colour, no depth test, a dump of a frame's draws
    if(!strcmp(key,"DM_NVN_HILITE")||!strcmp(key,"DM_NVN_DEPTHOVR")||!strcmp(key,"DM_NVN_PASSDUMP")||!strcmp(key,"DM_NVN_ATEST_OFF"))return 0;
    static const char *const prefixes[]={"DM_NVN_","DM_TEST_","MTL_DEBUG_","MTL_SHADER_VALIDATION"};
    for(unsigned i=0;i<sizeof prefixes/sizeof *prefixes;i++)
        if(!strncmp(key,prefixes[i],strlen(prefixes[i])))return 1;
    static const char *const names[]={"DM_CTL","DM_KEYS","DM_KBD","DM_DETCLOCK","DM_SLOWFRAME","DM_PROBE","DM_MSL_DIR"};
    for(unsigned i=0;i<sizeof names/sizeof *names;i++)if(!strcmp(key,names[i]))return 1;
    return 0;
}
