// Memory pressure mode (nvn_mtl.m mem_hot_next, kid-with-sword-remake L8.1): on at the footprint threshold or under the room threshold, off 300 MB under both, never without a
// threshold, and the Mac (room unknown) decided by the footprint alone. L8.2 (mem_level_next): the critical level under DM_NVN_MEM_CRIT_MB of room or on iOS's critical report,
// left 300 MB over it, iOS's warning turning the first level on, and nothing at all with DM_NVN_MEM_HIGH_MB=0
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
    CHECK(mem_hot_next(0, 5500, -1, (mem_hot_cfg){4600, 3000}), "the Mac (room unknown): the footprint decides");
    CHECK(!mem_hot_next(0, 4000, -1, c), "the Mac under the footprint threshold: off");
    CHECK(!mem_hot_next(0, 9000, 100, (mem_hot_cfg){0, 3000}), "DM_NVN_MEM_HIGH_MB=0: never on");
    mem_hot_cfg k = {4600, 3000, 1200};
    CHECK(mem_level_next(MEM_NORMAL, 3000, 5000, MEM_NORMAL, k) == MEM_NORMAL, "levels: plenty of room, no report: normal");
    CHECK(mem_level_next(MEM_NORMAL, 3000, 1199, MEM_NORMAL, k) == MEM_CRIT, "levels: room under the critical threshold: critical");
    CHECK(mem_level_next(MEM_NORMAL, 3000, 1200, MEM_NORMAL, k) == MEM_HIGH, "levels: room at the critical threshold: high (under the room threshold)");
    CHECK(mem_level_next(MEM_CRIT, 3000, 1450, MEM_NORMAL, k) == MEM_CRIT, "levels: critical, room back over by less than 300 MB: stays critical");
    CHECK(mem_level_next(MEM_CRIT, 3000, 1500, MEM_NORMAL, k) == MEM_HIGH, "levels: critical, room 300 MB over: down to high");
    CHECK(mem_level_next(MEM_NORMAL, 2000, 5000, MEM_HIGH, k) == MEM_HIGH, "levels: iOS warns with plenty of room: high");
    CHECK(mem_level_next(MEM_NORMAL, 2000, 5000, MEM_CRIT, k) == MEM_CRIT, "levels: iOS reports critical: critical");
    CHECK(mem_level_next(MEM_HIGH, 2000, 5000, MEM_NORMAL, k) == MEM_NORMAL, "levels: report over, plenty of room: normal");
    CHECK(mem_level_next(MEM_NORMAL, 2000, -1, MEM_NORMAL, k) == MEM_NORMAL, "levels: the Mac (room unknown) is never critical by room");
    CHECK(mem_level_next(MEM_NORMAL, 3000, 500, MEM_NORMAL, (mem_hot_cfg){4600, 3000, 0}) == MEM_HIGH, "levels: DM_NVN_MEM_CRIT_MB=0: no critical level by room");
    CHECK(mem_level_next(MEM_NORMAL, 9000, 100, MEM_CRIT, (mem_hot_cfg){0, 3000, 1200}) == MEM_NORMAL, "levels: DM_NVN_MEM_HIGH_MB=0: off, even on iOS's report");
    uint64_t t = 100000000000ull;
    atomic_store(&g_mem_os_high_at, t); atomic_store(&g_mem_os_crit_at, 0);
    CHECK(mem_os_level(t + 1000) == MEM_HIGH && mem_os_level(t + MEM_OS_HOLD_NS + 1) == MEM_NORMAL, "iOS's warning counts for 5 s");
    atomic_store(&g_mem_os_crit_at, t);
    CHECK(mem_os_level(t + 1000) == MEM_CRIT, "iOS's critical report counts as critical");
    atomic_store(&g_mem_os_high_at, 0); atomic_store(&g_mem_os_crit_at, 0);
    CHECK(!placed_parent_on(), "a placed texture's heap stands for it by default (DM_NVN_RES_PLACED_PARENT)");
    printf("t_mem_pressure: %d checks, %d failed\n", checks, failures);
    return failures != 0;
} }
