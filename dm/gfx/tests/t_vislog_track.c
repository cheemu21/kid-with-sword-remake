// DM_NVN_VISLOG follows a draw of the logged size from recording to submit (hle_nvn.c vislog_rec / vl_begin / vl_end / vl_called, nvn_queue.inc nq_record_one;
// kid-with-sword-remake L7.9, the Goku mod's body): each stage's count, a recording begun again before it ended, and a handle called into another recording.
// CPU only: the real record and submit entries, with the Metal prepare / replay stubbed as in t_gfx_suspend.c
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define mtl_prepare test_prepare
#define mtl_sub_begin test_sub_begin
#define mtl_sub_commit test_sub_commit
#define mtl_queue_activate test_queue_activate
#define mtl_set_queue_origin_lower_left test_queue_origin
#define mtl_exec_rest test_exec_rest
#define mtl_exec test_exec
#define mtl_set_frame test_set_frame
#define mtl_drain test_drain
#include "../nvn/hle_nvn.c"
#undef mtl_prepare
#undef mtl_sub_begin
#undef mtl_sub_commit
#undef mtl_queue_activate
#undef mtl_set_queue_origin_lower_left
#undef mtl_exec_rest
#undef mtl_exec
#undef mtl_set_frame
#undef mtl_drain

module_t *g_mod; int g_nmod;
void *front_metal_layer(void) { return NULL; }
// A stand-in "main" for the piece-entry readout: return addresses in [base, base + 64 MB) are in it
static module_t g_fake_main = { .name = "main", .base = (uint8_t *)(uintptr_t)0x100000000ull };
module_t *module_of(const void *p) { uintptr_t a = (uintptr_t)p, b = (uintptr_t)g_fake_main.base; return a >= b && a < b + (64u << 20) ? &g_fake_main : NULL; }
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
void test_prepare(void) {}
void test_sub_begin(void) {}
uint64_t test_sub_commit(void) { return 0; }
void test_queue_activate(uint64_t serial) { (void)serial; }
void test_queue_origin(int on) { (void)on; }
void test_exec_rest(const uint64_t *handles, int count) { (void)handles; (void)count; }
void test_exec(const uint8_t *commands) { (void)commands; }
void test_set_frame(uint64_t frame) { (void)frame; }
void test_drain(void) {}

static int checks, failures;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failures += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
static uint64_t ld(_Atomic uint64_t *v) { return atomic_load(v); }
static void draw(NVNcommandBuffer *c, int n) { h_nvnCommandBufferDrawElements(c, NVN_DRAW_PRIMITIVE_TRIANGLES, NVN_INDEX_TYPE_UNSIGNED_SHORT, n, 0x10000); }

