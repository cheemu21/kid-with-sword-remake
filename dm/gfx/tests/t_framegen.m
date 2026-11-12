// Frame generation (DM_FRAMEGEN, nvn_mtl.m fg_on): MetalFX's frame interpolator after each present snapshot, from the previous one, and the display link showing each generated
// frame on its present's first tick and the present's own picture half its interval later. A white square moves 16 px a present over a grey picture, with a still one at the right
// (a HUD): the generated frame has the moving one halfway and the still one in place. Real presents through an offscreen layer; the display link's ticks are called here
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
static CAMetalLayer *g_test_layer;
void *front_metal_layer(void) { return (__bridge void *)g_test_layer; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
enum { W = 256, H = 128, SQ = 32, Y0 = 48, STILL = 200 };
static int square_x(int i) { return 20 + 16 * (i % 8); }
static tex_t frame(int i) {   // present i: the moving square at square_x(i), the still one at STILL
    static uint32_t px[W * H];
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        int in = y >= Y0 && y < Y0 + SQ && ((x >= square_x(i) && x < square_x(i) + SQ) || (x >= STILL && x < STILL + SQ));
        px[y * W + x] = in ? 0xffffffff : 0xff303030;
    }
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d];
    [mt replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:W * 4];
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=91001+(uint64_t)i};
    t.d.width = W; t.d.height = H; t.d.depth = t.d.levels = t.d.samples = 1;
    t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    serial_put(t.serial, mt); res_add(mt); res_commit(); return t;
}
// The bright columns of row Y0 + SQ / 2 left of the still square, and whether the still square is whole; d: the texture's size is W / d by H / d (positions in its pixels)
static void bright_d(id<MTLTexture> t, int d, int *lo, int *hi, int *still);
static void bright(id<MTLTexture> t, int *lo, int *hi, int *still) { bright_d(t, 1, lo, hi, still); }
static void bright_d(id<MTLTexture> t, int d, int *lo, int *hi, int *still) {
    id<MTLBuffer> out = [g_dev newBufferWithLength:W * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, (Y0 + SQ / 2) / d, 0) sourceSize:MTLSizeMake(W / d, 1, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * 4];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const uint8_t *p = out.contents; *lo = *hi = -1; *still = 1;
    for (int x = 0; x < W / d; x++) { int on = p[4 * x + 1] > 128;
        if (x < (STILL - 4) / d && on) { if (*lo < 0) *lo = x; *hi = x; }
        if (x >= STILL / d + 1 && x < (STILL + SQ) / d - 1 && !on) *still = 0;
        if ((x == STILL / d - 2 || x == (STILL + SQ) / d + 1) && on) *still = 0; }
}
static void copied(void) { snap_commit_wait(g_snap_v); [g_snap_ev waitUntilSignaledValue:g_snap_v timeoutMS:2000]; }
static int last_slot(void) { return (int)((g_snap_next + (uint64_t)g_snap_n - 1) % (uint64_t)g_snap_n); }
@interface TUpdate : NSObject
@property (nonatomic, strong) id<CAMetalDrawable> drawable;
@property (nonatomic) CFTimeInterval targetPresentationTimestamp;
@end
@implementation TUpdate
@end
static double g_t = 100, g_tick_ms;   // g_tick_ms: how long the last tick's callback took (the drawable taken before it)
static uint64_t tick(void) {   // one 60 Hz tick of the display link; returns the serial it showed (0 = none)
    TUpdate *u = [TUpdate new]; u.drawable = [g_test_layer nextDrawable]; u.targetPresentationTimestamp = g_t; g_t += 1 / 60.0;
    uint64_t n = g_present_n; g_present_ser = 0;
    uint64_t t0 = now_ns();
    [[NvMetalDisplayLinkDelegate new] metalDisplayLink:(CAMetalDisplayLink *)nil needsUpdate:(CAMetalDisplayLinkUpdate *)u];
    g_tick_ms = (now_ns() - t0) / 1e6;
    return g_present_n != n ? g_present_ser : 0;
}
// A case starts with no drop history (the cases before it make the link wait on purpose, which would stop the interpolation for the ones after)
static void calm(void) { pthread_mutex_lock(&g_pq_mu); atomic_store(&g_fg_shed, 0); g_fg_last_drop = 0; g_fg_need = 1; g_fg_resume = 30; pthread_mutex_unlock(&g_pq_mu); }
// n presents from frame i0 at 30 fps on the link's 60 Hz ticks (two ticks each)
static void steady(int i0, int n) { for (int i = 0; i < n; i++) { tex_t t = frame(i0 + i); present_enqueue(&t, 1 / 30.0, NULL, 0); copied(); tick(); tick(); } }
// "t_framegen size": DM_FRAMEGEN_SCALE=0.5 (the launcher's Frame generation size), fixed for the process: the snapshots and generated frames at half the shown size, still
// with the moving square halfway, and the present's MetalFX upscaling turned on to bring them back
static int size_case(void) {
    setenv("DM_FRAMEGEN", "1", 1); setenv("DM_PRESENT_SNAP", "1", 1); setenv("DM_PRESENT_HZ", "0", 1); setenv("DM_PRESENT_LINK", "0", 1); setenv("DM_FRAMEGEN_SCALE", "0.5", 1);
    mtl_init();
    g_test_layer = [CAMetalLayer layer]; g_test_layer.device = g_dev; g_test_layer.drawableSize = CGSizeMake(W, H); g_test_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    mtl_present_screen(W, H); mtl_present_layer(W, H);
    for (int i = 0; i < 5; i++) { tex_t t = frame(i); present_enqueue(&t, 1 / 30.0, NULL, 0); mtl_present_flush(); copied(); }
    int k = last_slot(); id<MTLTexture> c = g_snap[k].tex;
    CHECK("size: the snapshot is at half the shown size", c.width == W / 2 && c.height == H / 2);
    CHECK("size: the present's MetalFX upscaling is on", fx_mode() == 1);
    int lo, hi, still; int want = (square_x(3) + square_x(4)) / 4;
    CHECK("size: a generated frame at half size", g_snap[k].gen_ok && g_snap[k].gen.width == W / 2);
    if (g_snap[k].gen_ok) { bright_d(g_snap[k].gen, 2, &lo, &hi, &still); printf("size: generated square at %d..%d (halfway %d..%d)\n", lo, hi, want, want + SQ / 2 - 1);
        CHECK("size: the square is halfway", abs(lo - want) <= 2 && abs(hi - (want + SQ / 2 - 1)) <= 2 && still); }
    mtl_drain();
    printf("frame generation size: %d checks, %d failed\n", checks, failed); return failed != 0;
}
// "t_framegen stab": how steady generated frames are (a measurement, it reports and fails nothing). A detailed scene (value noise of three scales, colour) pans at a steady
// SPEED px a frame and then a fast one, under an opaque HUD (top left: a box of glyph-like bars) and a half-transparent panel (bottom right, the scene through it, with
// bars in it). Each generated frame is scored against the ideal halfway picture (the scene at the mean of the two offsets, the HUD as it is): mean error on the scene,
// on the HUD and on the panel, and the HUD's flicker (its change between consecutive generated frames, 0 at best)
enum { SW = 960, SH = 540 };
static float sb_h(int x, int y) { unsigned h = (unsigned)x * 374761393u + (unsigned)y * 668265263u; h = (h ^ (h >> 13)) * 1274126177u; return (float)((h ^ (h >> 16)) & 0xffff) / 65535.f; }
static float sb_noise(float x, float y, float sc) { float fx = x / sc, fy = y / sc; int ix = (int)floorf(fx), iy = (int)floorf(fy); float tx = fx - ix, ty = fy - iy;
    float a = sb_h(ix, iy), b = sb_h(ix + 1, iy), c = sb_h(ix, iy + 1), d = sb_h(ix + 1, iy + 1); tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty);
    return (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty; }
