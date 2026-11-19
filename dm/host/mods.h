// Mods: replacement game files the player installs (Documents/mods/<name>/romfs/..., the usual Switch "LayeredFS" layout), served over the RomFS with the app's own
// overlay (DM_ROMFS_OVERLAY: the amiibo files, scripts/oot_amiibo_overlay.py). Header-only, shared by the host's rom mount (hle_fs.c rom_overlay_env) and the launcher's checks
// (hle_mods.c, Mods.swift), and tested by tests/t_mods.c without the host.
//
// DM_MODS = the enabled mods' romfs folders, ':'-separated, the one that wins first (the launcher writes it at Play, in the order of its list: top wins).
// The rom mount then reads, for each file, the first of:  [merged size table] : mod 1 : mod 2 : ... : the app's overlay (amiibo-nolimit/ first) : the game's RomFS.
// With DM_MODS unset or empty nothing here runs and the mount is as before.
//
// The resource size table (RSTB): the game reserves, for each file it loads, the bytes its System/Resource/ResourceSizeTable*.rsizetable.zs gives (RESTBL: CRC32 of the path
// without .zs → bytes; a few colliding paths by name). Measured on Ocarina of Time v131072: each entry is the file's uncompressed size plus a small per-type overhead (+280 for a
// .bntx, +2.4-3.7 % for a .bfres). A replacement bigger than the original runs that reservation out (the amiibo file did: a null allocation, a crash at 5 s). So when a mod's
// file is bigger than the file it replaces, its entry is raised by the growth (additive and proportional, whichever is larger) in a copy of the table, which is served first.
// The game's table is zstd-compressed and neither iOS nor the host has a zstd decoder: the IPA build stores it uncompressed (DM_MODS_RSTB, scripts/oot_mods_rstb.py), and the
// merged copy is written back as a zstd frame of raw (stored) blocks, which any zstd decoder reads. File sizes come from the zstd frame headers (Frame_Content_Size), which the
// game's dictionary-compressed files carry, so nothing is decompressed. Without DM_MODS_RSTB (an app built before this) mods are still served, and the launcher warns about
// files bigger than their originals. A mod's own copy of the size table is never served: it would drop the amiibo entry and other mods' raises; the merged table replaces it.
#pragma once
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "romfs_image.h"

#ifdef LOG
#define MODS_LOG(...) LOG(__VA_ARGS__)
#else
#define MODS_LOG(...) (fprintf(stderr, "[mods] " __VA_ARGS__), fputc('\n', stderr))
#endif
#define MODS_FN static __attribute__((unused))
#define MODS_MAX 64   // mods served at once (DM_MODS entries beyond are dropped, and said so)

static inline uint32_t mods_rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static inline void mods_wr32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

// ---- CRC-32 (zlib's: reflected 0xEDB88320), the size table's path hash and the zip entries' check ----
static uint32_t g_mods_crc_tab[256];
static pthread_once_t g_mods_crc_once = PTHREAD_ONCE_INIT;
static void mods_crc_init(void) {
    for (uint32_t i = 0; i < 256; i++) { uint32_t c = i; for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1; g_mods_crc_tab[i] = c; }
}
MODS_FN uint32_t mods_crc32(uint32_t crc, const void *p, size_t n) {
    pthread_once(&g_mods_crc_once, mods_crc_init);
    const uint8_t *b = p; crc = ~crc;
    while (n--) crc = g_mods_crc_tab[(crc ^ *b++) & 0xff] ^ (crc >> 8);
    return ~crc;
}

