// The set of CPU-written textures (mtl_tex_cpu_written, tex_cpu_written, mtl_tex_release): membership, no duplicates, a released texture leaving it, and lookups of textures
// not in it staying cheap with thousands of consecutive serials in it (a CFSet that hashed serials as numbers probed a whole bucket run per miss: half of Batman: Arkham Knight's
// rendering thread with 6,442 CPU-written textures)
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

static void retired_classification(void) {
    uint8_t mem[2]; pool_t pools[2] = {{.mem=&mem[0]}, {.mem=&mem[1]}};
    tex_t a = {.serial=nvn_new_serial(), .pool=&pools[0], .mem=&mem[0]};
    tex_t b = {.serial=nvn_new_serial(), .pool=&pools[1], .mem=&mem[1]};
    mtl_tex_init(&a); mtl_tex_init(&b);
    mtl_tex_cpu_written(&a); mtl_tex_cpu_written(&b);
    mtl_tex_release(&a);
    CHECK(mtl_cpu_tex_count() == 1 && !nvn_hm_get(&g_cpu_tex,&a.serial), "release removes live membership");
    CHECK(tex_cpu_written(a.serial), "recorded snapshots retain CPU classification");
    uint64_t gen = g_ser_gen; mtl_tex_cpu_written(&a);
    CHECK(mtl_cpu_tex_count() == 1 && g_ser_gen == gen, "late repeated marking cannot resurrect a released texture");
    mtl_alias_drop_pool(&pools[0]);
    CHECK(!tex_cpu_written(a.serial) && tex_cpu_written(b.serial), "pool cleanup preserves the other pool's live membership");
    // A poll may first discover CPU writes after another thread finalized the texture.
    tex_t late = {.serial=nvn_new_serial(), .pool=&pools[1], .mem=&mem[1]};
    mtl_tex_init(&late); mtl_tex_release(&late); gen = g_ser_gen; mtl_tex_cpu_written(&late);
    CHECK(tex_cpu_written(late.serial) && mtl_cpu_tex_count() == 1 && g_ser_gen == gen+1, "first marking after release records only retired classification");
    mtl_tex_release(&b); mtl_tex_release(&b);
    CHECK(mtl_cpu_tex_count() == 0 && tex_cpu_written(b.serial), "repeated release keeps retired snapshots classified");
    mtl_alias_drop_pool(&pools[1]);
    CHECK(!tex_cpu_written(b.serial) && !tex_cpu_written(late.serial) && !g_cpu_tex_retired.n, "pool cleanup removes all retired classifications");
}
static void descriptor_replacement(void) {
    tex_t a = {.serial=nvn_new_serial()}, b = {.serial=nvn_new_serial()};
    mtl_tex_init(&a); mtl_tex_init(&b);
    mtl_reg_tex(1,&a,NULL); mtl_reg_tex(2,&a,NULL); mtl_reg_tex(3,&a,NULL);
    mtl_reg_tex(2,&b,NULL); mtl_reg_tex(3,NULL,NULL);
    mtl_tex_release(&a);
    CHECK(g_treg[1].retired && !g_treg[2].retired && !g_treg[3].ok, "replacing middle and head descriptors preserves serial ownership");
    mtl_reg_tex(1,&b,NULL); mtl_reg_tex(2,NULL,NULL);
    CHECK(!nvn_hm_get(&g_treg_serial,&a.serial), "replacing the last descriptor removes the old serial");
    mtl_tex_release(&b);
    CHECK(g_treg[1].retired, "the replacement texture retires its current descriptors");
    mtl_reg_tex(1,NULL,NULL);
    CHECK(!g_treg_serial.n, "clearing descriptors removes serial links");
}
static void finalized_upload(int write_after_record) {
    const size_t len = 262144;
    uint8_t *mem = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (mem == MAP_FAILED) abort();
    pool_t pool = {0}; pool_builder_t pb = {.mem=mem, .size=len, .flags=NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&pool, (const NVNmemoryPoolBuilder *)&pb), "CPU-cached pool initialized");
    NVNtextureBuilder tb; NVNtexture tex = {0}; h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetWidth(&tb, 4); h_nvnTextureBuilderSetHeight(&tb, 4); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&pool, 65536);
    CHECK(h_nvnTextureInitialize(&tex, &tb), "texture without packaged layout initialized");
    uint64_t serial = ((tex_t *)&tex)->serial;
    uint8_t pixels[64]; for (int i=0;i<64;i++) pixels[i]=(uint8_t)(i+32);
    NVNcopyRegion region = {0,0,0,4,4,1};
    if (!write_after_record) h_nvnTextureWriteTexels(&tex, NULL, &region, pixels);
    mtl_reg_tex(1, (const tex_t *)&tex, NULL);
    NVNcommandBuffer cmd; CHECK(h_nvnCommandBufferInitialize(&cmd, NULL), "command buffer initialized");
    h_nvnCommandBufferAddCommandMemory(&cmd, (const NVNmemoryPool *)&pool, 0, 65536); h_nvnCommandBufferBeginRecording(&cmd);
    h_nvnCommandBufferCopyTextureToBuffer(&cmd, &tex, NULL, &region, (uint64_t)mem+131072, 0);
    NVNcommandHandle handle = h_nvnCommandBufferEndRecording(&cmd);
    if (write_after_record) h_nvnTextureWriteTexels(&tex, NULL, &region, pixels);
    // Cached descriptor views must not own every upload after its API object
    // is finalized. Two IDs and a compatible view exercise all lookup caches.
    mtl_reg_tex(2, (const tex_t *)&tex, NULL);
    mtl_sub_begin();
    id<MTLTexture> before = tex_by_id(1), second = tex_by_id(2); uint64_t compatible_id = 0;
    CHECK(before && second && g_treg[1].view && g_treg[2].view, "live descriptors cache their texture");
    CHECK(tex_fit(2, second, MTLTextureType2DArray, &compatible_id) && g_treg[2].alt, "live descriptor caches a compatible view");
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull), "initial descriptor uploads completed");
    h_nvnTextureFinalize(&tex);
    CHECK(mtl_cpu_tex_count() == 0, "finalized texture leaves the live CPU set");
    CHECK(!g_treg[1].view && !g_treg[2].view && !g_treg[2].alt, "finalization retires every descriptor's cached views");
    // Reuse the API object: commands and registered descriptors must use their snapshots.
    memset(&tex, 0xa5, sizeof tex);
    state_reset(); memset(&R,0,sizeof R); mtl_sub_begin(); mtl_exec((const uint8_t *)handle);
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull), "recorded texture readback completed");
    CHECK(!mtl_last_commit_error(), "recorded texture readback has no GPU error");
    CHECK(!memcmp(mem+131072, pixels, sizeof pixels), "finalized command snapshot uploads CPU-written pixels");
    mtl_sub_begin(); id<MTLTexture> registered = tex_by_id(1);
    CHECK(registered && registered.width == 4, "finalized registered descriptor resolves a Metal texture");
    CHECK(tex_fit(2, tex_by_id(2), MTLTextureType2DArray, &compatible_id), "late compatible view resolves");
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull), "registered descriptor upload completed");
    CHECK(!g_treg[1].view && !g_treg[2].view && !g_treg[2].alt, "late descriptor views retire at submission end");
    // Resolve again: a retired serial may already hold an NvPkg in the ghost cache.
    mtl_sub_begin(); mtl_exec((const uint8_t *)handle);
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull), "recorded snapshot can be replayed again");
    CHECK(!memcmp(mem+131072, pixels, sizeof pixels), "replayed retired snapshot keeps its CPU content");
    mtl_reg_tex(1,NULL,NULL); mtl_reg_tex(2,NULL,NULL); h_nvnCommandBufferFinalize(&cmd);
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&pool);
    CHECK(!tex_cpu_written(serial), "pool finalization drops retired CPU classification");
    defer_drain(); munmap(mem,len);
}
// Texture objects over the same storage and description share one packaged texture (g_pkg_share): one upload, one Metal texture, and a pool's finalization drops the entry
static void shared_storage_upload(void) {
    const size_t len = 262144;
    uint8_t *mem = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (mem == MAP_FAILED) abort();
    pool_t pool = {0}; pool_builder_t pb = {.mem=mem, .size=len, .flags=NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&pool, (const NVNmemoryPoolBuilder *)&pb), "shared storage: pool initialized");
    NVNtextureBuilder tb; NVNtexture a = {0}, b = {0}; h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetWidth(&tb, 4); h_nvnTextureBuilderSetHeight(&tb, 4); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&pool, 65536);
    CHECK(h_nvnTextureInitialize(&a, &tb) && h_nvnTextureInitialize(&b, &tb), "shared storage: two texture objects over one storage");
    uint8_t pixels[64]; for (int i = 0; i < 64; i++) pixels[i] = (uint8_t)(i * 3 + 1);
    NVNcopyRegion region = {0,0,0,4,4,1};
    h_nvnTextureWriteTexels(&a, NULL, &region, pixels); h_nvnTextureWriteTexels(&b, NULL, &region, pixels);
    mtl_reg_tex(1, (const tex_t *)&a, NULL); mtl_reg_tex(2, (const tex_t *)&b, NULL);
    uint64_t up = g_pkg_uploads;
    mtl_sub_begin();
    id<MTLTexture> ta = tex_by_id(1), tb2 = tex_by_id(2);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "shared storage: uploads completed");
    CHECK(ta && tb2 && (ta == tb2 || ta.parentTexture == tb2 || tb2.parentTexture == ta || (ta.parentTexture && ta.parentTexture == tb2.parentTexture)), "shared storage: both IDs read one Metal texture");
    CHECK(g_pkg_uploads == up + 1, "shared storage: one upload for both serials");
    mtl_reg_tex(1, NULL, NULL); mtl_reg_tex(2, NULL, NULL);
    h_nvnTextureFinalize(&a); h_nvnTextureFinalize(&b);
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&pool);
    alias_key k = tex_alias_key((const tex_t *)&a); pthread_mutex_lock(&g_smu); int left = hm_get_id(&g_pkg_share, &k) != nil; pthread_mutex_unlock(&g_smu);
    CHECK(!left, "shared storage: the pool's finalization drops its sharing entries");
    defer_drain(); munmap(mem, len);
}
static void finalized_bindless_pool(void) {
    enum { N = NGHOST + 16, FIRST = 256, STRIDE = 4096 };
    const size_t len = N * STRIDE;
    uint8_t *mem = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (mem == MAP_FAILED) abort();
    NVNmemoryPool pool = {0};
    pool_builder_t pb = {.mem = mem, .size = len, .flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize(&pool, (const NVNmemoryPoolBuilder *)&pb), "bindless texture storage initialized");
    NVNtextureBuilder tb; h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetWidth(&tb, 4); h_nvnTextureBuilderSetHeight(&tb, 4); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
    NVNcopyRegion region = {0, 0, 0, 4, 4, 1};
    uint8_t pixels[64]; memset(pixels, 0x7e, sizeof pixels);
    int initialized = 1;
    for (int i = 0; i < N; i++) {
        NVNtexture tex = {0};
        h_nvnTextureBuilderSetStorage(&tb, &pool, (ptrdiff_t)i * STRIDE);
        initialized &= h_nvnTextureInitialize(&tex, &tb);
        h_nvnTextureWriteTexels(&tex, NULL, &region, pixels);
        mtl_reg_tex(FIRST + i, (const tex_t *)&tex, NULL);
        h_nvnTextureFinalize(&tex);
    }
    CHECK(initialized, "all retired descriptors have valid storage");
    mtl_sub_begin();
    uint64_t uploads = g_pkg_uploads;
    __unsafe_unretained id<MTLBuffer> a = nil, b = nil;
    os_unfair_lock_lock(&g_rmu);
    pool_gpu(0, MTLTextureType2D, NVN_DPF_FLOAT, 0, &a);
    uint64_t first = ((const uint64_t *)((const char *)a.contents + DMSH_POOL_HEAD))[FIRST];
    CHECK(g_pkg_uploads == uploads + N && g_ghost_active.n == N, "one upload per retired descriptor in the first pool walk");
    pool_gpu(0, MTLTextureType2D, NVN_DPF_FLOAT, 0, &b);
    uint64_t again = ((const uint64_t *)((const char *)b.contents + DMSH_POOL_HEAD))[FIRST];
    os_unfair_lock_unlock(&g_rmu);
    CHECK(first == again && g_pkg_uploads == uploads + N, "rebuilding the pool preserves textures that spilled out of the ghost ring");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "bindless pool uploads completed");
    CHECK(!g_ghost_active.n && g_ghost.n == NGHOST && !g_treg[FIRST].view, "submission drops its pins and transient views and keeps the bounded ghost cache");
    for (int i = 0; i < N; i++) mtl_reg_tex(FIRST + i, NULL, NULL);
    h_nvnMemoryPoolFinalize(&pool);
    defer_drain(); munmap(mem, len);
}
// Pool table buffers (ptb_get / ptb_retire): a retired table is reused only after the GPU has completed its fence, only at the same length, stays resident while kept,
// and past PTB_KEEP the oldest goes to the deferred release (Ocarina of Time's Kokiri Forest made 2-3 new 265 KB tables a frame, each added to and removed from the residency set)
static int resident(id o) { pthread_mutex_lock(&g_res_mu); int r = [g_res_objects containsObject:o]; pthread_mutex_unlock(&g_res_mu); return r; }
static void ptb_recycle(void) {
    uint64_t fence0 = atomic_load(&g_fence), done0 = atomic_load(&g_done), made0 = g_stat_ptb_made, reused0 = g_stat_ptb_reused;
    atomic_store(&g_done, fence0);   // everything before is complete
    id<MTLBuffer> a = ptb_get(4096);
    CHECK(a && a.length == 4096 && resident(a) && g_stat_ptb_made == made0 + 1, "a new table buffer is made resident");
    ptb_retire(a);
    atomic_store(&g_fence, fence0 + 1);   // the submission that may read it is committed, not complete
    id<MTLBuffer> b = ptb_get(4096);
    CHECK(b && b != a && g_stat_ptb_reused == reused0, "a table the GPU may still read is not reused");
    atomic_store(&g_done, fence0 + 1);
    id<MTLBuffer> c = ptb_get(8192);
    CHECK(c != a && c.length == 8192, "a retired table is not reused at another length");
    id<MTLBuffer> d = ptb_get(4096);
    CHECK(d == a && resident(d) && g_stat_ptb_reused == reused0 + 1, "once its fence completes the retired table is reused, still resident");
    ptb_retire(b); ptb_retire(c); ptb_retire(d);
    size_t deferred0; pthread_mutex_lock(&g_deferred_mu); deferred0 = g_deferred.count; pthread_mutex_unlock(&g_deferred_mu);
    int kept = g_nptb;
    for (int i = 0; i < PTB_KEEP; i++) { id<MTLBuffer> e = [g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared]; res_add(e); ptb_retire(e); }
    size_t deferred1; pthread_mutex_lock(&g_deferred_mu); deferred1 = g_deferred.count; pthread_mutex_unlock(&g_deferred_mu);
    CHECK(g_nptb == PTB_KEEP && deferred1 == deferred0 + (size_t)kept, "past PTB_KEEP the oldest retired tables go to the deferred release");
    while (g_nptb) { defer_obj_release(g_ptb[--g_nptb].b); g_ptb[g_nptb].b = nil; }
    atomic_store(&g_fence, fence0); atomic_store(&g_done, done0);
}
// nvnMemoryPoolFinalize on a game thread while the submit thread walks the texture IDs (pool_gpu, holding g_rmu): the finalize dropped the pool's CPU-written classification before it
// marked the pool's IDs gone, so a walk in between found a live ID, a pool still set and a texture no longer CPU-written, and tex_mtl_ handed out its packaged entry (an NvPkg) as the
// texture: "-[NvPkg buffer]: unrecognized selector" in tex_by_id (Ocarina of Time, reference/nvn-objects.md). Here the test holds g_rmu as the walk does while another thread finalizes
static void *finalize_pool(void *pool) { h_nvnMemoryPoolFinalize((NVNmemoryPool *)pool); return NULL; }
static void finalize_during_walk(void) {
    const size_t len = 262144;
    uint8_t *mem = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (mem == MAP_FAILED) abort();
    pool_t pool = {0}; pool_builder_t pb = {.mem=mem, .size=len, .flags=NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&pool, (const NVNmemoryPoolBuilder *)&pb), "CPU-cached pool initialized");
    NVNtextureBuilder tb; NVNtexture tex = {0}; h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetWidth(&tb, 4); h_nvnTextureBuilderSetHeight(&tb, 4); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&pool, 65536);
    CHECK(h_nvnTextureInitialize(&tex, &tb), "texture initialized");
    uint64_t serial = ((tex_t *)&tex)->serial;
    uint8_t pixels[64]; for (int i=0;i<64;i++) pixels[i]=(uint8_t)(i+32);
    NVNcopyRegion region = {0,0,0,4,4,1};
    h_nvnTextureWriteTexels(&tex, NULL, &region, pixels);
    mtl_reg_tex(1, (const tex_t *)&tex, NULL);
    mtl_sub_begin();
    os_unfair_lock_lock(&g_rmu);
    id<MTLTexture> first = tex_by_id(1);
    CHECK(first && first.width == 4, "the packaged texture resolves");
    CHECK([tex_get(serial) isKindOfClass:[NvPkg class]], "its table entry is an NvPkg");
    pthread_t th; pthread_create(&th, NULL, finalize_pool, &pool);
    usleep(100000);   // the finalize runs as far as it can while the walk holds g_rmu
    CHECK(tex_cpu_written(serial), "the pool's classification stays while a walk can still find its IDs live");
    id again = tex_mtl((const tex_t *)&tex);
    CHECK(again && ![again isKindOfClass:[NvPkg class]], "tex_mtl does not hand out the NvPkg during the finalize");
    os_unfair_lock_unlock(&g_rmu);
    pthread_join(th, NULL);
    CHECK(!tex_cpu_written(serial) && g_treg[1].gone, "after the finalize the ID is gone and the classification dropped");
    os_unfair_lock_lock(&g_rmu); id after = tex_by_id(1); os_unfair_lock_unlock(&g_rmu);
    CHECK(![after isKindOfClass:[NvPkg class]], "the gone ID does not hand out the NvPkg either");
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull), "submission completed");
    mtl_reg_tex(1,NULL,NULL); h_nvnTextureFinalize(&tex);
    defer_drain(); munmap(mem,len);
}
// The kinds and levels of the GPU's writes are kept per texture (tex_gpu_wrote_lv) and decide its ownership (mtl_tex_gpu_owned): never written, the CPU's; written, the GPU's
static void gpu_written_levels(void) {
    tex_t t = {.serial=nvn_new_serial()}; t.d.width = t.d.height = 64; t.d.depth = 1; t.d.levels = 4; t.d.format = 0x25; mtl_tex_init(&t);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:YES];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d]; CHECK(mt != nil, "render-target texture made"); if (!mt) return;
    tex_put(t.serial, mt);
    CHECK(!mtl_tex_gpu_owned(t.serial) && !mtl_tex_gpu_levels(t.serial), "never written: the CPU's");
    tex_gpu_wrote_lv(&t, GW_ATTACH, 1); tex_gpu_wrote_lv(&t, GW_ATTACH, 3);
    CHECK(mtl_tex_gpu_writes(t.serial) == GW_ATTACH && mtl_tex_gpu_levels(t.serial) == 0xa && mtl_tex_gpu_owned(t.serial), "the kinds and the levels written are kept apart; written, the GPU's");
    tex_t u = {.serial=nvn_new_serial()}; u.d = t.d; mtl_tex_init(&u); tex_put(u.serial, mt);
    tex_gpu_wrote(&u, GW_IMAGE);
    CHECK(mtl_tex_gpu_writes(u.serial) == GW_IMAGE && (mtl_tex_gpu_levels(u.serial) & 0xf) == 0xf, "a write of levels not known counts for every level");
    mtl_tex_release(&t); mtl_tex_release(&u);
    CHECK(!mtl_tex_gpu_writes(t.serial) && !mtl_tex_gpu_levels(u.serial), "released: nothing kept");
}
int main(int argc, const char **argv) { @autoreleasepool {
    enum { N = 6442, BASE = 1000 };
    static tex_t t[N];
    for (int i = 0; i < N; i++) { t[i].serial = BASE + i; t[i].d.width = t[i].d.height = 4; t[i].d.depth = 1; t[i].d.format = 0x25; mtl_tex_init(&t[i]); }
    CHECK(mtl_cpu_tex_count() == 0 && !tex_cpu_written(BASE), "empty at start");
    for (int i = 0; i < N; i++) mtl_tex_cpu_written(&t[i]);
    mtl_tex_cpu_written(&t[7]);   // again: no duplicate
    CHECK(mtl_cpu_tex_count() == N, "every CPU-written texture counted once");
    int in = 0; for (int i = 0; i < N; i++) in += tex_cpu_written(BASE + i);
    CHECK(in == N, "every one found");
    CHECK(!tex_cpu_written(BASE - 1) && !tex_cpu_written(BASE + N) && !tex_cpu_written(0), "serials outside the set are not in it");
    // Misses: a million lookups of serials past the set, as every resolve of a GPU-only texture asks. With the old set's probing this took seconds; with a mixed hash, far less
    uint64_t t0 = bp_now(); int hits = 0;
    for (int i = 0; i < 1000000; i++) hits += tex_cpu_written(BASE + N + 1 + (uint64_t)i);
    double ms = (bp_now() - t0) / 1e6;
    printf("1,000,000 lookups of serials not in a set of %d consecutive ones: %.1f ms\n", N, ms);
    CHECK(hits == 0, "no miss is reported as a hit");
    CHECK(ms < 1000, "a million misses take well under a second");
    mtl_tex_release(&t[100]); mtl_tex_release(&t[101]);
    CHECK(!tex_cpu_written(BASE + 100) && !tex_cpu_written(BASE + 101) && tex_cpu_written(BASE + 102), "a released texture leaves the set, the others stay");
    CHECK(mtl_cpu_tex_count() == N - 2, "the count follows the releases");
    tex_t z = {0}; mtl_tex_cpu_written(&z);
    CHECK(mtl_cpu_tex_count() == N - 2, "a texture with no serial is not recorded");
    for (int i=0;i<N;i++) mtl_tex_release(&t[i]);
    // NVNtexture is plain data: finalizing a copy ends the copy. The texture stays live while the object it was initialized in holds it; if that object no longer does, the copy was the last one
    static tex_t own, cpy, moved;
    own.magic = MAGIC('T', 'E', 'X', 0); own.serial = 900001; own.d = t[0].d; mtl_tex_init(&own); mtl_tex_cpu_written(&own);
    cpy = own; mtl_tex_release(&cpy);
    CHECK(tex_cpu_written(own.serial) == 1, "finalizing a copy leaves the texture live");
    mtl_tex_release(&own);
    CHECK(!nvn_hm_get(&g_tex_live, &own.serial), "finalizing the object itself ends it");
    own.serial = 900002; mtl_tex_init(&own); moved = own; own.magic = 0; mtl_tex_release(&moved);
    CHECK(!nvn_hm_get(&g_tex_live, &moved.serial), "a copy outliving the object it was initialized in ends the texture");
    retired_classification(); descriptor_replacement();
    if (argc > 1 && !strcmp(argv[1], "--metal")) { mtl_init(); finalized_upload(0); finalized_upload(1); shared_storage_upload(); finalized_bindless_pool(); ptb_recycle(); finalize_during_walk(); gpu_written_levels(); }
    printf("t_cpu_tex: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