static void sb_scene(float ox, float x, float y, float *r, float *g, float *b) { float u = x + ox;
    float n1 = sb_noise(u, y, 64), n2 = sb_noise(u + 1000, y, 12), n3 = sb_noise(u + 2000, y, 3);
    *r = 0.15f + 0.5f * n1 + 0.25f * n3; *g = 0.2f + 0.35f * n2 + 0.3f * n1; *b = 0.1f + 0.3f * n3 + 0.2f * n2; }
static int sb_hud(int x, int y) { return x >= 40 && x < 300 && y >= 30 && y < 90; }
static int sb_panel(int x, int y) { return x >= 660 && x < 930 && y >= 380 && y < 520; }
static int sb_bar(int x, int y) { return ((x / 6) % 3 != 2) && ((y / 10) % 2 == 0) && ((x * 7 + y * 3) % 23 > 5); }
static float g_sb_obj;   // the moving object's x offset (its own motion, against the pan)
static int sb_in_obj(float obj, int x, int y) { float dx = x - (300 + obj), dy = y - 300; return dx * dx + dy * dy < 45 * 45; }
static void sb_pixel(float ox, int x, int y, uint8_t *px) { float r, g, b; sb_scene(ox, x, y, &r, &g, &b);
    if (sb_in_obj(g_sb_obj, x, y)) { int u = (int)(x - g_sb_obj); r = ((u / 5 + y / 5) & 1) ? 0.95f : 0.3f; g = 0.2f; b = ((u / 9) & 1) ? 0.9f : 0.1f; }
    if (sb_hud(x, y)) { float v = sb_bar(x, y) ? 0.95f : 0.08f; r = v; g = v * 0.9f; b = 0.2f; }
    else if (sb_panel(x, y)) { if (sb_bar(x, y) && (x % 40) < 30) { r = g = b = 0.9f; } else { r = 0.5f * r + 0.05f; g = 0.5f * g + 0.1f; b = 0.5f * b + 0.25f; } }
    px[0] = (uint8_t)fminf(255, r * 255 + 0.5f); px[1] = (uint8_t)fminf(255, g * 255 + 0.5f); px[2] = (uint8_t)fminf(255, b * 255 + 0.5f); px[3] = 255; }
