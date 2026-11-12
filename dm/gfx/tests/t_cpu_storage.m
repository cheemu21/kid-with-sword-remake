// An uncompressed 2D texture the CPU wrote, in a pool the GPU has not written (nvn_mtl.m tex_cpu_content): its storage is its content at first use, flushed or not, and a later CPU write is
// uploaded. At the first GPU write over its storage it becomes a GPU texture with the content it has (cpu_unc_drop), and CPU writes are no longer uploaded. Over storage the GPU already writes it
// stays a GPU texture; a GPU write elsewhere in its pool changes nothing (DM_NVN_GPUW_RANGE: Ocarina of Time's terrain shares its pool with render targets). Mario Kart World's terrain patches: R16, RG8, RGBA8, R11G11B10F and RGBA16 in a CPU_CACHED pool, never flushed, were zeros and every patch a flat plane.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static void finish(void) { CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull)); CHECK("GPU has no error", !mtl_last_commit_error()); }
enum { SIZE = 16, POOL = 65536 };
static void fill(tex_t *t, void *mem, uint8_t v) {
    uint8_t linear[SIZE * SIZE * 4];
    for (int i = 0; i < SIZE * SIZE; i++) { linear[i * 4] = v; linear[i * 4 + 1] = v + 1; linear[i * 4 + 2] = v + 2; linear[i * 4 + 3] = 255; }
    CHECK("fixture swizzle succeeds", !nvn_swizzle(&t->d, 0, 0, linear, SIZE * 4, mem));
}
static uint8_t first_red(id<MTLTexture> image) {   // the red of texel (3, 5), read through a blit: the texture is private
    static id<MTLCommandQueue> queue; if (!queue) queue = [g_dev newCommandQueue];
    id<MTLBuffer> out = [g_dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
    if (!image || !out) { fprintf(stderr, "nothing to read back\n"); return 0; }
    id<MTLCommandBuffer> cb = [queue commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:image.parentTexture ?: image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(3, 5, 0) sourceSize:MTLSizeMake(1, 1, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4];
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK("readback completes", cb.status == MTLCommandBufferStatusCompleted);
    return *(uint8_t *)out.contents;
}
static id<MTLTexture> resolve(tex_t *t) { mtl_sub_begin(); id<MTLTexture> image = tex_mtl(t); CHECK("texture resolves", image != nil); finish(); return image; }
typedef struct { void *mem; pool_t pool; tex_t t; } fixture;
static void setup(fixture *f, uint64_t serial, uint32_t pool_flags, int format, uint32_t tex_flags) {
    if (posix_memalign(&f->mem, getpagesize(), POOL)) abort();
    memset(f->mem, 0, POOL);
    f->pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .mem = f->mem, .size = POOL, .flags = pool_flags};
    mtl_pool_add(f->mem, POOL);
    f->t = (tex_t){.magic = MAGIC('T', 'E', 'X', 0), .serial = serial, .pool = &f->pool, .mem = f->mem};
    f->t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = SIZE, .height = SIZE, .depth = 1, .levels = 1, .samples = 1, .flags = tex_flags};
    nvn_tex_layout(&f->t.d, &f->t.L);
}
static void teardown(fixture *f) { mtl_tex_release(&f->t); mtl_alias_drop_pool(&f->pool); mtl_pool_del(f->mem); mtl_drain(); free(f->mem); }
static const uint32_t CACHED = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED;
// The terrain cases (gws spans, gsb_store): textures of several whole pages in a 1 MB pool the dirty-page tracker covers, as the game's pools are
enum { BIG = 1 << 20 };
typedef struct { void *mem; pool_t pool; } bigpool;
static void big_setup(bigpool *b) {
    if (posix_memalign(&b->mem, getpagesize(), BIG)) abort();
    memset(b->mem, 0, BIG);
    b->pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .mem = b->mem, .size = BIG, .flags = CACHED};
    mtl_pool_add(b->mem, BIG); nvn_dirty_add_range(b->mem, BIG);
}
static tex_t big_tex(bigpool *b, uint64_t serial, size_t off, unsigned size, int format, unsigned levels) {
    tex_t t = (tex_t){.magic = MAGIC('T', 'E', 'X', 0), .serial = serial, .pool = &b->pool, .mem = (uint8_t *)b->mem + off};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = size, .height = size, .depth = 1, .levels = levels, .samples = 1};
    nvn_tex_layout(&t.d, &t.L); return t;
}
static uint8_t stored_red(const tex_t *t) {   // the red of texel (3, 5) of level 0, as the storage holds it
    uint8_t *lin = malloc((size_t)t->d.width * t->d.height * 4);
    CHECK("fixture deswizzle succeeds", !nvn_deswizzle(&t->d, 0, 0, t->mem, lin, t->d.width * 4));
    uint8_t red = lin[(5 * t->d.width + 3) * 4]; free(lin); return red;
}
static void gpu_clear(tex_t *t, float red) {   // a texture clear: recorded (its storage's span is stamped), replayed, completed
    mtl_tex_gpu_written(t);
    p_clear_tex c = {.tex = t, .r = {0, 0, 0, (int)t->d.width, (int)t->d.height, 1}, .mask = 15, .c.f = {red, 0, 0, 1}};
    mtl_sub_begin(); clear_tex(&c); finish();
}

