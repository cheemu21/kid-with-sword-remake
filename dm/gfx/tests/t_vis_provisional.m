// A samples-passed record that may be read stale reads "visible" (nvn_mtl.m mtl_vis_report_recorded, DM_NVN_VIS_PROVISIONAL, kid-with-sword-remake L7.9): a record never written,
// or one whose previous report has not completed, gets a count of 1 when its report is recorded; a 0 a completed report wrote stays (the object really is hidden), and a count stays
#include "game_profile.h"
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failures;
#define CHECK(c, name) do { int check_ok = !!(c); checks++; failures += !check_ok; printf("%s: %s\n", check_ok ? "PASS" : "FAIL", name); } while (0)
int main(void) { @autoreleasepool {
    static uint64_t rec[8][2] __attribute__((aligned(16)));
    // never written: visible until its report completes, then the real count
    mtl_vis_report_recorded((uint64_t)(uintptr_t)rec[0]);
    CHECK(rec[0][0] == 1, "a record never written reads 1 once its report is recorded");
    rec[0][0] = 0; rec[0][1] = 1234; vis_report_done((uint64_t)(uintptr_t)rec[0]);   // the completion writes a real 0
    mtl_vis_report_recorded((uint64_t)(uintptr_t)rec[0]);
    CHECK(rec[0][0] == 0, "a 0 its last completed report wrote stays 0 (the object is hidden)");
    // a 0 while the previous report on the record is still running: it may be stale
    rec[1][0] = 0; rec[1][1] = 99;
    mtl_vis_report_recorded((uint64_t)(uintptr_t)rec[1]);   // report A, not completed
    CHECK(rec[1][0] == 0, "first report on a record already answered 0: stays 0");
    mtl_vis_report_recorded((uint64_t)(uintptr_t)rec[1]);   // report B while A runs
    CHECK(rec[1][0] == 1, "a 0 read while the previous report still runs reads 1");
    // a count is never touched
    rec[2][0] = 5; rec[2][1] = 7; mtl_vis_report_recorded((uint64_t)(uintptr_t)rec[2]); mtl_vis_report_recorded((uint64_t)(uintptr_t)rec[2]);
    CHECK(rec[2][0] == 5, "a non-zero count is left as it is");
    // completions bring the pending count back: a later real 0 stays
    rec[3][0] = 0; rec[3][1] = 1;
    mtl_vis_report_recorded((uint64_t)(uintptr_t)rec[3]); vis_report_done((uint64_t)(uintptr_t)rec[3]);
    mtl_vis_report_recorded((uint64_t)(uintptr_t)rec[3]);
    CHECK(rec[3][0] == 0, "after its report completed, a record's real 0 stays 0");
    printf("t_vis_provisional: %d checks, %d failed\n", checks, failures);
    return failures != 0;
} }
