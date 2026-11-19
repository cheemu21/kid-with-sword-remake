// mods.h and mods_zip.h without the host: the CRC-32, zstd frame headers and the stored-block frame writer, the RESTBL lookup and the raise rule, the overlay list
// DM_MODS makes (order, a mod above another, the app's overlay and its amiibo-nolimit/ under them, folders that are missing or do not fit), the merged size table it writes,
// and the zip import (romfs folders found at any depth, names, game files without a romfs folder, deflate and stored, Zip64-free archives from zip and ditto, what is
// left out or refused: an installer beside the romfs folder, exefs, a path that leaves its folder, encryption, another method, a bad CRC, a 7z file).
// Expected values are worked out by hand in the comments, not taken from the code under test.
#include "mods.h"
#include "mods_zip.h"
#include <stdarg.h>

static int g_fail, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_fail++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static char g_root[512];
static const char *P(const char *fmt, ...) {   // a path under the test's folder (rotating buffers, so a few can be live at once)
    static char buf[8][1024]; static int k; char *b = buf[k++ & 7];
    va_list a; va_start(a, fmt); int n = snprintf(b, 1024, "%s/", g_root); vsnprintf(b + n, 1024 - (size_t)n, fmt, a); va_end(a); return b;
}
static void wfile(const char *path, const void *d, size_t n) {
    char p[1024]; strlcpy(p, path, sizeof p); mods_mkdirs(p);
    FILE *f = fopen(path, "wb"); if (!f) { printf("cannot write %s\n", path); exit(1); }
    fwrite(d, 1, n, f); fclose(f);
}
// A .zs file as the game's are: a zstd frame header that gives the uncompressed size (single segment, 4-byte Frame_Content_Size), then some bytes
static void zs(const char *path, uint32_t content) {
    uint8_t b[24] = {0x28, 0xb5, 0x2f, 0xfd, 0xA0}; memcpy(b + 5, &content, 4); memset(b + 9, 0x55, sizeof b - 9); wfile(path, b, sizeof b);
}
static void text(const char *path, size_t n) { char *b = malloc(n); memset(b, 'x', n); wfile(path, b, n); free(b); }
static char *slurp(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long k = ftell(f); fseek(f, 0, SEEK_SET); char *b = malloc((size_t)k + 1); *n = fread(b, 1, (size_t)k, f); b[*n] = 0; fclose(f); return b;
}
static int exists(const char *p) { return !access(p, F_OK); }

// A RESTBL with these CRC entries (sorted here) and one name entry
typedef struct { const char *path; uint32_t v; } ent;
static int ent_cmp(const void *a, const void *b) { uint32_t x = mods_crc32(0, ((const ent *)a)->path, strlen(((const ent *)a)->path)), y = mods_crc32(0, ((const ent *)b)->path, strlen(((const ent *)b)->path)); return (x > y) - (x < y); }
static size_t restbl(uint8_t *out, ent *e, int n, const char *name, uint32_t nv) {
    qsort(e, (size_t)n, sizeof *e, ent_cmp);
    uint32_t slot = 160, nn = name ? 1 : 0, hdr[4] = {1, slot, (uint32_t)n, nn};
    memcpy(out, "RESTBL", 6); memcpy(out + 6, hdr, 16); size_t p = 22;
    for (int i = 0; i < n; i++) { uint32_t c = mods_crc32(0, e[i].path, strlen(e[i].path)); memcpy(out + p, &c, 4); memcpy(out + p + 4, &e[i].v, 4); p += 8; }
    if (name) { memset(out + p, 0, slot); memcpy(out + p, name, strlen(name)); memcpy(out + p + slot, &nv, 4); p += slot + 4; }
    return p;
}
// The table's entry for path in a raw-block zstd frame written by mods_rstb_write (read back by hand: header, then 3-byte block headers of type 0)
static uint32_t frame_entry(const char *file, const char *path, int *ok) {
    size_t n; uint8_t *z = (uint8_t *)slurp(file, &n); *ok = 0; if (!z || n < 13) { free(z); return 0; }
    uint64_t cs; memcpy(&cs, z + 5, 8);
    uint8_t *raw = malloc(cs ? cs : 1); size_t p = 13, got = 0; int last = 0;
    while (!last && p + 3 <= n) {
        uint32_t bh = z[p] | z[p + 1] << 8 | z[p + 2] << 16; p += 3; last = bh & 1;
        size_t k = bh >> 3; if ((bh >> 1 & 3) != 0 || p + k > n || got + k > cs) break;
        memcpy(raw + got, z + p, k); got += k; p += k;
    }
    mods_rstb t; uint32_t v = 0;
    if (mods_rd32(z) == 0xFD2FB528u && z[4] == 0xE0 && last && got == cs && p == n && mods_rstb_parse(&t, raw, got)) { uint8_t *s = mods_rstb_slot(&t, path); if (s) { v = mods_rd32(s); *ok = 1; } else *ok = 2; }
    free(raw); free(z); return v;
}