int main(void) {
    @autoreleasepool {
        mtl_init();
        fixture f;
        setup(&f, 7001, CACHED, NVN_FORMAT_RGBA8, 0);
        fill(&f.t, f.mem, 40);
        mtl_tex_init(&f.t);
        CHECK("at first use the storage is the content", first_red(resolve(&f.t)) == 40);
        dm_guest_write_prepare(f.mem, f.t.L.size); fill(&f.t, f.mem, 80);
        CHECK("a later CPU write is uploaded", first_red(resolve(&f.t)) == 80);
        { tex_t rt = f.t; rt.serial = 7101; mtl_tex_gpu_written(&rt); }   // another texture over the same storage, rendered into
        CHECK("at the first GPU write over its storage it keeps the content it has", first_red(resolve(&f.t)) == 80);
        CHECK("and is no longer CPU-written", !tex_cpu_written(f.t.serial));
        dm_guest_write_prepare(f.mem, f.t.L.size); fill(&f.t, f.mem, 120);
        CHECK("and a CPU write is no longer uploaded", first_red(resolve(&f.t)) == 80);
        teardown(&f);

        setup(&f, 7002, CACHED, NVN_FORMAT_RGBA8, 0);
        mtl_tex_gpu_written(&f.t);
        fill(&f.t, f.mem, 40);
        CHECK("over storage the GPU writes it is not taken from storage", !tex_cpu_content(&f.t));
        teardown(&f);

        setup(&f, 7004, CACHED, NVN_FORMAT_RGBA8, 0);
        { tex_t rt = f.t; rt.serial = 7104; rt.mem = (uint8_t *)f.mem + POOL / 2; mtl_tex_gpu_written(&rt); }   // a render target in the second half of the pool
        fill(&f.t, f.mem, 40);
        mtl_tex_init(&f.t);
        CHECK("a GPU write elsewhere in its pool leaves its storage the content", first_red(resolve(&f.t)) == 40);
        teardown(&f);

        setup(&f, 7003, CACHED, NVN_FORMAT_RGBA8, 0);
        CHECK("storage of zeros is not taken", !tex_cpu_content(&f.t));
        teardown(&f);

        static const struct { const char *label; int format; uint32_t flags; } left_out[] = {
            {"a display texture stays a GPU texture", NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_DISPLAY},
            {"a video-decode texture stays a GPU texture", NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_VIDEO_DECODE},
            {"a shader image stays a GPU texture", NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_IMAGE},
            {"a compressible texture stays a GPU texture", NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE},
            {"a depth texture stays a GPU texture", NVN_FORMAT_DEPTH32F, 0},
        };
        for (unsigned i = 0; i < sizeof left_out / sizeof *left_out; i++) {
            setup(&f, 7010 + i, CACHED, left_out[i].format, left_out[i].flags);
            memset(f.mem, 0x55, f.t.L.size);
            CHECK(left_out[i].label, !tex_cpu_content(&f.t));
            teardown(&f);
        }

        // What the GPU draws into a GPU texture in storage the CPU can read reaches that storage (gsb_store), and storage the CPU rewrote after the GPU's write is taken again (gws spans):
        // Ocarina of Time moves the terrain normal tiles the GPU drew with memcpy and makes them again at the new address, where they were zeros or another tile ("plaid" ground)
        bigpool bp; big_setup(&bp);
        tex_t tile = big_tex(&bp, 7201, 0x40000, 128, NVN_FORMAT_RGBA8, 1);
        uint64_t stores = g_gsb_stores;
        gpu_clear(&tile, 0.2f);
        CHECK("a clear of a GPU texture reaches its storage", stored_red(&tile) == 51 && g_gsb_stores == stores + 1);
        CHECK("which stays the GPU's", gpuw_overlaps((uintptr_t)tile.mem, (uintptr_t)tile.mem + tile.L.size) && !tex_cpu_written(tile.serial));
        tex_t old = big_tex(&bp, 7202, 0x80000, 128, NVN_FORMAT_RGBA8, 1);   // the slot the tile moves to held a tile the GPU drew
        gpu_clear(&old, 0.6f); mtl_tex_release(&old);
        tex_t moved = big_tex(&bp, 7203, 0x80000, 128, NVN_FORMAT_RGBA8, 1);
        dm_guest_write_prepare(moved.mem, moved.L.size); memcpy(moved.mem, tile.mem, tile.L.size);
        CHECK("moved with memcpy over storage the GPU drew before: a texture made there holds the move", first_red(resolve(&moved)) == 51 && tex_cpu_written(moved.serial));
        gpu_clear(&tile, 0.4f);
        CHECK("a write the frame after another is in the storage at once", stored_red(&tile) == 102);
        tex_t moved2 = big_tex(&bp, 7204, 0xc0000, 128, NVN_FORMAT_RGBA8, 1);
        dm_guest_write_prepare(moved2.mem, moved2.L.size); memcpy(moved2.mem, tile.mem, tile.L.size);
        CHECK("a memcpy right after it gives a texture with that write", first_red(resolve(&moved2)) == 102);
        p_clear_tex part = {.tex = &tile, .r = {8, 8, 0, 40, 24, 1}, .mask = 15, .c.f = {0.8f, 0, 0, 1}};
        mtl_tex_gpu_written(&tile); mtl_sub_begin(); clear_tex(&part); finish();
        { uint8_t *lin = malloc(128 * 128 * 4); int bad = nvn_deswizzle(&tile.d, 0, 0, tile.mem, lin, 128 * 4);
          for (int y = 0; y < 128 && !bad; y++) for (int x = 0; x < 128; x++) bad += lin[(y * 128 + x) * 4] != ((x >= 8 && x < 48 && y >= 8 && y < 32) ? 204 : 102);
          CHECK("a cleared region reaches the storage, and only its texels", !bad); free(lin); }
        tex_t img = big_tex(&bp, 7205, 0x40000, 128, NVN_FORMAT_RGBA8, 1); img.d.flags = NVN_TEXTURE_FLAGS_IMAGE;
        uint64_t before = g_gsb_stores; gpu_clear(&img, 0.6f);
        CHECK("an image's clear is not stored", g_gsb_stores == before);
        mtl_tex_release(&img);
        // Ocarina of Time's normal tiles: 260x260 RG8, 9 levels, rows of 520 bytes (no multiple of 16), smaller block heights in the small levels
        tex_t nt = big_tex(&bp, 7206, 0x00000, 260, NVN_FORMAT_RG8, 9);
        CHECK("the tile fits below the others", nt.L.size <= 0x40000);
        mtl_tex_gpu_written(&nt); mtl_sub_begin();
        for (unsigned lv = 0; lv < 9; lv++) {
            p_clear_tex tc = {.tex = &nt, .has_view = 1, .r = {0, 0, 0, (int)MAX(260u >> lv, 1u), (int)MAX(260u >> lv, 1u), 1}, .mask = 15, .c.f = {(float)(lv + 1) / 51.f, 0.2f, 0, 1}};
            tc.view.set_levels = 1; tc.view.base_level = lv; clear_tex(&tc);
        }
        finish();
        { uint8_t *lin = malloc(260 * 260 * 2); int bad = 0;
          for (unsigned lv = 0; lv < 9; lv++) { unsigned w = MAX(260u >> lv, 1u);
              memset(lin, 0xEE, 260 * 260 * 2); bad += nvn_deswizzle(&nt.d, lv, 0, nt.mem, lin, w * 2) ? 1000 : 0;
              for (unsigned i = 0; i < w * w; i++) bad += lin[i * 2] != (lv + 1) * 5 || lin[i * 2 + 1] != 51; }
          CHECK("every level of a 260x260 RG8 9-level tile reaches its storage, every texel", !bad); free(lin); }
        mtl_tex_release(&nt); mtl_tex_release(&moved2); mtl_tex_release(&moved); mtl_tex_release(&tile);
        mtl_alias_drop_pool(&bp.pool); mtl_pool_del(bp.mem); nvn_dirty_remove_range(bp.mem); mtl_drain(); free(bp.mem);
    }
    printf("t_cpu_storage: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