int main(void) {
    setenv("DM_NVN_VISLOG", "36", 1);
    static uint8_t mem[64 * 1024] __attribute__((aligned(4096)));
    NVNmemoryPoolBuilder mb; NVNmemoryPool mp;
    h_nvnMemoryPoolBuilderSetDefaults(&mb); h_nvnMemoryPoolBuilderSetStorage(&mb, mem, sizeof mem);
    if (!h_nvnMemoryPoolInitialize(&mp, &mb)) { printf("memory pool initialization failed\n"); return 1; }
    NVNcommandBuffer a, b;
    h_nvnCommandBufferInitialize(&a, NULL); h_nvnCommandBufferAddCommandMemory(&a, &mp, 0, 16 * 1024);
    h_nvnCommandBufferInitialize(&b, NULL); h_nvnCommandBufferAddCommandMemory(&b, &mp, 16 * 1024, 16 * 1024);

    // two draws of the logged size and one of another size, in a recording that ends
    h_nvnCommandBufferBeginRecording(&a); draw(&a, 36); draw(&a, 12); draw(&a, 36);
    NVNcommandHandle ha = h_nvnCommandBufferEndRecording(&a);
    CHECK("two draws of the logged size recorded (another size is not)", ld(&dm_vislog_recorded) == 2);
    CHECK("both are in an ended recording", ld(&dm_vislog_ended) == 2);
    CHECK("none begun again unended", ld(&dm_vislog_restarted) == 0);

    // a recording begun again before it ended: its draw is counted as such, not as ended
    h_nvnCommandBufferBeginRecording(&a); draw(&a, 36);
    h_nvnCommandBufferBeginRecording(&a);   // logs a red line (BeginRecording re-entered), as the game would get
    CHECK("a draw in a recording begun again is counted as such", ld(&dm_vislog_restarted) == 1);
    NVNcommandHandle hempty = h_nvnCommandBufferEndRecording(&a);
    CHECK("the recording begun again ends holding none", ld(&dm_vislog_ended) == 2);

    // a handle called into another recording carries its draws there
    h_nvnCommandBufferBeginRecording(&b); h_nvnCommandBufferCallCommands(&b, 1, &ha);
    NVNcommandHandle hb = h_nvnCommandBufferEndRecording(&b);
    CHECK("a called handle's draws end with the recording that called it", ld(&dm_vislog_ended) == 4);
    CHECK("calling records no new draw", ld(&dm_vislog_recorded) == 3);

    // CallCommands counted by call chain, with the calls of a handle holding a draw of the logged size
    int sites = 0; uint64_t calls = 0, marked = 0;
    for (int i = 0; i < VL_SITES; i++) if (g_vl_site[i].n) { sites++; calls += g_vl_site[i].n; marked += g_vl_site[i].marked; }
    CHECK("the call is counted at its call chain, as a call of a marked handle", sites == 1 && calls == 1 && marked == 1);
    NVNcommandBuffer d; h_nvnCommandBufferInitialize(&d, NULL); h_nvnCommandBufferAddCommandMemory(&d, &mp, 32 * 1024, 8 * 1024);
    h_nvnCommandBufferBeginRecording(&d); h_nvnCommandBufferCallCommands(&d, 1, &hempty); h_nvnCommandBufferEndRecording(&d);
    sites = 0; calls = 0; marked = 0;
    for (int i = 0; i < VL_SITES; i++) if (g_vl_site[i].n) { sites++; calls += g_vl_site[i].n; marked += g_vl_site[i].marked; }
    CHECK("a call from another place is another chain, of no marked handle", sites == 2 && calls == 2 && marked == 1);
    dm_vislog_sites_dump("test at", 0);
    sites = 0; for (int i = 0; i < VL_SITES; i++) if (g_vl_site[i].n) sites++;
    CHECK("listing the chains starts a new count", sites == 0);

    // the game's piece entry: a draw whose first game frame returns to main+0x273ba0 names the entry by that frame's saved x21 (index) and x20 (object)
    static uint8_t objmem[0x6a0] __attribute__((aligned(16))); static uint8_t ents[3 * 0x270] __attribute__((aligned(16)));
    uint64_t arr = (uint64_t)(uintptr_t)ents, hv = 0xabc0; uint32_t cmdu = 77, ctlu = 0;
    memcpy(objmem + 0x638, &arr, 8); objmem[0x69c] = 3; objmem[0x69e] = 2;
    memcpy(ents + 0x270 + 0x50, &hv, 8); ents[0x270 + 0x58] = 0x05; memcpy(ents + 0x270 + 0x2c, &cmdu, 4); memcpy(ents + 0x270 + 0x4c, &ctlu, 4);
    static uint64_t gframe[16] __attribute__((aligned(16)));   // 0x27fef0's frame: {x29, x30}, then its saved registers
    gframe[0] = 0; gframe[1] = (uint64_t)(uintptr_t)g_fake_main.base + 0x273ba0; gframe[7] = 1; gframe[8] = (uint64_t)(uintptr_t)objmem;
    static uint64_t own[2] __attribute__((aligned(16))); own[0] = (uint64_t)(uintptr_t)gframe;   // the NVN entry's own frame record: its saved x29 is the game's frame
    h_nvnCommandBufferBeginRecording(&d);
    vislog_rec(&d, 36, (void *)(uintptr_t)((uint64_t)(uintptr_t)g_fake_main.base + 0x27ff80), own);
    CHECK("the draw names its piece entry (object and index)", g_vl_nent == 1 && g_vl_ent[0].obj == (uint64_t)(uintptr_t)objmem && g_vl_ent[0].idx == 1);
    vislog_rec(&d, 36, (void *)(uintptr_t)((uint64_t)(uintptr_t)g_fake_main.base + 0x27ff80), own);
    CHECK("the same entry again is not listed twice", g_vl_nent == 1);
    gframe[1] = (uint64_t)(uintptr_t)g_fake_main.base + 0x2734f0;   // another caller: not the piece entry setup
    vislog_rec(&d, 36, (void *)(uintptr_t)((uint64_t)(uintptr_t)g_fake_main.base + 0x27ff80), own);
    CHECK("a draw from another caller names no entry", g_vl_nent == 1);
    CHECK("the entry is read back", dm_vislog_entries_dump("test at", 0) == 1);
    // the render queue's unit pointing at the entry's object (+0x68), and an element pointing at the unit (+0x10)
    static uint64_t unit[16] __attribute__((aligned(16))), elem[4] __attribute__((aligned(16)));
    unit[0x68 / 8] = (uint64_t)(uintptr_t)objmem; unit[0x54 / 8] = 0x1234; elem[2] = (uint64_t)(uintptr_t)unit;
    uint64_t hits[16]; int nh = vl_scan_refs((uint64_t)(uintptr_t)objmem, (uint64_t)(uintptr_t)objmem - (8u << 20), (uint64_t)(uintptr_t)objmem + (8u << 20), hits, 16), found = 0;
    for (int i = 0; i < nh; i++) if (hits[i] == (uint64_t)(uintptr_t)&unit[0x68 / 8]) found = 1;
    CHECK("the scan finds the unit's pointer to the object", found);
    nh = vl_scan_refs((uint64_t)(uintptr_t)unit, (uint64_t)(uintptr_t)objmem - (8u << 20), (uint64_t)(uintptr_t)objmem + (8u << 20), hits, 16); found = 0;
    for (int i = 0; i < nh; i++) if (hits[i] == (uint64_t)(uintptr_t)&elem[2]) found = 1;
    CHECK("the scan finds the element's pointer to the unit", found);
    CHECK("an unmapped range is skipped, not read", vl_scan_refs(1, 0x1000, 0x200000, hits, 16) == 0);
    CHECK("the dump lists at least that unit", dm_vislog_units_dump("test at", 0) >= 1);
    nh = vl_scan_refs((uint64_t)(uintptr_t)unit, (uint64_t)(uintptr_t)&elem[0], (uint64_t)(uintptr_t)&elem[4], hits, 16);
    CHECK("a range smaller than a page, not on a chunk boundary, is still scanned", nh == 1 && hits[0] == (uint64_t)(uintptr_t)&elem[2]);
    nh = vl_scan_all((uint64_t)(uintptr_t)objmem, (uint64_t)(uintptr_t)objmem - (8u << 20), (uint64_t)(uintptr_t)objmem + (8u << 20), hits, 16); found = 0;
    for (int i = 0; i < nh; i++) if (hits[i] == (uint64_t)(uintptr_t)&unit[0x68 / 8]) found = 1;
    CHECK("the region-by-region scan finds the unit's pointer too", found);
    // a draw unit's program table: slot 0 names row 0 (a program), slot 1 row 1 (none), the other slots -1 (a default program)
    static uint8_t du[0x70] __attribute__((aligned(16))); static uint64_t prog_tab[4] __attribute__((aligned(16)));
    prog_tab[0] = 0x5000; prog_tab[2] = 0;   // rows of 16 bytes: row 0 = {0x5000, 0}, row 1 = {0, 0}
    memset(du + 0x3b, 0xff, 16); du[0x3b] = 0; du[0x3c] = 1; du[0x5f] = 16; uint64_t tp = (uint64_t)(uintptr_t)prog_tab; memcpy(du + 0x60, &tp, 8);
    CHECK("a draw unit with one slot naming a row with no program counts 1", vl_unit_dump((uint64_t)(uintptr_t)du, "test at", 0) == 1);
    prog_tab[2] = 0x6000;
    CHECK("with both rows holding a program it counts 0", vl_unit_dump((uint64_t)(uintptr_t)du, "test at", 0) == 0);
    du[0x5f] = 0;
    CHECK("a structure without a unit's layout is not taken for one", vl_unit_dump((uint64_t)(uintptr_t)du, "test at", 0) == -1);
    CHECK("the queue element naming a unit is found", vl_unit_elements((uint64_t)(uintptr_t)unit, (uint64_t)(uintptr_t)&elem[0], (uint64_t)(uintptr_t)&elem[4], "test at", 0) == 1);
    draw(&d, 36);   // a real record, so the recording holds command memory (the calls above only exercised the hook)
    h_nvnCommandBufferEndRecording(&d);
    unsigned before = atomic_load(&g_vl_used_logs);
    size_t used = h_nvnCommandBufferGetCommandMemoryUsed(&d); size_t ctl = h_nvnCommandBufferGetControlMemoryUsed(&d);
    CHECK("both memory reads after that recording are logged", atomic_load(&g_vl_used_logs) == before + 2);
    CHECK("its command memory used is not 0", used > 0);
    (void)ctl;
    h_nvnCommandBufferBeginRecording(&d); before = atomic_load(&g_vl_used_logs);
    h_nvnCommandBufferGetCommandMemoryUsed(&d);
    CHECK("after a new recording begins, reads are not about it", atomic_load(&g_vl_used_logs) == before);
    h_nvnCommandBufferEndRecording(&d);

    // submit: each draw of the logged size met while the job is built
    NVNqueue q; NVNqueueBuilder qb = {0}; h_nvnQueueBuilderSetDefaults(&qb); h_nvnQueueInitialize(&q, &qb);
    h_nvnQueueSubmitCommands(&q, 1, &ha);
    CHECK("submitting the handle meets its two draws", ld(&dm_vislog_submitted) == 2);
    h_nvnQueueSubmitCommands(&q, 1, &hempty);
    CHECK("an empty recording adds none", ld(&dm_vislog_submitted) == 2);
    h_nvnQueueSubmitCommands(&q, 1, &hb);
    CHECK("the calling recording's submit meets the called draws", ld(&dm_vislog_submitted) == 4);
    h_nvnQueueFinish(&q); h_nvnQueueFinalize(&q);
    printf("t_vislog_track: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}
