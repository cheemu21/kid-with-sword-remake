// hle_codec.c unit test: the plain C interface's decoder and SDK 21's manager decoder share FinalizeHardwareOpusDecoder / ResetHardwareOpusDecoder, which go by the kind the host
// wrote into its own state. A plain decoder whose software state has a non-zero word at +0x10 (as the SDK's initialized OpusDecoderType does) used to be taken for a manager decoder,
// and its finalize followed that state's first word as the manager (Kirby Air Riders, h_codec_HwOpusFini+0xcc). No guest SDK: the software decoder's calls are fakes here.
#include "../hle_codec.c"
static int checks, fails, finis, resets;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)
uint64_t now_ns(void) { return 0; }
static struct { const void *k; void *v; } om[16];
void *objmap_get(const void *k) { for (int i = 0; i < 16; i++) if (om[i].k == k) return om[i].v; return NULL; }
void objmap_put(const void *k, void *v) { for (int i = 0; i < 16; i++) if (!om[i].k) { om[i].k = k; om[i].v = v; return; } }
void *objmap_del(const void *k) { for (int i = 0; i < 16; i++) if (om[i].k == k) { om[i].k = 0; return om[i].v; } return NULL; }
void hle_bind_system_event(void *g, int autoclear) { (void)g; (void)autoclear; }
uint64_t hle_system_event_binding(void *g) { (void)g; return 0; }
int hle_signal_system_event_binding(uint64_t b) { (void)b; return 0; }
static size_t f_wsize(int r, int c) { (void)r; (void)c; return 0x100; }
static int f_init(void *s, int r, int c, void *b, size_t n) {   // as the SDK: the state's words filled, +0 and +0x10 among them
    (void)r; (void)c; (void)n; uint64_t *w = s; w[0] = 0x5d4010005d480ull; w[2] = (uint64_t)(uintptr_t)b; return 0;
}
static void f_fini(void *s) { (void)s; finis++; }
static void f_reset(void *s) { (void)s; resets++; }
void *guest_sym(const char *name) {
    if (strstr(name, "GetOpusDecoderWorkBufferSize")) return (void *)f_wsize;
    if (strstr(name, "InitializeOpusDecoder")) return (void *)f_init;
    if (strstr(name, "FinalizeOpusDecoder")) return (void *)f_fini;
    if (strstr(name, "ResetOpusDecoder")) return (void *)f_reset;
    return NULL;
}
int main(void) {
    static uint8_t hw[0x40], gm[0x18], gd[0x30], work[0x100];
    CHECK(h_codec_HwOpusInit(hw, 48000, 2, work, sizeof work, 0) == 0, "plain decoder initializes");
    h_codec_HwOpusReset(hw);
    CHECK(resets == 1, "plain decoder resets its software state");
    h_codec_HwOpusFini(hw);
    CHECK(finis == 1 && !objmap_get(hw), "plain decoder whose state has a word at +0x10 finalizes as a plain decoder");
    CHECK(h_codec_HwOpusMgrInit(gm, NULL, 48000, 2, 20000000, 4, 8, NULL, 0) == 0, "manager initializes");
    CHECK(h_codec_HwOpusMgrDecInit(gd, 48000, 2, 20000000, gm) == 0, "manager decoder initializes");
    h_codec_HwOpusReset(gd);
    CHECK(resets == 2, "manager decoder resets");
    h_codec_HwOpusFini(gd);
    CHECK(finis == 2 && !objmap_get(gd), "manager decoder finalizes through its manager");
    CHECK((*(opus_mgr **)gm)->ndec == 0, "the manager drops the finalized decoder");
    h_codec_HwOpusMgrFini(gm);
    printf("Opus decoder kinds: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
