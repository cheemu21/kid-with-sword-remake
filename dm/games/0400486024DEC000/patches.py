# The Legend of Zelda: Ocarina of Time, Switch 2 (0400486024DEC000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies
# those of a module's NSO build ID; CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # v131072 main: the movie player's video enhancement. Creating a movie player (main+0x3b5f500), the game takes the enhanced player (0x2f0 bytes, main+0x3b62cd0, then the NDVE setup
  # main+0x3b62ea0) when its NDVE manager is ready ([x0+0x460] set and its +0x10 not 0), else the plain one (0x1c0 bytes, main+0x3b619e0). The enhanced player runs an Ampere tensor network
  # (Movie/Ndve/Ndve-Nvn2-vid_seq5.dat: 14 compute dispatches a movie frame, 465 HMMA and 1,005 subgroup shuffles a thread in its largest) that took 47.5 ms of GPU time a frame on an
  # M-series Mac, against a 16.7 ms frame: the movies ran at 20 fps. A workaround for that platform limit (the HMMA chains are open in docs/reference/shaders.md, "Ampere HMMA through
  # simdgroup_matrix"): the branch always takes the plain player, which shows the decoded 1920x1080 picture as it is
  'e0f3ccfaf50065ae4ea01eb5aeb13b1a': [
    (0x3b5f524, '28010034', '09000014', 'movie player: cbz w8 → b main+0x3b5f548 (the plain player, without the NDVE tensor network)'),
  ],
}

from nso_asm import ADRP, B

# v131072 main: the frame step (patch_nso.py "Frame step in whole vsyncs"). The game has its own frame-rate controller (main+0x3b4ef60, called once a frame with x20 = its
# config): from the measured frame time it picks a vsync interval between config +0x0 and +0x4 (with hysteresis, +0x50 / +0x54), stores it at +0x48 and fps = 60 / interval
# at +0x58, then at main+0x3b4f074 (where its paths meet) calls main+0x3b4f160, which hands +0x58 to setFrameRate (main+0x4dc0f0), and the framework's setInterval
# (main+0x346c5c0) with +0x48, which sets the window's present interval (main+0xf49970) and the framework's fps (+0xfc = 60 / interval). So 30 fps (interval 2) is the game's
# own mode, with its game time stepping by the interval. The stub at main+0x3b4f074 replaces the interval and fps with the host's step (state page +0x20, 1 = 60 fps, 2 = 30) while
# a target fps is set (state +0x0, the launcher's Frame rate / DM_FPS_TARGET; 0 = the game's own choice), and counts the vsyncs stepped (+0x30) for the host's speed check
def frame_step(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    site = 0x3b4f074
    fs_site(site, 'e00314aa')   # mov x0,x20
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xb9400211,   # ldr w17,[x16]           target fps (float bits; 0 = off)
              0x34000151,   # cbz w17,orig (+10)
              0xb9402211,   # ldr w17,[x16,#0x20]     step in vsyncs
              0x34000111,   # cbz w17,orig (+8)       not decided yet
              0xb9004a91,   # str w17,[x20,#0x48]     the controller's interval
              0x52800789,   # mov w9,#60
              0x1ad10929,   # udiv w9,w9,w17
              0xb9005a89,   # str w9,[x20,#0x58]      its fps, which setFrameRate takes
              0xf9401a09,   # ldr x9,[x16,#0x30]
              0x8b314129,   # add x9,x9,w17,uxtw
              0xf9001a09,   # str x9,[x16,#0x30]      vsyncs stepped
              0xaa1403e0):  # orig: mov x0,x20
        emit(w)
    emit(B(here(), site + 4))
    fs_put(site, [B(site, start)], "frame step: the frame-rate controller's interval and fps follow the host's vsyncs (state page target fps; 0 = the game's own choice)")
    render_scale(ctx)   # the launcher's Render scale (state +0x10), below
    wide_view(ctx)      # the launcher's Wide view (state +0x100..+0x10f), below

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

    ctx.render_scale = 1

# Wide view (DM_WIDE_VIEW, a launcher setting; X1): the game sizes its output from fixed constants, so a screen wider than 16:9 shows bars. These stubs take the widths from the state
# page, written at each start from the screen's shape (loader.c dm_fps_state_apply), so the view widens (Hor+) and nothing stretches; 0 there (16:9, or the setting off) runs the game's
# own constant. Sites from nxnative PR #1460 by vladbondarenko97, which cut them at build time (DM_ULTRAWIDE); here they are stubs that read the state page,
# so the setting needs no rebuild. v131072 only (this FRAME_STEP's build). Each stub writes only the register the constant loads
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
    for site, what in ((0x9b5f38, 'camera projection constructor'), (0x2e1be40, 'second camera projection constructor'), (0x14fc7e4, 'aspect getter fallback')):
        ctx.site(site, (0x72A7FC68).to_bytes(4, 'little').hex())   # movk w8,#0x3fe3,lsl #16 (16:9 = 0x3fe38e39)
        start = here(); emit(0x72A7FC68)                       # movk w8,#0x3fe3,lsl #16: the game's 16:9
        emit(ADRP(16, here(), ctx.state))
        emit(0xB9411210)                                        # ldr w16,[x16,#0x110]
        emit(0x34000050)                                        # cbz w16,+8 (0: 16:9 kept)
        emit(0x2A1003E8)                                        # mov w8,w16
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
    emit(B(here(), site + 4))
    ctx.put(site, [B(site, start)], 'wide view: the 2D canvas width from the state page (0: 1920)')

FRAME_STEP = {'e0f3ccfaf50065ae4ea01eb5aeb13b1a': frame_step}
CAPABILITIES = {'e0f3ccfaf50065ae4ea01eb5aeb13b1a': ('WIDE_VIEW',)}   # the launcher's Wide view row (settings.tsv fixups:WIDE_VIEW)

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': "frame step: the frame-rate controller's interval and fps from the host", 'now': 'build', 'goal': 'game', 'purpose': 'frame rate',
     'why': "the game's own 30 fps mode (interval 2), chosen by the host's step so presentation and game time agree",
     'blocked': 'frame-step stubs have no function-matched form yet'},
    {'what': 'render scale at the dynamic-resolution status and the final 3D view scale store', 'now': 'build', 'goal': 'game', 'purpose': 'rendering',
     'why': "the game's controller status and final scale store are its own code at fixed addresses",
     'blocked': 'the two sites and their roles are verified for this main build only',
     'checked': 'v131072 main E0F3CCFAF50065AE4EA01EB5AEB13B1A: the status ubfx at +0x31d3ee4, the store at +0x31d3f48 and the size loop that clears bit 3 of +0xe2c, 2026-11-06'},
    {'what': 'movie player: the plain player instead of the NDVE-enhanced one', 'now': 'build', 'goal': 'game', 'purpose': 'frame rate',
     'why': 'a workaround: the tensor network costs 47.5 ms of GPU a movie frame; a function fingerprint could carry it over updates, and once the translator keeps LDSM / MOVM / HMMA chains in matrices the cut can go',
     'blocked': 'one build on hand; the faster tensor path is translator work (docs/reference/shaders.md, Ampere HMMA through simdgroup_matrix, Open)'},
]
