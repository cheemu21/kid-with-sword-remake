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
module_t *module_of(const void *p) { (void)p; return NULL; }
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