// ---- RESTBL: "RESTBL", u32 version 1, u32 name slot size, u32 CRC entries, u32 name entries; then {u32 crc, u32 bytes} sorted by crc; then {char name[slot], u32 bytes} ----
typedef struct { uint8_t *d; size_t n; uint32_t slot, ncrc, nname; } mods_rstb;
#define MODS_RSTB_HDR 22
MODS_FN int mods_rstb_parse(mods_rstb *t, uint8_t *d, size_t n) {
    if (n < MODS_RSTB_HDR || memcmp(d, "RESTBL", 6) || mods_rd32(d + 6) != 1) return 0;
    uint32_t slot = mods_rd32(d + 10), nc = mods_rd32(d + 14), nn = mods_rd32(d + 18);
    if (slot < 8 || slot > 1024 || (uint64_t)MODS_RSTB_HDR + (uint64_t)nc * 8 + (uint64_t)nn * (slot + 4) != n) return 0;
    for (uint32_t i = 1; i < nc; i++) if (mods_rd32(d + MODS_RSTB_HDR + 8 * i) <= mods_rd32(d + MODS_RSTB_HDR + 8 * (i - 1))) return 0;   // sorted, one entry per CRC
    t->d = d; t->n = n; t->slot = slot; t->ncrc = nc; t->nname = nn; return 1;
}
// The 4 bytes of path's entry (the name table first: it holds the paths whose CRCs collide), or NULL when the table has none
MODS_FN uint8_t *mods_rstb_slot(const mods_rstb *t, const char *path) {
    size_t len = strlen(path);
    uint8_t *names = t->d + MODS_RSTB_HDR + (size_t)t->ncrc * 8;
    for (uint32_t i = 0; i < t->nname; i++) {
        const char *nm = (const char *)names + (size_t)i * (t->slot + 4);
        if (len < t->slot && !memcmp(nm, path, len) && !nm[len]) return (uint8_t *)nm + t->slot;
    }
    uint32_t crc = mods_crc32(0, path, len), lo = 0, hi = t->ncrc;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2, c = mods_rd32(t->d + MODS_RSTB_HDR + 8 * mid);
        if (c == crc) return t->d + MODS_RSTB_HDR + 8 * mid + 4;
        if (c < crc) lo = mid + 1; else hi = mid;
    }
    return NULL;
}
// The entry a file that grew from orig to now bytes (uncompressed) needs: its growth on top (the per-type overhead stays), or the entry scaled by the growth (an overhead that
// scales with the file), whichever is larger, rounded up to 256 bytes; the old entry when the file did not grow. UINT32_MAX when it does not fit the table's 32 bits
MODS_FN uint64_t mods_rstb_need(uint32_t entry, int64_t orig, int64_t now) {
    if (now <= orig || orig < 0) return entry;
    uint64_t add = (uint64_t)entry + (uint64_t)(now - orig);
    uint64_t scaled = orig ? ((unsigned __int128)entry * (uint64_t)now + (uint64_t)orig - 1) / (uint64_t)orig : add;
    uint64_t need = ((add > scaled ? add : scaled) + 255) & ~(uint64_t)255;
    return need > UINT32_MAX ? UINT32_MAX : need;
}

// ---- zstd frame headers ----
// The uncompressed size a zstd frame's header gives (Frame_Content_Size), or -1 (not a zstd frame, or a frame that does not say)
MODS_FN int64_t mods_zstd_size(const uint8_t *h, size_t n) {
    if (n < 5 || mods_rd32(h) != 0xFD2FB528u) return -1;
    uint8_t d = h[4]; int fcs = d >> 6, single = (d >> 5) & 1, did = d & 3;
    if (d & 0x08) return -1;   // the reserved bit
    size_t p = 5 + !single + (did == 3 ? 4 : (size_t)did);
    int fs = fcs == 0 ? single : fcs == 1 ? 2 : fcs == 2 ? 4 : 8;
    if (!fs || p + fs > n) return -1;
    uint64_t v = 0; for (int i = 0; i < fs; i++) v |= (uint64_t)h[p + i] << (8 * i);
    return (int64_t)(fs == 2 ? v + 256 : v);
}
// A zstd frame holding src in raw (stored) blocks: magic, a single-segment header with an 8-byte content size, then blocks of at most 128 KiB. dst needs mods_zstd_raw_bound(n)
static inline size_t mods_zstd_raw_bound(size_t n) { return 13 + 3 * (n / 131072 + 1) + n; }
MODS_FN size_t mods_zstd_raw(const uint8_t *src, size_t n, uint8_t *dst) {
    uint8_t *o = dst; mods_wr32(o, 0xFD2FB528u); o += 4; *o++ = 0xE0;   // FCS 8 bytes, single segment, no checksum, no dictionary
    for (int i = 0; i < 8; i++) *o++ = (uint8_t)((uint64_t)n >> (8 * i));
    size_t off = 0;
    do {
        size_t k = n - off > 131072 ? 131072 : n - off; uint32_t bh = (uint32_t)(off + k == n) | (uint32_t)k << 3;   // last block flag, block type 0 (raw), size
        *o++ = (uint8_t)bh; *o++ = (uint8_t)(bh >> 8); *o++ = (uint8_t)(bh >> 16);
        memcpy(o, src + off, k); o += k; off += k;
    } while (off < n);
    return (size_t)(o - dst);
}

