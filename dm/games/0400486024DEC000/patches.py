# The Legend of Zelda: Ocarina of Time (0400486024DEC000): the rewriter's patches of this game's own code. dm/tools/patch_nso.py loads every profile's patches.py;
# MATCH_FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
from nso_asm import ADRP, B

# The game's frame ratio. Once a frame the function at main+0x6e6be0 (v131072) divides its base rate (60.0, or 30.0 while bit 0 of [x21+0x24f] is set) by the int frame rate at
# [x21+0x2c8] (fdiv s8,s1,s0 at +0xe4) and hands the result to the time object (main+0x3b4e300: ratio at +0x10, 1 / ratio at +0x14, round(60 / ratio) at +0x1c), which the game
# steps by; the frame's own time never enters it, so a frame that takes two vsyncs at rate 60 plays at half speed. The stub gives the ratio the host's step instead: step × base / 60
# (the division's value when the host keeps frames 60 / rate vsyncs), and counts the vsyncs stepped. Until the host has decided a step, and at fps_target 0, the division runs.
# s0 and x16 / x17 are free there (s0 is written again on every path before it is read; the function uses neither x16 nor x17); s1 keeps the base rate.
# Lichii (a GPL emulator; only the fact was taken) found the division (its notes: main+0x6E6CC4, 60 / [x21+0x2C8])
def frame_step(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF, base = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state, ctx.base
    site = base + 0xe4
    fs_site(site, '2818201e')   # fdiv s8,s1,s0
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xb9400211,   # ldr w17,[x16]          target fps (0 = off)
              0x340001b1,   # cbz w17,orig (+13)
              0xb9402211,   # ldr w17,[x16,#0x20]    step in vsyncs
              0x34000171,   # cbz w17,orig (+11)     not decided yet
              0x1e230220,   # ucvtf s0,w17
              0xf9401a10,   # ldr x16,[x16,#0x30]
              0x8b110210):  # add x16,x16,x17
        emit(w)
    emit(ADRP(17, here(), FS_STATE_OFF))
    for w in (0xf9001a30,   # str x16,[x17,#0x30]    vsyncs stepped
              0x1e210808,   # fmul s8,s0,s1          step × base rate
              0x52a84e10,   # mov w16,#0x42700000    60.0
              0x1e270200,   # fmov s0,w16
              0x1e201908):  # fdiv s8,s8,s0          / 60
        emit(w)
    emit(B(here(), site + 4))
    emit(0x1e201828); emit(B(here(), site + 4))   # orig: fdiv s8,s1,s0; back
    fs_put(site, [B(site, start)], 'frame ratio: the host\'s step × base rate / 60 instead of base rate / the game\'s frame rate (state page target fps; 0 = the game\'s ratio)')
    dynamic_resolution(ctx)
    if ctx.base == 0x6e6be0: render_scale(ctx)   # the launcher's Render scale (state +0x10, below): its two sites are fixed addresses verified on v131072 only, where the frame-step function starts here