// A zip of stored entries, written here so the test can make what zip(1) will not: "..", an encrypted flag, another method, a wrong CRC
typedef struct { const char *name; const char *data; uint16_t method, flags; int bad_crc; } zent;
static void mkzip(const char *path, const zent *e, int n) {
    FILE *f = fopen(path, "wb"); uint32_t off[16]; uint8_t h[46];
    for (int i = 0; i < n; i++) {
        size_t dl = strlen(e[i].data), nl = strlen(e[i].name); uint32_t crc = mods_crc32(0, e[i].data, dl) ^ (uint32_t)e[i].bad_crc;
        off[i] = (uint32_t)ftell(f); memset(h, 0, 30);
        mods_wr32(h, 0x04034b50u); h[4] = 20; memcpy(h + 6, &e[i].flags, 2); memcpy(h + 8, &e[i].method, 2); mods_wr32(h + 14, crc); mods_wr32(h + 18, (uint32_t)dl); mods_wr32(h + 22, (uint32_t)dl);
        h[26] = (uint8_t)nl; fwrite(h, 1, 30, f); fwrite(e[i].name, 1, nl, f); fwrite(e[i].data, 1, dl, f);
    }
    uint32_t cd = (uint32_t)ftell(f);
    for (int i = 0; i < n; i++) {
        size_t dl = strlen(e[i].data), nl = strlen(e[i].name); uint32_t crc = mods_crc32(0, e[i].data, dl) ^ (uint32_t)e[i].bad_crc;
        memset(h, 0, 46); mods_wr32(h, 0x02014b50u); h[4] = 20; h[6] = 20; memcpy(h + 8, &e[i].flags, 2); memcpy(h + 10, &e[i].method, 2);
        mods_wr32(h + 16, crc); mods_wr32(h + 20, (uint32_t)dl); mods_wr32(h + 24, (uint32_t)dl); h[28] = (uint8_t)nl; mods_wr32(h + 42, off[i]);
        fwrite(h, 1, 46, f); fwrite(e[i].name, 1, nl, f);
    }
    uint32_t cdn = (uint32_t)ftell(f) - cd; uint8_t eo[22] = {0}; mods_wr32(eo, 0x06054b50u); eo[8] = eo[10] = (uint8_t)n; mods_wr32(eo + 12, cdn); mods_wr32(eo + 16, cd);
    fwrite(eo, 1, 22, f); fclose(f);
}
static int sh(const char *fmt, ...) { char c[2048]; va_list a; va_start(a, fmt); vsnprintf(c, sizeof c, fmt, a); va_end(a); return system(c); }
static int count_dir(const char *d) {   // entries in a folder, hidden ones too (a failed import must leave no .import-* behind)
    DIR *x = opendir(d); int n = 0; struct dirent *e; if (!x) return -1;
    while ((e = readdir(x))) if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) n++;
    closedir(x); return n;
}