static inline int mods_ends_with(const char *s, const char *suf) { size_t a = strlen(s), b = strlen(suf); return a >= b && !strcmp(s + a - b, suf); }
// A file's size as the size table counts it: a .zs file's uncompressed size from its frame header (the stored size when the header does not say), else its size
MODS_FN int64_t mods_fd_size(int fd, off_t off, int64_t stored, int zs) {
    if (!zs) return stored;
    uint8_t h[18]; size_t k = stored < 18 ? (size_t)stored : 18;
    if (!k || !romfs_image_read(fd, h, k, off)) return stored;
    int64_t s = mods_zstd_size(h, k); return s >= 0 ? s : stored;
}
MODS_FN int64_t mods_path_size(const char *path, const char *rel) {
    struct stat st; if (lstat(path, &st) || !S_ISREG(st.st_mode)) return -1;
    int fd = open(path, O_RDONLY); if (fd < 0) return -1;
    int64_t s = mods_fd_size(fd, 0, st.st_size, mods_ends_with(rel, ".zs")); close(fd); return s;
}

// ---- The files under the mods: what the game reads without them (the app's overlay, then the RomFS image or folder) ----
typedef struct { romfs_img *img; char base[1024]; char *roots[2 * MODS_MAX]; int nroots; } mods_base;
// An image entry by path: each component a binary search of its directory's sorted children (hle_fs.c img_find)
MODS_FN int64_t mods_img_find(const romfs_img *m, const char *rest) {
    uint64_t k = 0;
    while (*rest) {
        while (*rest == '/') rest++;
        if (!*rest) break;
        const char *end = strchr(rest, '/'); if (!end) end = rest + strlen(rest);
        size_t len = (size_t)(end - rest);
        if (m->e[k].type) return -1;
        uint64_t lo = m->e[k].a, hi = lo + m->e[k].b; int found = 0;
        while (lo < hi) {
            uint64_t mid = lo + (hi - lo) / 2; const img_ent *x = &m->e[mid];
            int c = memcmp(m->names + x->name, rest, x->nlen < len ? x->nlen : len);
            if (!c) c = (x->nlen > len) - (x->nlen < len);
            if (!c) { k = mid; found = 1; break; }
            if (c < 0) lo = mid + 1; else hi = mid;
        }
        if (!found) return -1;
        rest = end;
    }
    return (int64_t)k;
}
// The app's overlay roots as the mount expands them (each root's amiibo-nolimit/ before it), and the RomFS (an image file or a folder)
MODS_FN void mods_base_open(mods_base *b, const char *bundled, const char *romfs) {
    memset(b, 0, sizeof *b);
    if (bundled && *bundled) {
        char *all = strdup(bundled), *save = NULL;
        for (char *r = all ? strtok_r(all, ":", &save) : NULL; r && b->nroots + 2 <= 2 * MODS_MAX; r = strtok_r(NULL, ":", &save)) {
            char sub[1100]; struct stat st; snprintf(sub, sizeof sub, "%s/amiibo-nolimit", r);
            if (!stat(sub, &st) && S_ISDIR(st.st_mode)) b->roots[b->nroots++] = strdup(sub);
            b->roots[b->nroots++] = strdup(r);
        }
        free(all);
    }
    struct stat st;
    if (romfs && !stat(romfs, &st)) {
        if (S_ISREG(st.st_mode)) b->img = romfs_image_open(romfs);
        else strlcpy(b->base, romfs, sizeof b->base);
    }
}
MODS_FN void mods_base_close(mods_base *b) {
    for (int i = 0; i < b->nroots; i++) free(b->roots[i]);
    if (b->img) romfs_image_close(b->img);
    memset(b, 0, sizeof *b);
}
// The size (as the table counts it) of the file rel names without the mods, or -1 when there is none (a file the mod adds)
MODS_FN int64_t mods_base_size(const mods_base *b, const char *rel) {
    char p[2048];
    for (int i = 0; i < b->nroots; i++) {
        snprintf(p, sizeof p, "%s/%s", b->roots[i], rel);
        if (!access(p, F_OK)) return mods_path_size(p, rel);
    }
    if (b->img) {
        int64_t k = mods_img_find(b->img, rel);
        if (k < 0 || !b->img->e[k].type) return -1;
        return mods_fd_size(b->img->fd, (off_t)b->img->e[k].a, (int64_t)b->img->e[k].b, mods_ends_with(rel, ".zs"));
    }
    if (b->base[0]) { snprintf(p, sizeof p, "%s/%s", b->base, rel); return mods_path_size(p, rel); }
    return -1;
}

