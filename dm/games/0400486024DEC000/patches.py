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
    if ctx.base == 0x6e6be0:   # v131072, where the frame-step function starts here: the stubs below use fixed addresses verified on that build only
        render_scale(ctx)   # the launcher's Render scale (state +0x10)
        wide_view(ctx); ctx.capabilities.add('WIDE_VIEW')   # the launcher's Wide view (state +0x100..+0x117; settings.tsv fixups:WIDE_VIEW)

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

# Wide view (DM_WIDE_VIEW, a launcher setting; X1): the game sizes its output from fixed constants, so a screen wider than 16:9 shows bars. These stubs take the widths from the state
# page, written at each start from the screen's shape (loader.c dm_fps_state_apply), so the view widens (Hor+) and nothing stretches; 0 there (16:9, or the setting off) runs the game's
# own constant. Sites from nxnative PR #1460 by vladbondarenko97, which cut them at build time (DM_ULTRAWIDE); here they are stubs that read the state page,
# so the setting needs no rebuild. v131072 only (frame_step calls it where the frame-step function starts at main+0x6e6be0, as on v131072). Each stub writes only the register the constant loads
wide_sites = [(0x1202ee0, 0xD2814008, 0x100, 8, 'graphics setup output width'), (0x31f39f4, 0xD2814008, 0x100, 8, 'docked render width'),
              (0x31f3a00, 0xD280F008, 0x104, 8, 'handheld render width'), (0xecbc80, 0x52A8A409, 0x108, 9, 'output width as a float')]