int main(void) {
    snprintf(g_root, sizeof g_root, "%s/t_mods.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (!mkdtemp(g_root)) { perror("mkdtemp"); return 1; }

    printf("CRC-32\n");
    CHECK(mods_crc32(0, "123456789", 9) == 0xCBF43926u, "the CRC-32 check value");
    CHECK(mods_crc32(mods_crc32(0, "1234", 4), "56789", 5) == 0xCBF43926u, "CRC-32 in two parts");

    printf("zstd frame headers\n");
    {   // a mod's dictionary-compressed .bfres.zs (Ocarina of Time, Player_Adult): descriptor 0x81 = 4-byte size, a window byte, a 1-byte dictionary ID; 0x0086aa50 = 8,825,424
        const uint8_t h[] = {0x28, 0xb5, 0x2f, 0xfd, 0x81, 0x60, 0x01, 0x50, 0xaa, 0x86, 0x00, 0x8c};
        CHECK(mods_zstd_size(h, sizeof h) == 8825424, "4-byte size after a window and a dictionary ID");
        const uint8_t h1[] = {0x28, 0xb5, 0x2f, 0xfd, 0x20, 200};                     // single segment, 1-byte size
        CHECK(mods_zstd_size(h1, sizeof h1) == 200, "1-byte size");
        const uint8_t h2[] = {0x28, 0xb5, 0x2f, 0xfd, 0x60, 0xe8, 0x02};               // 2-byte size: 0x02e8 + 256 = 1000
        CHECK(mods_zstd_size(h2, sizeof h2) == 1000, "2-byte size is 256 more");
        const uint8_t h3[] = {0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x60};                     // no size field
        CHECK(mods_zstd_size(h3, sizeof h3) == -1, "a frame that does not say");
        const uint8_t h4[] = {0x28, 0xb5, 0x2f, 0xfd, 0x83, 0x60, 1, 2, 3, 4, 0x10, 0, 0, 0};   // 4-byte dictionary ID, 4-byte size 16
        CHECK(mods_zstd_size(h4, sizeof h4) == 16, "after a 4-byte dictionary ID");
        CHECK(mods_zstd_size(h4, 9) == -1, "a cut-short header");
        CHECK(mods_zstd_size((const uint8_t *)"PK\3\4abcdefgh", 12) == -1, "not zstd");
    }
    printf("stored-block frames\n");
    {   size_t sizes[] = {0, 1, 131072, 131073, 300000};
        for (int i = 0; i < 5; i++) {
            size_t n = sizes[i]; uint8_t *src = malloc(n + 1), *z = malloc(mods_zstd_raw_bound(n));
            for (size_t k = 0; k < n; k++) src[k] = (uint8_t)(k * 7 + 3);
            size_t zn = mods_zstd_raw(src, n, z);
            size_t blocks = n ? (n + 131071) / 131072 : 1;
            CHECK(zn == 13 + 3 * blocks + n, "frame of %zu bytes: %zu bytes, %zu blocks", n, zn, blocks);
            CHECK(mods_zstd_size(z, zn) == (int64_t)n, "its header gives %zu", n);
            char fn[64]; snprintf(fn, sizeof fn, "frame%d.zs", i); wfile(P("%s", fn), z, zn);
            if (!access("/opt/homebrew/bin/zstd", X_OK) || !access("/usr/local/bin/zstd", X_OK)) {   // a real decoder, where this Mac has one
                CHECK(!sh("PATH=/opt/homebrew/bin:/usr/local/bin:$PATH zstd -q -d -c '%s' > '%s.out' 2>/dev/null", P("%s", fn), P("%s", fn)), "zstd decodes the %zu-byte frame", n);
                size_t got; char *back = slurp(P("%s.out", fn), &got);
                CHECK(back && got == n && !memcmp(back, src, n), "zstd gives back the %zu bytes", n); free(back);
            }
            free(src); free(z);
        }
    }

    printf("RESTBL\n");
    {   uint8_t t[22 + 8 * 3 + 164]; ent e[] = {{"Model/a.bfres", 1100}, {"Tex/t.bntx", 780}, {"Game/x.txt", 300}};
        size_t n = restbl(t, e, 3, "Clash/n.bin", 4242); mods_rstb r;
        CHECK(n == sizeof t && mods_rstb_parse(&r, t, n), "parse");
        uint8_t *s = mods_rstb_slot(&r, "Tex/t.bntx"); CHECK(s && mods_rd32(s) == 780, "by CRC");
        s = mods_rstb_slot(&r, "Clash/n.bin"); CHECK(s && mods_rd32(s) == 4242, "by name");
        CHECK(!mods_rstb_slot(&r, "Tex/t.bntx.zs") && !mods_rstb_slot(&r, "Clash/n.bi"), "other paths have none");
        CHECK(!mods_rstb_parse(&r, t, n - 1), "a size that does not add up");
        uint8_t u[sizeof t]; memcpy(u, t, n); memcpy(u + 22, t + 30, 8); memcpy(u + 30, t + 22, 8);
        CHECK(!mods_rstb_parse(&r, u, n), "unsorted CRCs");
        memcpy(u, t, n); u[0] = 'X'; CHECK(!mods_rstb_parse(&r, u, n), "not RESTBL");
    }
    printf("raise rule\n");
    // a .bntx of 401,520 bytes with entry 401,800 grown by 1,000: +1,000 = 402,800; scaled 401,800 × 402,520 / 401,520 = 402,800.69 → 402,801; rounded up to 256: 402,944
    CHECK(mods_rstb_need(401800, 401520, 402520) == 402944, "bigger: %llu", (unsigned long long)mods_rstb_need(401800, 401520, 402520));
    CHECK(mods_rstb_need(401800, 401520, 401520) == 401800 && mods_rstb_need(401800, 401520, 100) == 401800, "not bigger: the entry as it is");
    CHECK(mods_rstb_need(1100, 1000, 1500) == 1792, "1,100 for 1,000 → 1,500: max(1,600, 1,650) up to 256 = 1,792");
    CHECK(mods_rstb_need(300, 150, 400) == 1024, "300 for 150 → 400: max(550, 800) up to 256 = 1,024");
    CHECK(mods_rstb_need(4000000000u, 1, 4) == UINT32_MAX, "too big for the table");

    printf("overlay list and merged size table\n");
    {   // the game: Model/a.bfres.zs (1,000 uncompressed), Tex/t.bntx.zs (500), Game/x.txt (100, but the app's amiibo-nolimit/ has a 150-byte one)
        zs(P("rom/Model/a.bfres.zs"), 1000); zs(P("rom/Tex/t.bntx.zs"), 500); text(P("rom/Game/x.txt"), 100); text(P("rom/Other/y.txt"), 10);
        text(P("ov/amiibo-nolimit/Game/x.txt"), 150); text(P("ov/amiibo.tsv"), 5);
        uint8_t t[22 + 8 * 3]; ent e[] = {{"Model/a.bfres", 1100}, {"Tex/t.bntx", 780}, {"Game/x.txt", 300}};
        size_t tn = restbl(t, e, 3, NULL, 0);
        const char *hdr = "System/Resource/T.rsizetable.zs\n"; uint8_t file[256]; memcpy(file, hdr, strlen(hdr)); memcpy(file + strlen(hdr), t, tn);
        wfile(P("mods_rstb.bin"), file, strlen(hdr) + tn);
        // mod 1 (top): a bigger a.bfres (1,500), the same-size t.bntx, a new file, its own copy of the size table, a hidden file
        zs(P("m1/romfs/Model/a.bfres.zs"), 1500); zs(P("m1/romfs/Tex/t.bntx.zs"), 500); text(P("m1/romfs/New/n.bin"), 9999); text(P("m1/romfs/System/Resource/T.rsizetable.zs"), 50); text(P("m1/romfs/.DS_Store"), 3);
        // mod 2: an even bigger a.bfres (under mod 1's, so not counted), a bigger Game/x.txt (400 over the amiibo-nolimit 150)
        zs(P("m2/romfs/Model/a.bfres.zs"), 3000); text(P("m2/romfs/Game/x.txt"), 400);
        // mod 3: a bigger Other/y.txt, which the table has no entry for
        text(P("m3/romfs/Other/y.txt"), 20);
        char mods[2048]; snprintf(mods, sizeof mods, "%s:%s:%s:%s", P("m1/romfs"), P("m2/romfs"), P("missing/romfs"), P("m3/romfs"));
        char out[4096]; mods_stat st[4];
        int n = mods_prepare(mods, P("ov"), P("rom"), P("mods_rstb.bin"), P("work"), out, sizeof out, st, 4);
        char want[4096]; snprintf(want, sizeof want, "%s:%s:%s:%s:%s", P("work/romfs"), P("m1/romfs"), P("m2/romfs"), P("m3/romfs"), P("ov"));
        CHECK(n == 3 && !strcmp(out, want), "list: the merged table, the mods in order, the app's overlay last\n  got  %s\n  want %s", out, want);
        CHECK(st[0].files == 4 && st[0].shadowed == 0 && st[0].bigger == 1 && st[0].raised == 1 && st[0].own_table == 1 && st[0].untracked == 0, "mod 1: %d files, %d bigger, %d raised, own table %d", st[0].files, st[0].bigger, st[0].raised, st[0].own_table);
        CHECK(st[1].files == 2 && st[1].shadowed == 1 && st[1].bigger == 1 && st[1].raised == 1, "mod 2: %d files, %d under mod 1, %d bigger, %d raised", st[1].files, st[1].shadowed, st[1].bigger, st[1].raised);
        CHECK(st[2].dropped && !st[2].files, "a missing folder is left out");
        CHECK(st[3].bigger == 1 && st[3].untracked == 1 && !st[3].raised, "a bigger file with no entry is said so");
        int ok; char tf[1024]; strlcpy(tf, P("work/romfs/System/Resource/T.rsizetable.zs"), sizeof tf);   // P's buffers rotate: keep this one
        CHECK(frame_entry(tf, "Model/a.bfres", &ok) == 1792 && ok == 1, "a.bfres: 1,100 → 1,792 (mod 1's 1,500, not mod 2's 3,000)");
        CHECK(frame_entry(tf, "Game/x.txt", &ok) == 1024 && ok == 1, "x.txt: grown from the amiibo-nolimit file's 150, not the game's 100: 300 → 1,024");
        CHECK(frame_entry(tf, "Tex/t.bntx", &ok) == 780 && ok == 1, "t.bntx: the same size, unchanged");
        CHECK(!exists(P("work/romfs/System/Resource/T.rsizetable.zs.tmp")), "no temporary file left");

        // the launcher's check: one mod, nothing written
        mods_stat one; unlink(tf);
        mods_prepare(P("m2/romfs"), P("ov"), P("rom"), P("mods_rstb.bin"), NULL, NULL, 0, &one, 1);
        CHECK(one.files == 2 && one.bigger == 2 && one.raised == 2 && !one.no_table && !exists(tf), "a check on its own: mod 2's a.bfres counts now (%d bigger, %d raised), nothing written", one.bigger, one.raised);
        // an app without the table: mods still served, bigger files reported, no table folder in the list
        n = mods_prepare(P("m2/romfs"), P("ov"), P("rom"), NULL, P("work"), out, sizeof out, &one, 1);
        snprintf(want, sizeof want, "%s:%s", P("m2/romfs"), P("ov"));
        CHECK(n == 1 && !strcmp(out, want) && one.no_table && one.untracked == 2 && !exists(tf), "no table: %s", out);
        // nothing bigger and no own table: no merged table
        n = mods_prepare(P("m3/romfs"), NULL, P("rom"), P("mods_rstb.bin"), P("work"), out, sizeof out, &one, 1);
        CHECK(n == 1 && !strcmp(out, P("m3/romfs")) && !exists(tf), "no overlay of the app's, nothing to raise: the mod alone");
        // the list's room: the overlay field is 4,096 bytes in the host; a mod that does not fit is left out whole, the app's overlay stays
        size_t cap = strlen(P("work/romfs")) + 1 + strlen(P("m1/romfs")) + 1 + strlen(P("ov/amiibo-nolimit")) + 1 + strlen(P("ov")) + 1;
        n = mods_prepare(mods, P("ov"), P("rom"), P("mods_rstb.bin"), P("work"), out, cap, st, 4);
        snprintf(want, sizeof want, "%s:%s:%s", P("work/romfs"), P("m1/romfs"), P("ov"));
        CHECK(n == 1 && !strcmp(out, want) && !st[0].dropped && st[1].dropped && st[3].dropped, "full list: mod 1 and the app's overlay\n  got  %s", out);
        // the game's files as an image (romfs_image.h's layout, by hand): Model/a.bfres.zs with a header saying 2,000
        uint8_t img[32 + 24 + 3 * 24 + 15] = {0}, zh[24] = {0x28, 0xb5, 0x2f, 0xfd, 0xA0}; uint32_t big = 2000; memcpy(zh + 5, &big, 4);
        uint64_t hd[3] = {56, 3 * 24 + 15, 3}; memcpy(img, "DMROMFS1", 8); memcpy(img + 8, hd, 24); memcpy(img + 32, zh, 24);
        img_ent ie[3] = {{1, 1, 0, 0, 0, 0}, {2, 1, 0, 5, 0, 0}, {32, 24, 5, 10, 1, 0}};
        memcpy(img + 56, ie, sizeof ie); memcpy(img + 56 + sizeof ie, "Modela.bfres.zs", 15); wfile(P("rom.img"), img, sizeof img);
        n = mods_prepare(P("m1/romfs"), NULL, P("rom.img"), P("mods_rstb.bin"), NULL, NULL, 0, &one, 1);
        CHECK(one.bigger == 0, "from the image: mod 1's 1,500-byte a.bfres is smaller than the image's 2,000");
        n = mods_prepare(P("m2/romfs"), NULL, P("rom.img"), P("mods_rstb.bin"), NULL, NULL, 0, &one, 1);
        CHECK(one.bigger == 1 && one.raised == 1, "from the image: mod 2's 3,000 is bigger (x.txt has no original there: a new file)");
    }

    printf("zip import\n");
    {   char md[1024]; strlcpy(md, P("mods"), sizeof md);
        char msg[1024], added[1024]; int n;
        // a mod as players share them: romfs at the top beside an installer and a readme, made by zip(1) (deflate)
        zs(P("src1/romfs/Model/a.bfres.zs"), 1500); text(P("src1/romfs/Tex/t.bntx.zs"), 70000); text(P("src1/Installer.exe"), 5000); text(P("src1/Installation.txt"), 300);
        CHECK(!sh("cd '%s' && zip -qr ../goku.zip romfs Installer.exe Installation.txt", P("src1")), "zip(1)");
        n = mods_import_zip(P("goku.zip"), md, "goku_patch", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(n == 1 && !strcmp(added, "goku_patch") && !msg[0], "one mod named after the archive: %d %s | %s", n, added, msg);
        size_t a, b; char *x = slurp(P("src1/romfs/Tex/t.bntx.zs"), &a), *y = slurp(P("mods/goku_patch/romfs/Tex/t.bntx.zs"), &b);
        CHECK(x && y && a == b && !memcmp(x, y, a), "the deflated file comes out the same"); free(x); free(y);
        CHECK(exists(P("mods/goku_patch/romfs/Model/a.bfres.zs")) && !exists(P("mods/goku_patch/Installer.exe")) && !exists(P("mods/goku_patch/romfs/Installer.exe")), "the installer is left out");
        n = mods_import_zip(P("goku.zip"), md, "goku_patch", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(n == 1 && !strcmp(added, "goku_patch 2"), "imported again: a name of its own (%s)", added);
        // stored (zip -0), the mod inside a named folder, with exefs patches
        text(P("src2/Tunic/romfs/Tex/u.bntx.zs"), 1000); text(P("src2/Tunic/exefs/main.ips"), 10);
        CHECK(!sh("cd '%s' && zip -0 -qr ../tunic.zip Tunic", P("src2")), "zip -0");
        n = mods_import_zip(P("tunic.zip"), md, "tunic", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(n == 1 && !strcmp(added, "Tunic") && strstr(msg, "exefs") && exists(P("mods/Tunic/romfs/Tex/u.bntx.zs")), "named after its folder; exefs said: %s", msg);
        // a folder zipped by the system (ditto -c -k --keepParent, as the Files app's own archives are), with two romfs folders in Atmosphère and loader layouts
        text(P("Pack/atmosphere/contents/0400486024DEC000/romfs/A/a.txt"), 10); text(P("Pack/load/0400486024DEC000/Kid Goku/romfs/B/b.txt"), 20);
        CHECK(!sh("cd '%s' && ditto -c -k --keepParent Pack pack.zip", g_root), "ditto");
        n = mods_import_zip(P("pack.zip"), md, "Pack", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(n == 2 && strstr(added, "Pack\n") == added && strstr(added, "Kid Goku"), "two mods: past the title ID and contents to Pack, and Kid Goku: %s", added);
        CHECK(exists(P("mods/Pack/romfs/A/a.txt")) && exists(P("mods/Kid Goku/romfs/B/b.txt")), "each in its own folder");
        // no romfs folder: game files from inside the one top folder; files that are not the game's are refused
        zs(P("src3/Loose/Model/a.bfres.zs"), 1200);
        CHECK(!sh("cd '%s' && zip -qr ../loose.zip Loose", P("src3")), "zip loose");
        n = mods_import_zip(P("loose.zip"), md, "loose", NULL, P("rom"), msg, sizeof msg, added, sizeof added);
        CHECK(n == 1 && !strcmp(added, "Loose") && exists(P("mods/Loose/romfs/Model/a.bfres.zs")), "game files without romfs/: %s %s", added, msg);
        text(P("src4/notes/readme.txt"), 5);
        CHECK(!sh("cd '%s' && zip -qr ../junk.zip notes", P("src4")), "zip junk");
        int before = count_dir(md);
        n = mods_import_zip(P("junk.zip"), md, "junk", NULL, P("rom"), msg, sizeof msg, added, sizeof added);
        CHECK(!n && strstr(msg, "romfs") && count_dir(md) == before, "no game files: refused (%s)", msg);
        // what is left out or refused (written by hand)
        zent slip[] = {{"romfs/ok.txt", "fine", 0, 0, 0}, {"romfs/../../evil.txt", "bad", 0, 0, 0}, {"romfs/.hidden", "h", 0, 0, 0}, {"romfs/__MACOSX/x", "m", 0, 0, 0}};
        mkzip(P("slip.zip"), slip, 4);
        n = mods_import_zip(P("slip.zip"), md, "Slip", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(n == 1 && exists(P("mods/Slip/romfs/ok.txt")) && !exists(P("evil.txt")) && !exists(P("mods/evil.txt")) && !exists(P("mods/Slip/romfs/.hidden")) && count_dir(P("mods/Slip/romfs")) == 1, "a path out of its folder, a hidden file, __MACOSX: left out");
        zent enc[] = {{"romfs/a.txt", "secret", 0, 1, 0}}; mkzip(P("enc.zip"), enc, 1);
        before = count_dir(md);
        n = mods_import_zip(P("enc.zip"), md, "Enc", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(!n && strstr(msg, "password") && count_dir(md) == before, "encrypted: refused, nothing left (%s)", msg);
        zent lz[] = {{"romfs/a.txt", "data", 14, 0, 0}}; mkzip(P("lzma.zip"), lz, 1);
        n = mods_import_zip(P("lzma.zip"), md, "Lz", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(!n && strstr(msg, "method 14") && count_dir(md) == before, "another method: refused (%s)", msg);
        zent crc[] = {{"romfs/a.txt", "good", 0, 0, 0}, {"romfs/b.txt", "data", 0, 0, 1}}; mkzip(P("crc.zip"), crc, 2);
        n = mods_import_zip(P("crc.zip"), md, "Crc", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(!n && strstr(msg, "b.txt") && count_dir(md) == before, "a bad CRC: refused, the whole mod gone (%s)", msg);
        wfile(P("mod.7z"), "7z\xBC\xAF\x27\x1C\0\4", 8);
        n = mods_import_zip(P("mod.7z"), md, "Seven", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(!n && strstr(msg, "7z archive"), "7z: said what it is (%s)", msg);
        text(P("notzip.bin"), 100);
        n = mods_import_zip(P("notzip.bin"), md, "No", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(!n && strstr(msg, "isn't a zip"), "not a zip (%s)", msg);
        // a folder, read as it is (LiveContainer: no zipping by the system): src1's romfs, its installer left out, named after the folder
        n = mods_import_zip(P("src1"), md, "ignored", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(n == 1 && !strcmp(added, "src1") && exists(P("mods/src1/romfs/Model/a.bfres.zs")) && !exists(P("mods/src1/Installer.exe")), "a folder: %d %s | %s", n, added, msg);
        x = slurp(P("src1/romfs/Tex/t.bntx.zs"), &a); y = slurp(P("mods/src1/romfs/Tex/t.bntx.zs"), &b);
        CHECK(x && y && a == b && !memcmp(x, y, a), "a folder's file is copied as it is"); free(x); free(y);
        n = mods_import_zip(P("Pack/"), md, "ignored", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(n == 2 && strstr(added, "Pack 2") && strstr(added, "Kid Goku 2"), "a folder with two romfs folders, a trailing slash: %s", added);
        text(P("cloud/Mod/romfs/a.txt"), 5); text(P("cloud/Mod/romfs/.b.txt.icloud"), 5);
        before = count_dir(md);
        n = mods_import_zip(P("cloud/Mod"), md, "x", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(!n && strstr(msg, "iCloud") && count_dir(md) == before, "a folder with files still in iCloud: said so (%s)", msg);
        mkdir(P("emptydir"), 0755);
        n = mods_import_zip(P("emptydir"), md, "x", NULL, NULL, msg, sizeof msg, added, sizeof added);
        CHECK(!n && strstr(msg, "empty"), "an empty folder (%s)", msg);
        // names
        char nm[64];
        mods_name_from("a/romfs/", 8, "f", nm, sizeof nm); CHECK(!strcmp(nm, "a"), "name: a");
        mods_name_from("romfs/", 6, "f", nm, sizeof nm); CHECK(!strcmp(nm, "f"), "name: the archive's");
        mods_name_from(".x:y/romfs/", 11, "f", nm, sizeof nm); CHECK(!strcmp(nm, "x_y"), "name: no leading dot, no colon (%s)", nm);
        mods_name_from("0400486024DEC000/romfs/", 23, "", nm, sizeof nm); CHECK(!strcmp(nm, "Mod"), "name: a title ID alone");
        mods_name_from("Caf\x82/romfs/", 11, "f", nm, sizeof nm); CHECK(!strcmp(nm, "Caf_"), "name: a code page byte becomes _ (%s)", nm);
        mods_name_from("Caf\xc3\xa9 2/romfs/", 14, "f", nm, sizeof nm); CHECK(!strcmp(nm, "Caf\xc3\xa9 2"), "name: UTF-8 is kept (%s)", nm);
    }

    sh("rm -rf '%s'", g_root);
    printf("%s: %d checks, %d failed\n", g_fail ? "FAIL" : "ok", g_n, g_fail);
    return g_fail != 0;
}
