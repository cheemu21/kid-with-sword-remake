// Memory pressure mode (nvn_mtl.m mem_hot_next, kid-with-sword-remake L8.1): on at the footprint threshold or under the room threshold, off 300 MB under both, never without a
// threshold, and the Mac (room unknown) decided by the footprint alone
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
    mem_hot_cfg c = {4600, 3000};
    CHECK(!mem_hot_next(0, 4000, 5000, c), "under both thresholds: off");
    CHECK(mem_hot_next(0, 4600, 5000, c), "at the footprint threshold: on");
    CHECK(mem_hot_next(0, 4000, 2999, c), "under the room threshold: on");
    CHECK(mem_hot_next(1, 4400, 5000, c), "on, 200 MB under the footprint threshold: stays on");
    CHECK(!mem_hot_next(1, 4299, 3301, c), "on, more than 300 MB under both: off");
    CHECK(mem_hot_next(1, 4000, 3200, c), "on, room back over its threshold by less than 300 MB: stays on");
    CHECK(!mem_hot_next(0, 5500, -1, (mem_hot_cfg){4600, 3000}) == 0, "the Mac (room unknown): the footprint decides");
    CHECK(!mem_hot_next(0, 4000, -1, c), "the Mac under the footprint threshold: off");
    CHECK(!mem_hot_next(0, 9000, 100, (mem_hot_cfg){0, 3000}), "DM_NVN_MEM_HIGH_MB=0: never on");
    CHECK(!placed_parent_on(), "a placed texture's heap stands for it by default (DM_NVN_RES_PLACED_PARENT)");
    printf("t_mem_pressure: %d checks, %d failed\n", checks, failures);
    return failures != 0;
} }