# The game's dynamic resolution (game__gfx__DynamicResolutionParam: LoadThreshold, ReduceCounterMax, IncreaseCounterMax and a list of levels, each a ResolutionReduceScale and a
# Priority; on v131072 levels 0..9 at 0.75..0.333 of 2048x1152, 1536x864 to 683x384). Its update (main+0x805aa0) reads the frame's GPU load (about 0.2 ms a unit) into +0x8, subtracts
# its small model of the fixed costs and divides the rest by the square of the current scale: it takes the rest of the frame's cost to grow with the pixel count, as on the Switch 2
# its constants were tuned for. The level function (main+0x8065e0) adds that back times each level's scale squared and returns the best level under the threshold (+0x10, 83 = about
# 16.4 ms). On Apple GPUs this game's cost hardly depends on the resolution (mesh, compute and the upscaler's fixed 2048x1152 dominate): 683x384 cost 14.3 ms and 1536x864 14.7 ms on
# an M4 Pro, yet at 683x384 the extrapolation put 1536x864 at about 300 units against the 83 it allows, so the controller sat at its floor for good (game note, Dynamic resolution).
# The stub replaces the level function. With DM_DYNAMIC_RESOLUTION 0 (the default; state +0x40 0) it returns 0: full resolution. With 1 it climbs on what was measured at each
# level, with no model of how the cost grows: one level down when the load (+0x8) has been over the threshold for 8 calls in a row, and that level is marked as not fitting; one level
# up when the load fits and the level above was never measured, fitted when it was last measured, or was measured more than 600 calls (about 10 s) ago; else the current level
# (+0x174). Nothing is decided or recorded until a level has held 8 calls: the load is read a few frames late, so before that it may be the previous level's. The 8 calls over in a
# row keep a single slow frame, or the first frames at a new size (its render targets), from marking a level that fits (on the full library at level 1: one burst to 90 against loads
# of 77-80 at levels 2 and 1). The game's counters still pace the steps (down after ReduceCounterMax frames, up after IncreaseCounterMax); its level count (+0x1a0) is the floor.
# The memory is in the state page: +0x200 calls, +0x204 the last call's level, +0x208 calls at it, +0x20c calls over in a row, +0x210 the load measured at each level (16 floats),
# +0x250 the call it was measured at (0 = never). Run against a model of the update (a level moves after the stub asked 5 times up or 2 times down; the load two frames late): a load
# of 70 at every level climbs from the floor to full size in 9 steps, as does Ocarina's measured 72-80 with a spike every 37 frames and a burst after each change; a load that grows
# with the pixel count settles at the highest level that fits and tries the one above once per 600 calls; a scene that gets lighter climbs again, a heavier one steps down.
# The function is a leaf: x2..x11, x16, x17 and s0..s2 are free, w0 its only result (the original also stores its predicted cost at +0x18, which only it and the update's own
# decision read). The update's fingerprint is required too: +0x8 and +0x174 are its fields
drs_controller = (   # drs_stub.s, assembled with clang; x0 the controller, x16 the state page (the ADRP before it)
    0xb9404211, 0x35000071, 0x2a1f03e0, 0xd65f03c0,                                                   # off (state +0x40 0): level 0
    0xbd400800, 0xbd401001, 0xb9417402, 0xb941a003, 0x7100005f, 0x1a9fa042, 0x528001e9, 0x6b09005f,   # load, threshold, level (0..15), count
    0x1a89d042, 0xb9420204, 0x11000484, 0xb9020204, 0xb9420605, 0xb9420a06, 0x6b0200bf, 0x1a8617e6,   # calls + 1; calls at this level
    0xb9020602, 0xb9020a06, 0x35000046, 0xb9020e1f, 0x91084207, 0x91094208, 0x710020df, 0x5400040b,   # a new level: none over; under 8 calls: stay
    0x1e212000, 0x540001ad, 0xb9420e0b, 0x1100056b, 0xb9020e0b, 0x7100217f, 0x5400032b,               # over: under 8 in a row, stay
    0xbc2258e0, 0xb8225904, 0x51000469, 0x1100044a, 0x6b09015f, 0x1a89d140, 0xd65f03c0,               # 8 in a row: record it, down one (to the floor)
    0xb9020e1f, 0xbc2258e0, 0xb8225904, 0x34000182, 0x51000449, 0xb869590a, 0x340000ea, 0x4b0a008a,   # fits: record it; at 0 stay; the level above's record
    0x7109615f, 0x54000088, 0xbc6958e2, 0x1e212040, 0x540000aa, 0x2a0903e0, 0xd65f03c0,               # never, stale or fitting: up one
    0x2a1f03e0, 0xd65f03c0, 0x2a0203e0, 0xd65f03c0)                                                   # 0; or stay
