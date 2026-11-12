// hle_audio.c unit test: SDK 21's input streams on the device's microphone (mic_apple.h), here a fake one whose frame k holds the value k & 0x3fff. One device is listed; a stream
// opens as PCM16 48 kHz (other formats fail), starts the capture once, reads only what it has not read, keeps at most its capacity (the oldest frames passed over), purges to the newest
// frame, and two streams read with cursors of their own; the states are 0 closed, 1 stopped, 2 started (Ocarina of Time: 2 is started, main+0x336ee60)
#define DM_MIC_FAKE
#include "../hle_audio.c"
#include <time.h>
__thread _Atomic int dm_host_work;
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
static struct { const void *k; void *v; } om[8];
void *objmap_get(const void *k) { for (int i = 0; i < 8; i++) if (om[i].k == k) return om[i].v; return NULL; }
void objmap_put(const void *k, void *v) { for (int i = 0; i < 8; i++) if (!om[i].k) { om[i].k = k; om[i].v = v; return; } }
void *objmap_del(const void *k) { for (int i = 0; i < 8; i++) if (om[i].k == k) { om[i].k = 0; return om[i].v; } return NULL; }
void hle_signal_system_event(void *g) { (void)g; }
void hle_bind_system_event(void *g, int autoclear) { (void)g; (void)autoclear; }
module_t *module_of(const void *p) { (void)p; return NULL; }
int dm_guest_as_contains(uintptr_t a) { (void)a; return 0; }
void dm_host_helper_qos(qos_class_t q) { (void)q; }

static uint64_t f_head; static int f_users, f_retains, f_on = 1;
int dm_mic_available(void) { return f_on; }
int dm_mic_retain(void) { f_users++; f_retains++; return 1; }
void dm_mic_release(void) { f_users--; }
uint64_t dm_mic_head(void) { return f_head; }
int dm_mic_copy(uint64_t from, int16_t *dst, int n) {
    if (from > f_head || f_head - from > DM_MIC_RING) return 0;
    if ((uint64_t)n > f_head - from) n = (int)(f_head - from);
    for (int i = 0; i < n; i++) dst[i] = (int16_t)((from + i) & 0x3fff);
    return n;
}
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; printf("FAIL: %s\n", label); } } while (0)
int main(void) {
    char names[8][256]; memset(names, 0, sizeof names);
    f_on = 0; CHECK("no device listed without the microphone", h_is_List(names[0], 8) == 0);
    f_on = 1; CHECK("one device listed with it", h_is_List(names[0], 8) == 1 && names[0][0]);
    char a[0x350] = {0}, b[0x350] = {0}, c[0x350] = {0};
    int32_t fmt[3] = {OS_PCM16, 1, 48000}, flt[3] = {OS_FLOAT, 1, 48000}, st2[3] = {OS_PCM16, 2, 48000};
    CHECK("a stream never opened is closed", h_is_State(a) == 0 && h_is_Read(a, (int16_t[4]){0}, 4) == 0);
    CHECK("a float stream does not open", h_is_Open(c, NULL, 9600, names[0], flt, 4800) != 0 && h_is_State(c) == 0);
    CHECK("PCM16 mono 48 kHz opens, stopped", h_is_Open(a, NULL, 9600, names[0], fmt, 4800) == 0 && h_is_State(a) == 1);
    CHECK("its capacity is its buffer's frames", h_is_Capacity(a) == 4800 && h_is_Format(a).channels == 1 && h_is_Format(a).rate == 48000);
    f_head = 5000;
    CHECK("starting starts the capture", h_is_Start(a) == 0 && h_is_State(a) == 2 && f_users == 1);
    CHECK("it reads nothing captured before its start", h_is_Filled(a) == 0 && h_is_Read(a, (int16_t[4]){0}, 4) == 0);
    f_head += 1000;
    int16_t buf[512];
    CHECK("frames captured since are filled", h_is_Filled(a) == 1000 && h_is_Free(a) == 3800);
    CHECK("a read of 256 gets the next 256", h_is_Read(a, buf, 256) == 256 && buf[0] == (5000 & 0x3fff) && buf[255] == ((5000 + 255) & 0x3fff));
    CHECK("and they are read once", h_is_Filled(a) == 744);
    CHECK("a second start does not start the capture again", h_is_Start(a) == 0 && f_users == 1);
    f_head += 20000;
    CHECK("at most its capacity is kept", h_is_Filled(a) == 4800);
    CHECK("the oldest frames are passed over", h_is_Read(a, buf, 4) == 4 && buf[0] == (int16_t)((f_head - 4800) & 0x3fff));
    CHECK("a purge drops what is not read", (h_is_Purge(a), h_is_Filled(a) == 0));
    CHECK("the second stream opens stereo", h_is_Open(b, NULL, 19200, "TrueRaw", st2, 4800) == 0 && h_is_Capacity(b) == 4800 && h_is_Format(b).channels == 2);
    CHECK("and starts on the running capture", h_is_Start(b) == 0 && f_users == 2);
    f_head += 100;
    CHECK("each stream reads with its own cursor", h_is_Filled(a) == 100 && h_is_Filled(b) == 100 && h_is_Read(a, buf, 50) == 50 && h_is_Filled(a) == 50 && h_is_Filled(b) == 100);
    CHECK("a stereo read gives each frame to both channels", h_is_Read(b, buf, 10) == 10 && buf[0] == buf[1] && buf[2] == buf[3] && buf[2] == buf[0] + 1);
    h_is_SetGain(a, 0.5f, 0); int16_t one;
    CHECK("the gain scales the frames", h_is_GetGain(a) == 0.5f && h_is_Read(a, &one, 1) == 1 && one == (int16_t)(((f_head - 50) & 0x3fff) / 2));
    h_is_Stop(a);
    CHECK("a stopped stream reads nothing and releases the capture", h_is_State(a) == 1 && h_is_Read(a, buf, 4) == 0 && f_users == 1);
    h_is_Close(b);
    CHECK("closing a started stream releases the capture", h_is_State(b) == 0 && f_users == 0);
    h_is_Close(a);
    CHECK("a closed stream is closed", h_is_State(a) == 0 && h_is_Capacity(a) == 0 && h_is_GetGain(a) == 1.0f);
    CHECK("the capture was started once per started stream", f_retains == 2);
    printf("t_input_stream: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