def wide_view(ctx):
    here, emit = ctx.here, ctx.emit
    for site, orig, off, rd, what in wide_sites:
        ctx.site(site, orig.to_bytes(4, 'little').hex())
        start = here(); emit(ADRP(rd, here(), ctx.state))
        emit(0xB9400000 | (off // 4) << 10 | rd << 5 | rd)      # ldr w<rd>,[x<rd>,#off]
        emit(0x35000040 | rd)                                   # cbnz w<rd>,the branch back
        emit(orig); emit(B(here(), site + 4))
        ctx.put(site, [B(site, start)], f'wide view: {what} from the state page (0: the game\'s own)')
    # The output resolution table (main+0x3f58540, read here by the display mode, a leaf ending in ret: x9..x11 are free): each entry's width from its height and the screen's ratio
    site = 0x112c604
    ctx.site(site, '287968f8')   # ldr x8,[x9,x8,lsl #3]: width in the low word, height in the high one
    start = here(); emit(0xF8687928); emit(ADRP(9, here(), ctx.state))
    for w in (0xB9410D2A, 0x340000EA, 0xD360FD0B, 0x9B0B7D4A, 0x9142014A, 0xD354FD4A, 0xD37CED4A, 0xB3407D48): emit(w)   # ratio (16.16); if 0 skip; height * ratio, to a multiple of 16; width
    emit(B(here(), site + 4))
    ctx.put(site, [B(site, start)], 'wide view: output resolution table width from its height')
    # The camera's aspect: the projection objects' constructors (main+0x9b5f34, main+0x2e1be3c) store 16:9 at +0x100 beside the near plane (0.1 at +0xf8), and a getter's
    # fallback (main+0x14fc7e0) returns it, so with the wider output the 3D was drawn 16:9 and stretched sideways, about 22 % wide on a 2.18:1 iPhone (the owner's
    # screenshot: Link, Zelda and Navi fat; PR #1460 at 21:9 on a Mac had said the camera takes its aspect from the render size). Each stub keeps the game's 16:9 in w8,
    # then takes the state page's float at +0x110 (the output's width / height, loader.c) when it is not 0. x16 is the scratch register: none of the three uses it
    for site, what, mark in ((0x9b5f38, 'camera projection constructor', 0x128), (0x2e1be40, 'second camera projection constructor', 0x12c), (0x14fc7e4, 'aspect getter fallback', 0x130)):
        ctx.site(site, (0x72A7FC68).to_bytes(4, 'little').hex())   # movk w8,#0x3fe3,lsl #16 (16:9 = 0x3fe38e39)
        start = here(); emit(0x72A7FC68)                       # movk w8,#0x3fe3,lsl #16: the game's 16:9
        emit(ADRP(16, here(), ctx.state))
        emit(0xB9411210)                                        # ldr w16,[x16,#0x110]
        emit(0x34000050)                                        # cbz w16,+8 (0: 16:9 kept)
        emit(0x2A1003E8)                                        # mov w8,w16
        emit(ADRP(16, here(), ctx.state)); emit(0xB9000000 | ((mark // 4) << 10) | 16 << 5 | 8)   # str w8,[x16,#mark]: the aspect it took, for the host's log (loader.c dm_wide_note)
        emit(B(here(), site + 4))
        ctx.put(site, [B(site, start)], f'wide view: {what} aspect from the state page (0: 16:9)')
    # The 2D canvas: main+0xe8303c stores a fixed 1920 x 1080 as the layout canvas's size (+0xe54 / +0xe58) unless one of two flags takes it from the display, so the HUD and
    # the menus were drawn 16:9 and stretched sideways like the 3D (the owner's screenshots, X15: the item frame 129 x 106 px, 22 % wide; the title's moon, 3D, round). The stub
    # keeps the game's 1920.0 in w8, then takes the state page's +0x114 (the 1080-high output width as a float, loader.c) when it is not 0: the canvas the screen's shape at 1080 tall
    site = 0xe8303c
    ctx.site(site, (0x52A89E08).to_bytes(4, 'little').hex())   # mov w8,#0x44f00000 (1920.0)
    start = here(); emit(0x52A89E08)
    emit(ADRP(16, here(), ctx.state))
    emit(0xB9411610)                                            # ldr w16,[x16,#0x114]
    emit(0x34000050)                                            # cbz w16,+8 (0: 1920 kept)
    emit(0x2A1003E8)                                            # mov w8,w16
    emit(ADRP(16, here(), ctx.state)); emit(0xB9012608)         # str w8,[x16,#0x124]: the canvas width this path stored (float bits), for the host's log
    emit(B(here(), site + 4))
    ctx.put(site, [B(site, start)], 'wide view: the 2D canvas width from the state page (0: 1920)')
    # Three more cameras build the same 16:9 aspect beside a 0.1 near plane (main+0xe07154 w8, the far plane 10000; main+0x27b13f8 w9 and main+0x2e1cb84 w9, a projection set up on
    # the stack): the constructors above are what the field and town cameras take (a Mac run at 2.174:1: 2.1778 in both, Navi's glow round, 34 x 35 px), and these are the others
    # (an event or special view's camera), widened the same way so no 3D view stays 16:9. Each keeps the game's 16:9 in its register unless the state page's +0x110 is set
    for site, rd, what in ((0xe07154, 8, 'third camera'), (0x27b13f8, 9, 'fourth camera'), (0x2e1cb84, 9, 'fifth camera')):
        ctx.site(site, (0x72A7FC60 | rd).to_bytes(4, 'little').hex())   # movk w<rd>,#0x3fe3,lsl #16
        start = here(); emit(0x72A7FC60 | rd)                  # the game's 16:9 high half
        emit(ADRP(16, here(), ctx.state))
        emit(0xB9411210)                                        # ldr w16,[x16,#0x110]
        emit(0x34000050)                                        # cbz w16,+8 (0: 16:9 kept)
        emit(0x2A1003E0 | rd)                                   # mov w<rd>,w16
        emit(B(here(), site + 4))
        ctx.put(site, [B(site, start)], f'wide view: the {what}\'s aspect from the state page (0: 16:9)')
    # The world-to-layout mapping: a point's place on screen (-1 to 1) times 1920 x 1080 gives its place in the game's 3840x2160 2D layout, where a speech bubble or a marker
    # over a character is drawn (main+0x20c2b0, +0x20c99c, +0x215fb0: mov w8,#1920.0, fmov s0,w8, then times the x). With Wide view the host draws that layout at its own shape in
    # the middle 16:9 of the screen (nvn_mtl.m wide2d_fix), so the x is taken times the 1080-high output width (2352.0, state +0x114) in place of 1920: the screen's width in
    # layout units, and a bubble stays over its character to the screen's edges. 0 there (Wide view off): the game's 1920. x16 is free at all three
    for site in (0x20c2b0, 0x20c99c, 0x215fb0):
        ctx.site(site, (0x52A89E08).to_bytes(4, 'little').hex())   # mov w8,#0x44f00000 (1920.0)
        start = here(); emit(0x52A89E08)
        emit(ADRP(16, here(), ctx.state))
        emit(0xB9411610)                                        # ldr w16,[x16,#0x114]
        emit(0x34000050)                                        # cbz w16,+8 (0: 1920 kept)
        emit(0x2A1003E8)                                        # mov w8,w16
        emit(B(here(), site + 4))
        ctx.put(site, [B(site, start)], 'wide view: the world-to-layout x scale from the state page (0: 1920)')
    # The aspect the 3D draws with: the renderer copies its view's camera (near, far, field of view and aspect at +0x1c8..+0x1d4 of it, 0xa2 bytes, main+0x4c6388) into its own
    # at +0x3118, and main+0x335650 builds from that copy the camera constants every 3D pass reads (near, far, aspect, the projection and the frustum; copied into the uniform
    # buffer at main+0x660aac). Mac runs with the host's write watch (DM_CTL watch, nvn_mtl.m DM_WATCH_SCENE) on each: the uniform block from main+0x660aac, the renderer's copy
    # only from main+0x4c6388, the view's camera never during play, its aspect 0x3fe38e3b from before: the decimal 1.777778 of the game's camera data, which no 16:9 constant
    # in the code (the constructors' above, the parameter copy's) ever reached; Link 1.25 times too wide on Wide view. After the copy (main+0x4c638c, mov w8,#0x31c0 before
    # the constants are built) an aspect from 1.75 to 1.875 (bits >> 20 == 0x3fe) is taken as the output's when Wide view is on (state +0x110): the projection, the frustum and
    # everything built from them follow. x16, x17 and the flags are free there (a call follows)
    site = 0x4c638c
    ctx.site(site, (0x52863808).to_bytes(4, 'little').hex())   # mov w8,#0x31c0
    start = here()
    emit(0x52862490)                                            # mov w16,#0x3124          the renderer camera's aspect (+0x2f50 + 0x1d4)
    emit(0xB8706A71)                                            # ldr w17,[x19,x16]
    emit(0x53147E31)                                            # lsr w17,w17,#20
    emit(0x710FFA3F)                                            # cmp w17,#0x3fe          1.75 to 1.875
    emit(0x540000A1)                                            # b.ne +20                (another aspect: as it is)
    emit(ADRP(17, here(), ctx.state))
    emit(0xB9411231)                                            # ldr w17,[x17,#0x110]    the output's aspect (0: Wide view off)
    emit(0x34000051)                                            # cbz w17,+8
    emit(0xB8306A71)                                            # str w17,[x19,x16]
    emit(0x52863808)                                            # mov w8,#0x31c0          the original
    emit(B(here(), site + 4))
    ctx.put(site, [B(site, start)], 'wide view: the renderer camera\'s 16:9 aspect taken as the output\'s before its constants are built')
    # The projections the 3D draws with: sead::PerspectiveProjection keeps its aspect at +0xb0 (near +0x98, far +0x9c, the tan of the half angle +0xac) and builds its matrix
    # from it, and the game sets that aspect from its cameras' data (1.777778, the 0x3fe38e3b a Mac run's write watch found in every camera, whose projection stayed 16:9 with
    # Wide view on: Link 1.25 times too wide). Eleven stores set it: the constructor (main+0x3485c64), the setter (main+0xea4b20, a pair whose second word is the aspect), and the
    # cameras' updates (the others). At each, a value from 1.75 to 1.875 (bits >> 20 == 0x3fe) is stored as the output's aspect when Wide view is on (state +0x110); any other ratio
    # (a cube map's, a shadow map's, one already wide) as the game gives it. The stubs keep the flags (sub and cbnz, no compare: some sites carry live flags) and the source
    # register (the wide value is stored from w16); x16 and x17 are free at each (a call or a store follows, none reads them)
    for site, rt, rn, pair in ((0x3485c64, 3, 0, 0), (0xea4b20, 8, 19, 1), (0x4c533c, 0, 20, 0), (0x653bd4, 0, 8, 0), (0x6545f4, 0, 26, 0), (0x28e72a4, 0, 8, 0),
                               (0x2dd7164, 0, 22, 0), (0x2e1bb6c, 0, 23, 0), (0x2e1c7d0, 0, 21, 0), (0x3b50988, 0, 0, 0), (0x3b50b50, 0, 24, 0)):
        orig = 0x2D15A260 if pair else 0xBD000000 | (0xb0 // 4) << 10 | rn << 5 | rt   # stp s0,s8,[x19,#0xac] / str s<rt>,[x<rn>,#0xb0]
        ctx.site(site, orig.to_bytes(4, 'little').hex())
        start = here()
        emit(0x1E260000 | rt << 5 | 17)                         # fmov w17,s<rt>          the aspect's bits
        emit(0x53147E31)                                        # lsr w17,w17,#20
        emit(0x510FFA31)                                        # sub w17,w17,#0x3fe      0 for 1.75 to 1.875 (no flags)
        emit(0x35000091)                                        # cbnz w17,+16            (another ratio: the game's store)
        emit(ADRP(16, here(), ctx.state))
        emit(0xB9411210)                                        # ldr w16,[x16,#0x110]    the output's aspect (0: Wide view off)
        emit(0x35000070)                                        # cbnz w16,+12            (the wide store)
        emit(orig)                                              # the game's store
        emit(B(here(), site + 4))
        if pair: emit(orig)                                     # the pair as the game stores it, then its aspect word replaced
        emit(0xB9000000 | (0xb0 // 4) << 10 | rn << 5 | 16)     # str w16,[x<rn>,#0xb0]  the output's aspect
        emit(B(here(), site + 4))
        ctx.put(site, [B(site, start)], 'wide view: a perspective projection\'s 16:9 aspect stored as the output\'s')
    # A note of the camera aspect getter's main path (main+0x14fc7b4, ldr d0,[x8]: the two floats it copies from its source object) at +0x138, to tell which path the cameras take
    site = 0x14fc7b4
    ctx.site(site, (0xFD400100).to_bytes(4, 'little').hex())   # ldr d0,[x8]
    start = here(); emit(0xFD400100); emit(ADRP(16, here(), ctx.state)); emit(0xFD009E00)   # ldr d0,[x8]; str d0,[x16,#0x138]
    emit(B(here(), site + 4))
    ctx.put(site, [B(site, start)], 'wide view: a note of the camera aspect getter\'s main path (state +0x138)')

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