def dynamic_resolution(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    site = ctx.others.get('dynamic resolution')
    if site is None or ctx.others.get('dynamic resolution update') is None: return   # not both found in this build (a red line from the locator): the game's own dynamic resolution
    fs_site(site, '017c40bd')   # ldr s1,[x0,#0x7c]
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in drs_controller: emit(w)
    fs_put(site, [B(site, start)], 'dynamic resolution level: 0 (full resolution), or with state +0x40 (DM_DYNAMIC_RESOLUTION) a climb on the load measured at each level')
    ctx.capabilities.add('DYNAMIC_RESOLUTION')

# Render scale (DM_RENDER_SCALE, state +0x10, dm/host/loader.c). The 3D views' sizes come from the scale the engine stores at main+0x31d3f48 (str s0,[x20,#0xe5c], found by
# upstream PR #1497), but that store and the size loop after it (main+0x31d3fd8, which clears the "scale changed" bit 3 of [x20+0xe2c] at main+0x31d40b4) run only in a frame
# where the dynamic-resolution controller (bl main+0x805aa0) answers status 0, a new scale: at a steady 60 fps it never does, so a stub at the store alone changed nothing until
# the game came under load. Two stubs: at the controller's answer (main+0x31d3ee4, ubfx of its status byte) a host scale below 1.0 that is not the stored one makes the status 0, so
# that frame recomputes the sizes; at the store the host scale replaces the game's (seedds' fixed form of #1497's ceiling). The scale is then fixed and the dynamic resolution off;
# 0, unset or over 1.0 run the game's own code; 1.0 itself is fixed at the full base (this game's slider, game.tsv render_scale). Registers and flags are kept but x8 (the status, as the game reads it next) and s0 (dead after the store: main+0x31d3f84 reloads it).
# The scale is a fraction of the output (the size loop's cap at main+0x31d3fe8 is skipped on this path, bit 0x13 of +0xe20): docked, 0.75 is the game's usual 1920x1080 and 0.5
# draws 1280x720, 0.9 2328x1310. The game picks its NDSR network by the ratio, and nvn_mtl.m's DM_NDSR replacement takes whichever follows the chain's third dispatch
_scale_status, _scale_store = 0x31d3ee4, 0x31d3f48

def _bcond(frm, to, cond): return 0x54000000 | (((to - frm) >> 2) & 0x7ffff) << 5 | cond
def _cbz_w(frm, to, rt): return 0x34000000 | (((to - frm) >> 2) & 0x7ffff) << 5 | rt

def render_scale(ctx):
    here, emit = ctx.here, ctx.emit
    ctx.site(_scale_status, '089c60d3')   # ubfx x8,x0,#32,#8: the controller's status byte
    s = here(); at = lambda k: s + 4 * k   # the stub's k-th word; done is word 16
    for k, w in enumerate((
            0xd3609c08,                       # ubfx x8,x0,#32,#8     the original
            0xa9be47f0,                       # stp x16,x17,[sp,#-32]!
            0xd53b4210,                       # mrs x16,nzcv
            0xf9000bf0,                       # str x16,[sp,#16]
            ADRP(16, at(4), ctx.state),
            0xb9401211,                       # ldr w17,[x16,#0x10]  the host scale's bits
            _cbz_w(at(6), at(16), 17),        # cbz w17,done         unset
            0x52a7f010,                       # mov w16,#0x3f800000
            0x6b10023f,                       # cmp w17,w16
            _bcond(at(9), at(16), 0x8),       # b.hi done            over 1.0, negative or NaN: the game's own
            0x7100051f,                       # cmp w8,#1
            _bcond(at(11), at(16), 0x0),      # b.eq done            status 1, the game's other request (main+0x31d3f4c), is left alone
            0xb94e5e90,                       # ldr w16,[x20,#0xe5c] the stored scale
            0x6b11021f,                       # cmp w16,w17
            _bcond(at(14), at(16), 0x0),      # b.eq done            already the host's
            0x52800008,                       # mov w8,#0            status 0: a new scale, so the sizes are recomputed
            0xf9400bf0,                       # done: ldr x16,[sp,#16]
            0xd51b4210,                       # msr nzcv,x16
            0xa8c247f0)):                     # ldp x16,x17,[sp],#32
        assert here() == at(k); emit(w)
    emit(B(here(), _scale_status + 4))
    ctx.put(_scale_status, [B(_scale_status, s)], 'dynamic-resolution status: a host render scale not yet stored asks for new 3D sizes (state +0x10)')

    ctx.site(_scale_store, '805e0ebd')    # str s0,[x20,#0xe5c]
    s = here()   # original is word 11
    for k, w in enumerate((
            0xadbf7ffe,                       # stp q30,q31,[sp,#-32]!
            0xa9bf47f0,                       # stp x16,x17,[sp,#-16]!
            ADRP(16, at(2), ctx.state),
            0xd53b4211,                       # mrs x17,nzcv
            0xbd40121e,                       # ldr s30,[x16,#0x10]  the host scale
            0x1e2023c8,                       # fcmp s30,#0.0
            _bcond(at(6), at(11), 0xd),       # b.le original        unset, negative or NaN
            0x1e2e101f,                       # fmov s31,#1.0
            0x1e3f23c0,                       # fcmp s30,s31
            _bcond(at(9), at(11), 0xc),       # b.gt original        over 1.0
            0x1e2043c0,                       # fmov s0,s30          the host's fixed scale
            0xbd0e5e80,                       # original: str s0,[x20,#0xe5c]
            0xd51b4211,                       # msr nzcv,x17
            0xa8c147f0,                       # ldp x16,x17,[sp],#16
            0xacc17ffe)):                     # ldp q30,q31,[sp],#32
        assert here() == at(k); emit(w)
    emit(B(here(), _scale_store + 4))
    ctx.put(_scale_store, [B(_scale_store, s)], 'final 3D view scale: the host render scale fixes it, up to 1.0 (over 1.0 = the game\'s own)')

    ctx.render_scale = 1   # the loader takes DM_RENDER_SCALE up to 1.0 and the launcher offers the row (patch_nso.py RENDER_SCALE)

MATCH_FRAME_STEP = {'main': [
    {'name': 'frame ratio from the host\'s step', 'size': 0x9b4, 'fingerprints': ['6ae2aff5344d14568e4dbaf93455e2d8278384bf892ed6c6eca87fef98fbcd1d'], 'stub': frame_step,   # v131072 main+0x6e6be0
     'others': {'dynamic resolution': {'size': 0x294, 'fingerprints': ['7af6ceb0aedf8e0c17dc08ce17fcd6a7cba6d394a0d09e3b504c6d668dc418e7']},   # v131072 main+0x8065e0
                'dynamic resolution update': {'size': 0xb24, 'fingerprints': ['5a423697838976baf286cffa5e2ceef0d4e037abbcd9d371e90e9e702d61b3d4']}}},   # main+0x805aa0
]}

BINDING = [
    {'what': 'frame ratio from the host\'s step', 'now': 'game', 'goal': 'game', 'purpose': 'frame rate',
     'why': "the game's own frame-ratio division, found by its function's fingerprint on any build that keeps the function",
     'checked': 'v131072 main: one function with this fingerprint, the site and its free registers read by disassembly (2026-11-08)'},
    {'what': 'dynamic resolution: full size, or a climb on the load measured at each level', 'now': 'game', 'goal': 'game', 'purpose': 'rendering',
     'why': "the game's own dynamic-resolution level function and update, found by their functions' fingerprints on any build that keeps both; switchable (DM_DYNAMIC_RESOLUTION)",
     'checked': 'v131072 main: one function with each fingerprint (the level function a leaf, x2..x11 / x16 / x17 / s0..s2 free), its callers, the update and the controller fields read by disassembly, the fields read in play (2026-11-08); the climb run natively against a model of the update and in play to full size (2026-11-09)'},
    {'what': 'render scale at the dynamic-resolution status and the final 3D view scale store', 'now': 'build', 'goal': 'game', 'purpose': 'rendering',
     'why': "the game's controller status and final scale store are its own code at fixed addresses",
     'blocked': 'the two sites and their roles are verified for this main build only',
     'checked': 'v131072 main E0F3CCFAF50065AE4EA01EB5AEB13B1A: the status ubfx at +0x31d3ee4, the store at +0x31d3f48 and the size loop that clears bit 3 of +0xe2c, 2026-11-06'}
]