static uint8_t *sb_image(float ox) { uint8_t *p = malloc(SW * SH * 4); for (int y = 0; y < SH; y++) for (int x = 0; x < SW; x++) sb_pixel(ox, x, y, p + 4 * (y * SW + x)); return p; }
static tex_t sb_tex(float ox, int i) {
    uint8_t *p = sb_image(ox);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:SW height:SH mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead; id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d];
    [mt replaceRegion:MTLRegionMake2D(0, 0, SW, SH) mipmapLevel:0 withBytes:p bytesPerRow:SW * 4]; free(p);
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=95001+(uint64_t)i}; t.d.width = SW; t.d.height = SH; t.d.depth = t.d.levels = t.d.samples = 1;
    t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8; serial_put(t.serial, mt); res_add(mt); res_commit(); return t;
}
static uint8_t *sb_read(id<MTLTexture> t) {
    id<MTLBuffer> out = [g_dev newBufferWithLength:SW * SH * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(SW, SH, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:SW * 4 destinationBytesPerImage:SW * SH * 4];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    uint8_t *p = malloc(SW * SH * 4); memcpy(p, out.contents, SW * SH * 4); return p;
}
static int stab_case(void) {
    setenv("DM_FRAMEGEN", "1", 1); setenv("DM_PRESENT_SNAP", "1", 1); setenv("DM_PRESENT_HZ", "0", 1); setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init();
    g_test_layer = [CAMetalLayer layer]; g_test_layer.device = g_dev; g_test_layer.drawableSize = CGSizeMake(SW, SH); g_test_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    mtl_present_screen(SW, SH); mtl_present_layer(SW, SH);
    const char *e = getenv("STAB_SPEEDS"); int sp[2] = {24, 96}; if (e) sscanf(e, "%d,%d", &sp[0], &sp[1]);
    for (int run = 0; run < 2; run++) {
        float off = 0, prev_off = 0, obj = 0, prev_obj = 0; double es = 0, eh = 0, ep = 0, fl = 0, es2 = 0, eo = 0, ew = 0, ea = 0, eheld = 0; int n = 0, nf = 0; uint8_t *last = NULL;
        for (int i = 0; i < 16; i++) {
            prev_off = off; off += sp[run]; prev_obj = obj; obj += 32;
            g_sb_obj = obj; tex_t t = sb_tex(off, run * 100 + i); present_enqueue(&t, 1 / 30.0, NULL, 0); mtl_present_flush(); copied();
            int k = last_slot(); if (!g_snap[k].gen_ok || i < 5) continue;
            g_sb_obj = obj; uint8_t *cur = sb_image(off); g_sb_obj = prev_obj; uint8_t *prv = sb_image(prev_off);
            g_sb_obj = (obj + prev_obj) / 2; uint8_t *g = sb_read(g_snap[k].gen), *ideal = sb_image((off + prev_off) / 2);
            double s = 0, h = 0, pl = 0, ob = 0, wa = 0, oa = 0; long ns = 0, nh = 0, np = 0, no = 0, nw = 0, held = 0, hx[10] = {0}, hy[6] = {0};
            for (int y = 0; y < SH; y++) for (int x = 0; x < SW; x++) { int o = 4 * (y * SW + x); double d = (fabs(g[o] - ideal[o]) + fabs(g[o + 1] - ideal[o + 1]) + fabs(g[o + 2] - ideal[o + 2])) / (3 * 255.0);
                float dx = x - (300 + g_sb_obj), dy = y - 300; int near = dx * dx + dy * dy < 80 * 80;   // the object and the ring around it it uncovers
                double dc = (fabs(g[o] - cur[o]) + fabs(g[o + 1] - cur[o + 1]) + fabs(g[o + 2] - cur[o + 2])) / (3 * 255.0), dp = (fabs(g[o] - prv[o]) + fabs(g[o + 1] - prv[o + 1]) + fabs(g[o + 2] - prv[o + 2])) / (3 * 255.0);
                double art = fmin(d, fmin(dc, dp)); wa += art; nw++;
                if (!near && !sb_hud(x, y) && !sb_panel(x, y) && dc < 1.5 / 255 && d > 3.0 / 255) { held++; if (getenv("STAB_WHERE")) hx[x * 10 / SW]++, hy[y * 6 / SH]++; }   // the scene shown as the present has it where the halfway picture differs   // in none of the three pictures: a ghost, a smear, a tear
                if (near && !sb_hud(x, y) && !sb_panel(x, y)) { ob += d; no++; oa += art; }
                if (sb_hud(x, y)) { h += d; nh++; } else if (sb_panel(x, y)) { pl += d; np++; } else if (!near && x > 8 && x < SW - 8 && y > 8 && y < SH - 8) { s += d; ns++; } }
            if (getenv("STAB_WHERE") && i == 15) { printf("held by tenth of width:"); for (int q = 0; q < 10; q++) printf(" %ld", hx[q]); printf("; by sixth of height:"); for (int q = 0; q < 6; q++) printf(" %ld", hy[q]); printf("\n"); }
            eo += ob / no; ew += wa / nw; ea += oa / no; eheld += (double)held / ns; free(cur); free(prv);
            s /= ns; es += s; es2 += s * s; eh += h / nh; ep += pl / np; n++;
            if (last) { double f = 0; long nn = 0; for (int y = 30; y < 90; y++) for (int x = 40; x < 300; x++) { int o = 4 * (y * SW + x); f += fabs(g[o] - last[o]) / 255.0; nn++; } fl += f / nn; nf++; }
            free(last); last = g; free(ideal);
        }
        free(last);
        double m = es / n;
        printf("stab: %3d px a frame: scene error %.4f (spread %.4f), HUD error %.4f, panel error %.4f, HUD flicker %.4f, moving object error %.4f; artifacts: whole picture %.5f, around the object %.4f; scene held at 30 fps %.1f%% (%d frames)\n", sp[run], m, sqrt(fmax(0, es2 / n - m * m)), eh / n, ep / n, nf ? fl / nf : 0, eo / n, ew / n, ea / n, 100 * eheld / n, n);
        calm_reset_history: g_fg_warm = 0;
    }
    mtl_drain(); return 0;
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc > 1 && !strcmp(argv[1], "size")) return size_case();
    if (argc > 1 && !strcmp(argv[1], "stab")) return stab_case();
    alarm(90); setbuf(stdout, NULL);
    setenv("DM_FRAMEGEN", "1", 1); setenv("DM_PRESENT_SNAP", "1", 1); setenv("DM_PRESENT_HZ", "0", 1); setenv("DM_PRESENT_LINK", "0", 1);   // the present thread first; the link's ticks are called below
    mtl_init();
    g_test_layer = [CAMetalLayer layer]; g_test_layer.device = g_dev; g_test_layer.drawableSize = CGSizeMake(W, H); g_test_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    mtl_present_screen(W, H); mtl_present_layer(W, H);   // the picture's shape, as a front end reports it
    CHECK("frame generation on", fg_on());
    CHECK("snapshots on with a ring of 3", mtl_snap_on() && g_snap_n == 3);
    // The present thread takes the presents (no display link): each slot's generated frame against the presents before
    int ok[6];
    for (int i = 0; i < 6; i++) {
        tex_t t = frame(i); present_enqueue(&t, 1 / 30.0, NULL, 0); mtl_present_flush(); copied();
        int k = last_slot(); ok[i] = g_snap[k].gen_ok;
        if (i == 5) CHECK("the queued present carries its generated frame", g_pq[(g_pq_in - 1) % PQ].gen == g_snap[k].gen_serial && g_snap[k].gen_serial);
        if (!ok[i]) continue;
        int lo, hi, still; bright(g_snap[k].gen, &lo, &hi, &still); int want = (square_x(i - 1) + square_x(i)) / 2;
        printf("present %d: generated square at %d..%d (halfway %d..%d), still square %s\n", i, lo, hi, want, want + SQ - 1, still ? "in place" : "moved");
        CHECK("the moving square is halfway", abs(lo - want) <= 2 && abs(hi - (want + SQ - 1)) <= 2);
        CHECK("the still square stays", still);
    }
    CHECK("generated frames from the fourth present on", !ok[0] && !ok[1] && !ok[2] && ok[3] && ok[4] && ok[5]);
    { tex_t t = frame(6); present_enqueue(&t, 1 / 60.0, NULL, 0); mtl_present_flush(); copied(); }
    CHECK("none for a present of one tick", !g_snap[last_slot()].gen_ok && !g_pq[(g_pq_in - 1) % PQ].gen);
    for (int i = 7; i < 10; i++) { tex_t t = frame(i); present_enqueue(&t, 1 / 30.0, NULL, 0); mtl_present_flush(); copied(); ok[i - 7] = g_snap[last_slot()].gen_ok; }
    CHECK("after it, the history starts again", !ok[0] && !ok[1] && ok[2]);
    // The display link at 30 fps on 60 Hz ticks: the generated frame on the present's first tick, its own picture on the second. Frame generation pauses while frames drop:
    // a present the link waited for (a tick found nothing new to show) or one taken while a newer one waits shows its own picture, until three have come in time
    pthread_mutex_lock(&g_pq_mu); g_link_owns_layer = 1; pthread_mutex_unlock(&g_pq_mu);
    g_dm_present_link = 1; g_link_started = 1;   // no link object: the ticks below are the link's
    for (int i = 0; i < 4; i++) tick();
    CHECK("the link's tick interval is known", fabs(g_fg_tick - 1 / 60.0) < 1e-4);
    int order = 1, paused = 1;
    for (int i = 10; i < 16; i++) {   // (10 to 15: a lone drop's pause, FG_AGAIN presents before the late case below)
        tex_t t = frame(i); present_enqueue(&t, 1 / 30.0, NULL, 0); copied();
        int k = last_slot(); uint64_t gen = g_snap[k].gen_ok ? g_snap[k].gen_serial : 0, own = g_snap[k].serial;
        uint64_t a = tick(), b = tick();
        printf("present %d: ticks showed %llx %llx (generated %llx, own %llx)\n", i, (unsigned long long)a, (unsigned long long)b, (unsigned long long)gen, (unsigned long long)own);
        if (i < 11) paused &= a == own && !b;   // 10 came after ticks with nothing to show: a lone drop pauses only it
        else order &= gen && a == gen && b == own;
    }
    CHECK("after the link waited for a present, its own picture, then generated frames again", paused);
    CHECK("each present in time: its generated frame, then its own picture", order);
    CHECK("then held", !tick());
    // A tick missed after the generated frame: once the interval is over and the next present waits, that one is shown, not the stale picture
    calm(); steady(40, 3);
    tex_t t1 = frame(14); present_enqueue(&t1, 1 / 30.0, NULL, 0); copied();
    uint64_t g1 = g_snap[last_slot()].gen_serial, a = tick(); g_t += 1 / 60.0;
    tex_t t2 = frame(15); present_enqueue(&t2, 1 / 30.0, NULL, 0); copied();
    uint64_t g2 = g_snap[last_slot()].gen_serial, late = g_fg_late, b = tick();
    CHECK("a missed tick skips the stale picture for the next present", a == g1 && b == g2 && g_fg_late == late + 1);
    tick(); tick();
    // A present of one tick on the link: its own picture only
    tex_t t3 = frame(16); present_enqueue(&t3, 1 / 60.0, NULL, 0); copied();
    uint64_t own = g_snap[last_slot()].serial;
    CHECK("a present of one tick shows its own picture", tick() == own && !tick());
    // A present that comes late (the link shows nothing new on a tick past its interval) within FG_AGAIN presents of the drop before: its own picture, and so for the next
    // ones until three have come in time
    calm(); steady(30, 4); g_fg_last_drop = g_pq_in; tick();   // in time (a drop just before, so the late one below is soon after it), then a tick with nothing new
    uint64_t late_show[4], late_own[4], late_gen[4];
    for (int i = 0; i < 4; i++) { tex_t t = frame(34 + i); present_enqueue(&t, 1 / 30.0, NULL, 0); copied();
        late_own[i] = g_snap[last_slot()].serial; late_gen[i] = g_snap[last_slot()].gen_ok ? g_snap[last_slot()].gen_serial : 0; late_show[i] = tick(); tick(); }
    printf("after a late present the first ticks showed: %s %s %s %s\n", late_show[0] == late_own[0] ? "own" : "?", late_show[1] == late_own[1] ? "own" : "?",
           late_show[2] == late_own[2] ? "own" : "?", late_show[3] == late_own[3] ? "own" : late_show[3] == late_gen[3] ? "generated" : "?");
    CHECK("a late present soon after another stops the interpolation: its own pictures", late_show[0] == late_own[0] && late_show[1] == late_own[1] && late_show[2] == late_own[2] && late_show[3] == late_own[3] && atomic_load(&g_fg_shed));
    // One newer present waiting is the game running a frame ahead (snapshots): generated frames go on. Three waiting: the oldest is dropped, and the one taken shows its
    // own picture, as does the next
    calm(); steady(44, 3);
    tex_t b1 = frame(36), b2 = frame(37);
    present_enqueue(&b1, 1 / 30.0, NULL, 0); copied(); uint64_t gen_b1 = g_snap[last_slot()].gen_ok ? g_snap[last_slot()].gen_serial : 0, own_b1 = g_snap[last_slot()].serial;
    present_enqueue(&b2, 1 / 30.0, NULL, 0); copied(); uint64_t gen_b2 = g_snap[last_slot()].gen_ok ? g_snap[last_slot()].gen_serial : 0;
    uint64_t sb1 = tick(), ob1 = tick(), sb2 = tick(); tick();
    CHECK("one newer present waiting: generated frames go on", gen_b1 && sb1 == gen_b1 && ob1 == own_b1 && gen_b2 && sb2 == gen_b2);
    tex_t c1 = frame(38), c2 = frame(39), c3 = frame(40);
    present_enqueue(&c1, 1 / 30.0, NULL, 0); copied();
    present_enqueue(&c2, 1 / 30.0, NULL, 0); copied(); uint64_t own_c2 = g_snap[last_slot()].serial;
    present_enqueue(&c3, 1 / 30.0, NULL, 0); copied(); uint64_t own_c3 = g_snap[last_slot()].serial;
    uint64_t behind0 = g_fg_paused_behind, sc2 = tick(); tick(); uint64_t sc3 = tick(); tick();
    printf("three waiting: ticks showed %llx then %llx (own %llx, %llx)\n", (unsigned long long)sc2, (unsigned long long)sc3, (unsigned long long)own_c2, (unsigned long long)own_c3);
    // (c3's ring slot is still held, so it is shown from the game's own texture)
    CHECK("an older present dropped: the one taken and the next show their own pictures", sc2 == own_c2 && (sc3 == own_c3 || sc3 == c3.serial) && g_fg_paused_behind == behind0 + 1);
    // Frames dropping on and on: two late presents within FG_AGAIN stop the interpolation itself (no generated frame is made), until g_fg_resume presents in a row come in time
    calm(); steady(50, 4);
    for (int i = 0; i < 2; i++) { tick(); tex_t t = frame(54 + i); present_enqueue(&t, 1 / 30.0, NULL, 0); copied(); tick(); tick(); }   // a tick with nothing new, then a present: late, twice
    CHECK("frames dropping on and on stop the interpolation", atomic_load(&g_fg_shed) == 1);
    { tex_t t = frame(56); present_enqueue(&t, 1 / 30.0, NULL, 0); copied(); tick(); tick(); }
    CHECK("while stopped, no generated frame is made", !g_snap[last_slot()].gen_ok);
    int resumed = 0, made = 0;
    for (int i = 0; i < g_fg_resume + 6; i++) { tex_t t = frame(57 + i); present_enqueue(&t, 1 / 30.0, NULL, 0); copied(); if (!atomic_load(&g_fg_shed)) resumed = 1; if (g_snap[last_slot()].gen_ok) made = 1; tick(); tick(); }
    printf("interpolation stopped %llu times; resumed %d, generated again %d (after %d presents in time)\n", (unsigned long long)g_fg_sheds, resumed, made, g_fg_resume);
    CHECK("it runs again after presents in time", resumed && made);
    // The picture after a generated frame while the GPU has not run that frame (a long frame, a load): it does not wait on the display link thread for the generated frame's
    // allocator, which held the link silent until its rescue (a Mac run while loading)
    calm(); steady(17, 3);
    tex_t t4 = frame(20); present_enqueue(&t4, 1 / 30.0, NULL, 0); copied();
    uint64_t g4 = g_snap[last_slot()].gen_ok ? g_snap[last_slot()].gen_serial : 0, own4 = g_snap[last_slot()].serial;
    id<MTLSharedEvent> gate = [g_dev newSharedEvent]; [g_q4 waitForEvent:gate value:1];   // the GPU stops before the generated frame's present
    uint64_t ga = tick(), gb = tick(); double ms = g_tick_ms;
    printf("with the GPU held: ticks showed %llx %llx, the second's callback took %.2f ms\n", (unsigned long long)ga, (unsigned long long)gb, ms);
    CHECK("the picture after a generated frame does not wait for the GPU", g4 && ga == g4 && gb == own4 && ms < 50);
    gate.signaledValue = 1;
    CHECK("the interpolation's GPU time is measured", g_fg_gpu_last > 2e-5 && g_fg_gpu_last < 1);   // (an empty or early stamp read 0 or 6 µs)
    printf("last interpolation: %.3f ms\n", g_fg_gpu_last * 1e3);
    // A screen smaller than the picture (an iPhone's): the snapshot and the frames generated from it are made at the size the picture is shown at
    for (int i = 0; i < 4; i++) tick();
    g_test_layer.drawableSize = CGSizeMake(W / 2, H / 2);
    const int whole_crop[4] = {0, 0, W, H};   // Ocarina of Time passes its window's crop, the whole texture, with every present (log 73)
    for (int i = 21; i < 26; i++) { tex_t t = frame(i); present_enqueue(&t, 1 / 30.0, whole_crop, 0); copied(); tick(); tick(); }
    CHECK("a present whose snapshot holds its crop is shown whole", !g_pq[(g_pq_in - 1) % PQ].crop[2] && !g_pq[(g_pq_in - 1) % PQ].crop[3]);
    int k5 = last_slot(); id<MTLTexture> half = g_snap[k5].tex;
    CHECK("the snapshot is at the size the picture is shown at", half.width == W / 2 && half.height == H / 2 && g_snap[k5].gen_ok && g_snap[k5].gen.width == W / 2);
    { int lo, hi, still; bright_d(g_snap[k5].tex, 2, &lo, &hi, &still);
      printf("half size, own picture: square at %d..%d (%d..%d)\n", lo, hi, square_x(25) / 2, (square_x(25) + SQ) / 2 - 1);
      CHECK("the half-size picture is the picture scaled", abs(lo - square_x(25) / 2) <= 1 && abs(hi - ((square_x(25) + SQ) / 2 - 1)) <= 1 && still);
      bright_d(g_snap[k5].gen, 2, &lo, &hi, &still); int want = (square_x(24) + square_x(25)) / 4;
      printf("half size, generated: square at %d..%d (halfway %d..%d)\n", lo, hi, want, want + SQ / 2 - 1);
      CHECK("the half-size generated frame has the square halfway", abs(lo - want) <= 2 && abs(hi - (want + SQ / 2 - 1)) <= 2 && still); }
    // A crop of the right half (the still square and what lies left of it, from x 128): the snapshot holds that half alone, at the half-size screen's size
    const int right[4] = {W / 2, 0, W / 2, H};
    for (int i = 26; i < 28; i++) { tex_t t = frame(i); present_enqueue(&t, 1 / 30.0, right, 0); copied(); tick(); tick(); }
    { int k6 = last_slot(); id<MTLTexture> c = g_snap[k6].tex;
      id<MTLBuffer> out = [g_dev newBufferWithLength:c.width * 4 options:MTLResourceStorageModeShared];
      id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
      [b copyFromTexture:c sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, (Y0 + SQ / 2) * c.height / H, 0) sourceSize:MTLSizeMake(c.width, 1, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:c.width * 4 destinationBytesPerImage:c.width * 4];
      [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
      const uint8_t *p = out.contents; int a = -1, z = -1; for (int x = 0; x < (int)c.width; x++) if (p[4 * x + 1] > 128) { if (a < 0) a = x; z = x; }
      double sc = (double)c.width / (W / 2); int wa = (int)lround((STILL - W / 2) * sc), wz = (int)lround((STILL + SQ - W / 2) * sc) - 1;
      printf("right-half crop: snapshot %lux%lu, still square at %d..%d (%d..%d)\n", (unsigned long)c.width, (unsigned long)c.height, a, z, wa, wz);
      CHECK("a cropped picture is copied alone at its shown size", c.width == (NSUInteger)lround(H / 2.0 * (W / 2) / H) && c.height == H / 2 && abs(a - wa) <= 1 && abs(z - wz) <= 1); }
    // A crop shown at its size or larger (Ocarina of Time: 2352x1080 of a 3136x1440 texture on a 2622x1203 screen, log 75): the snapshot holds the crop alone, 1:1
    g_test_layer.drawableSize = CGSizeMake(W, H);
    for (int i = 28; i < 32; i++) { tex_t t = frame(i); present_enqueue(&t, 1 / 30.0, right, 0); copied(); tick(); tick(); }
    { int k7 = last_slot(); id<MTLTexture> c = g_snap[k7].tex;
      id<MTLBuffer> out = [g_dev newBufferWithLength:c.width * 4 options:MTLResourceStorageModeShared];
      id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
      [b copyFromTexture:c sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, Y0 + SQ / 2, 0) sourceSize:MTLSizeMake(c.width, 1, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:c.width * 4 destinationBytesPerImage:c.width * 4];
      [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
      const uint8_t *p = out.contents; int a = -1, z = -1; for (int x = 0; x < (int)c.width; x++) if (p[4 * x + 1] > 128) { if (a < 0) a = x; z = x; }
      printf("right-half crop on a full-size screen: snapshot %lux%lu, bright from %d to %d (the moving square from %d, the still one to %d), generated %s\n", (unsigned long)c.width, (unsigned long)c.height, a, z, square_x(31) - W / 2, STILL + SQ - W / 2 - 1, g_snap[k7].gen_ok ? "yes" : "no");
      CHECK("a crop shown at its size is copied alone, 1:1, and shown whole", c.width == W / 2 && c.height == H && a == square_x(31) - W / 2 && z == STILL + SQ - W / 2 - 1 && g_snap[k7].gen_ok
            && !g_pq[(g_pq_in - 1) % PQ].crop[2]); }
    present_drop_for_suspend(); mtl_drain();
    printf("frame generation: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