// ---- The mods' files ----
typedef struct { char *rel; int mod; } mods_file;
typedef struct { mods_file *v; size_t n, cap; } mods_files;
MODS_FN void mods_walk(const char *root, const char *sub, int mod, mods_files *f, int depth) {
    char dir[2048]; snprintf(dir, sizeof dir, "%s%s%s", root, *sub ? "/" : "", sub);
    DIR *d = opendir(dir); if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;   // ., .., and hidden files (.DS_Store, the merged table's folder)
        char rel[1024], full[2048]; struct stat st;
        if (snprintf(rel, sizeof rel, "%s%s%s", sub, *sub ? "/" : "", e->d_name) >= (int)sizeof rel) continue;
        snprintf(full, sizeof full, "%s/%s", root, rel);
        if (lstat(full, &st)) continue;
        if (S_ISDIR(st.st_mode)) { if (depth < 32) mods_walk(root, rel, mod, f, depth + 1); }
        else if (S_ISREG(st.st_mode)) {
            if (f->n == f->cap && !(f->v = realloc(f->v, (f->cap = f->cap ? 2 * f->cap : 256) * sizeof *f->v))) { MODS_LOG("[RED] mods: out of memory"); abort(); }
            f->v[f->n].rel = strdup(rel); f->v[f->n].mod = mod; f->n++;
        }
    }
    closedir(d);
}
static int mods_file_cmp(const void *a, const void *b) {
    const mods_file *x = a, *y = b; int c = strcmp(x->rel, y->rel);
    return c ? c : (x->mod > y->mod) - (x->mod < y->mod);
}
MODS_FN void mods_files_free(mods_files *f) { for (size_t i = 0; i < f->n; i++) free(f->v[i].rel); free(f->v); memset(f, 0, sizeof *f); }

// What each mod does, for the log and the launcher
typedef struct {
    int files;       // its files
    int shadowed;    // of them, files a mod above it also has (that one is served)
    int bigger;      // files bigger than the file they replace (uncompressed)
    int raised;      // size table entries raised for them
    int untracked;   // bigger files the table cannot cover (no entry, or no table in this app): the game may run out of room loading them
    int own_table;   // it carries a copy of the size table (not served: the merged one is)
    int dropped;     // not served: the list of folders was full, or it is not a folder
    int no_table;    // this app has no size table to raise entries in (built before mods, or a game without one)
} mods_stat;

// The table this app was built with: DM_MODS_RSTB = "<the table's RomFS path>\n" then the uncompressed RESTBL (scripts/oot_mods_rstb.py). 1 when *t holds it (the caller frees t->d)
MODS_FN int mods_rstb_load(const char *file, mods_rstb *t, char *path, size_t pathn) {
    memset(t, 0, sizeof *t);
    if (!file || !*file) return 0;
    int fd = open(file, O_RDONLY); struct stat st;
    if (fd < 0) return 0;
    uint8_t *d = NULL;
    if (fstat(fd, &st) || st.st_size < 32 || st.st_size > (64 << 20) || !(d = malloc((size_t)st.st_size)) || !romfs_image_read(fd, d, (size_t)st.st_size, 0)) { close(fd); free(d); return 0; }
    close(fd);
    uint8_t *nl = memchr(d, '\n', (size_t)st.st_size < 1024 ? (size_t)st.st_size : 1024);
    if (!nl || (size_t)(nl - d) >= pathn) { free(d); return 0; }
    memcpy(path, d, (size_t)(nl - d)); path[nl - d] = 0;
    size_t hl = (size_t)(nl - d) + 1, n = (size_t)st.st_size - hl;
    memmove(d, d + hl, n);
    if (!mods_rstb_parse(t, d, n)) { MODS_LOG("[RED] mods: %s is not a resource size table", file); free(d); memset(t, 0, sizeof *t); return 0; }
    return 1;
}

