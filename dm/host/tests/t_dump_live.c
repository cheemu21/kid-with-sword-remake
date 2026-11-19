// kid-with-sword-remake L7.5: the live thread dump (the stall watchdog's, the app leaving the screen) shows where in the host a guest thread that is in no guest wait sits, and names a
// lock's owner by its SDK 22 kernel ID. A worker blocks on a host mutex (as the member's 'OptimizeChangeBanc' sat in host code holding a game lock), a second thread waits on a guest lock
// whose word holds the worker's ID; the dump must list the worker's host frames (blocked_in_host), name it as the owner, and leave both threads running afterwards
#include "../hle_thread.c"
#include <unistd.h>
static pthread_mutex_t hm = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int in_lock, got;
__attribute__((noinline)) static void blocked_in_host(void) { atomic_store(&in_lock, 1); pthread_mutex_lock(&hm); atomic_store(&got, 1); pthread_mutex_unlock(&hm); }
static thr_t w, m;
static uint32_t lockword;
static void *host_idle(void *p) { (void)p; for (;;) pause(); return NULL; }
static void *worker(void *p) { (void)p; w.mport = pthread_mach_thread_np(pthread_self()); blocked_in_host(); return NULL; }
int main(void) {
    pthread_key_create(&g_keythr, NULL);
    pthread_mutex_lock(&hm);
    w.handle = 0x1050; w.id = 0xa6; w.started = 1; w.prio = 55;
    m.handle = 0x1001; m.id = 0x51; m.started = 1; m.prio = 44; m.wkind = 1;
    lockword = 0x400000a6; m.waddr = (uint64_t)(uintptr_t)&lockword;
    w.all = &m; g_all = &w;
    pthread_t th, hi; pthread_create(&th, NULL, worker, NULL); pthread_create(&hi, NULL, host_idle, NULL);
    while (!atomic_load(&in_lock)) usleep(100);
    usleep(20000);
    char path[] = "/tmp/t_dump_live.XXXXXX"; int fd = mkstemp(path), save = dup(2); dup2(fd, 2);
    svc_thread_dump_live();
    fflush(stderr); dup2(save, 2);
    pthread_mutex_unlock(&hm);
    for (int i = 0; i < 2000 && !atomic_load(&got); i++) usleep(1000);
    char buf[16384] = {0}; lseek(fd, 0, SEEK_SET); ssize_t n = read(fd, buf, sizeof buf - 1); close(fd); unlink(path); (void)n;
    int ok = 1;
    if (!strstr(buf, "0x1050 id 0xa6 not in a guest wait")) { printf("FAIL: no host-frames line for the worker\n"); ok = 0; }
    if (!strstr(buf, "blocked_in_host") && !strstr(buf, "t_dump_live+")) { printf("FAIL: the worker's frames do not reach its function\n"); ok = 0; }
    if (!strstr(buf, "owner 0xa6 = 0x1050")) { printf("FAIL: the lock owner is not named by its kernel ID\n"); ok = 0; }
    if (!strstr(buf, "host thread")) { printf("FAIL: host threads not listed\n"); ok = 0; }
    if (!atomic_load(&got)) { printf("FAIL: the worker did not run on after the dump (left suspended?)\n"); ok = 0; }
    if (!ok) printf("--- dump ---\n%s\n", buf);
    printf("%s\n", ok ? "PASS: live dump lists host frames, names the SDK 22 lock owner, leaves threads running" : "FAIL");
    return !ok;
}