static int mods_mkdirs(char *p) {   // mkdir -p of p's parent folders
    for (char *s = strchr(p + 1, '/'); s; s = strchr(s + 1, '/')) { *s = 0; int r = mkdir(p, 0755); *s = '/'; if (r && errno != EEXIST) return -1; }
    return 0;
}
// Writes the merged table as a zstd frame to work/romfs/<path>, through a temporary file renamed over it. 0 on success
MODS_FN int mods_rstb_write(const mods_rstb *t, const char *work, const char *path) {
    char out[2048], tmp[2100];
    snprintf(out, sizeof out, "%s/romfs/%s", work, path); snprintf(tmp, sizeof tmp, "%s.tmp", out);
    if (mods_mkdirs(out)) return -1;
    uint8_t *z = malloc(mods_zstd_raw_bound(t->n)); if (!z) return -1;
    size_t zn = mods_zstd_raw(t->d, t->n, z);
    FILE *f = fopen(tmp, "wb"); int ok = f && fwrite(z, 1, zn, f) == zn; if (f && fclose(f)) ok = 0;
    free(z);
    if (!ok || rename(tmp, out)) { unlink(tmp); return -1; }
    return 0;
}

// Puts together the rom mount's overlay list for DM_MODS (mods, ':'-separated, the first wins) over bundled (DM_ROMFS_OVERLAY, may be NULL), and the size table they need.
// romfs: DM_ROMFS (image or folder), for the sizes of the files the mods replace. rstb_file: DM_MODS_RSTB (may be NULL). work: where the merged table is written (NULL: only
// count, write nothing: the launcher's check). out (cap bytes, may be NULL with work NULL) gets the list, its folders as rom_overlay_expand will need them: each root's
// amiibo-nolimit/ is counted in, and a mod that does not fit is dropped. st (nmods entries, may be NULL) gets each DM_MODS entry's numbers. Returns how many mods are served
MODS_FN int mods_prepare(const char *mods, const char *bundled, const char *romfs, const char *rstb_file, const char *work, char *out, size_t cap, mods_stat *st, int nst) {
    char *list = strdup(mods ? mods : ""), *save = NULL, *mod[MODS_MAX]; int nm = 0;
    if (st) memset(st, 0, sizeof *st * (size_t)nst);
    for (char *r = list ? strtok_r(list, ":", &save) : NULL; r; r = strtok_r(NULL, ":", &save)) {
        if (nm == MODS_MAX) { MODS_LOG("[RED] mods: more than %d mods on; %s and those after it are not served", MODS_MAX, r); if (st && nm < nst) st[nm].dropped = 1; break; }
        mod[nm++] = r;
    }
    // the list's length as the mount expands it: room for every root, its amiibo-nolimit/ where it has one
    size_t need = 0; struct stat sb; char sub[1100];
    if (bundled && *bundled) {
        char *b = strdup(bundled), *s2 = NULL;
        for (char *r = b ? strtok_r(b, ":", &s2) : NULL; r; r = strtok_r(NULL, ":", &s2)) {
            snprintf(sub, sizeof sub, "%s/amiibo-nolimit", r); need += strlen(r) + 1 + (!stat(sub, &sb) && S_ISDIR(sb.st_mode) ? strlen(sub) + 1 : 0);
        }
        free(b);
    }
    char table_root[1100] = ""; if (work) { snprintf(table_root, sizeof table_root, "%s/romfs", work); need += strlen(table_root) + 1; }
    int served[MODS_MAX] = {0}, nserved = 0;
    for (int i = 0; i < nm; i++) {
        if (stat(mod[i], &sb) || !S_ISDIR(sb.st_mode)) { MODS_LOG("[RED] mods: %s is not a folder; skipped", mod[i]); if (st && i < nst) st[i].dropped = 1; continue; }
        snprintf(sub, sizeof sub, "%s/amiibo-nolimit", mod[i]);
        size_t len = strlen(mod[i]) + 1 + (!stat(sub, &sb) && S_ISDIR(sb.st_mode) ? strlen(sub) + 1 : 0);
        if (cap && need + len > cap)   /* need counts a separator or the NUL per folder */ { MODS_LOG("[RED] mods: the list of folders is full; %s is not served", mod[i]); if (st && i < nst) st[i].dropped = 1; continue; }
        need += len; served[i] = 1; nserved++;
    }
    // the size table
    mods_base base; mods_base_open(&base, bundled, romfs);
    mods_rstb t; char tpath[1024] = ""; int have = mods_rstb_load(rstb_file, &t, tpath, sizeof tpath);
    if (st) for (int i = 0; i < nst; i++) st[i].no_table = !have;
    mods_files f = {0};
    for (int i = 0; i < nm; i++) if (served[i]) mods_walk(mod[i], "", i, &f, 0);
    if (f.n) qsort(f.v, f.n, sizeof *f.v, mods_file_cmp);
    int raised = 0, own = 0;
    for (size_t j = 0; j < f.n; j++) {
        mods_file *x = &f.v[j]; mods_stat *s = st && x->mod < nst ? &st[x->mod] : NULL;
        if (s) s->files++;
        if (j && !strcmp(f.v[j - 1].rel, x->rel)) { if (s) s->shadowed++; continue; }   // a mod above has it
        if (strstr(x->rel, ".rsizetable") && !strncmp(x->rel, "System/Resource/", 16)) { if (s) s->own_table++; own++; continue; }
        char p[2048]; snprintf(p, sizeof p, "%s/%s", mod[x->mod], x->rel);
        int64_t now = mods_path_size(p, x->rel), orig = mods_base_size(&base, x->rel);
        if (orig < 0 || now <= orig) continue;   // a new file, or not bigger
        if (s) s->bigger++;
        char key[1024]; strlcpy(key, x->rel, sizeof key); if (mods_ends_with(key, ".zs")) key[strlen(key) - 3] = 0;
        uint8_t *slot = have ? mods_rstb_slot(&t, key) : NULL;
        uint64_t want = slot ? mods_rstb_need(mods_rd32(slot), orig, now) : 0;
        if (!slot || want == UINT32_MAX) { if (s) s->untracked++; MODS_LOG("mods: %s: %lld bytes, the original %lld: %s", x->rel, (long long)now, (long long)orig, have ? "no size table entry" : "no size table in this app"); continue; }
        if (want > mods_rd32(slot)) { MODS_LOG("mods: %s: %lld bytes, the original %lld: size table %u → %llu", x->rel, (long long)now, (long long)orig, mods_rd32(slot), (unsigned long long)want); mods_wr32(slot, (uint32_t)want); raised++; if (s) s->raised++; }
    }
    mods_files_free(&f); mods_base_close(&base);
    int use_table = 0;
    if (work && have && (raised || own)) {
        if (!mods_rstb_write(&t, work, tpath)) { use_table = 1; MODS_LOG("mods: size table %s: %d entries raised%s", tpath, raised, own ? ", served instead of a mod's own copy" : ""); }
        else MODS_LOG("[RED] mods: the merged size table could not be written to %s (errno %d): files bigger than their originals may not load", work, errno);
    } else if (work && own && !have) MODS_LOG("[RED] mods: a mod carries its own size table and this app has none to merge it with: the mod's is served");
    free(t.d);
    if (out && cap) {
        out[0] = 0;
        if (use_table) strlcat(out, table_root, cap);
        for (int i = 0; i < nm; i++) if (served[i]) { if (out[0]) strlcat(out, ":", cap); strlcat(out, mod[i], cap); }
        if (bundled && *bundled) { if (out[0]) strlcat(out, ":", cap); strlcat(out, bundled, cap); }
    }
    free(list);
    return nserved;
}
