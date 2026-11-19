// Mods from a .zip or a folder (the launcher's Import Mod, Mods.swift). Header-only, tested by tests/t_mods.c. A folder is read as it is (mods_zip_open_dir: its files
// as entries named "<folder>/<path>", copied), not zipped by iOS first: NSFileCoordinator's zipping needs the app's own identity, which an app in LiveContainer lacks.
// The archive's romfs folders become mods: each first path component named romfs (any case) ends a prefix ("romfs/", "Goku/romfs/",
// "atmosphere/contents/0400486024DEC000/romfs/", "load/0400486024DEC000/Goku/romfs/"), and each prefix is one mod, named after the folder above it (a title ID, contents,
// load, atmosphere are skipped) or the archive's name. An archive with no romfs folder whose files are game files (they name files the game has) is one mod: its files from
// the top, or from inside its one top folder. Everything else in it (an installer, a readme, exefs patches, cheats) is left out, and the exefs and cheats are said so.
// Files are written to a hidden folder in the mods folder and moved into place at the end, so a failed import leaves nothing. Read only: stored (0) and deflate (8) entries,
// Zip64; an encrypted entry, another method, a link, or a path that leaves its folder (.., an absolute path) is refused or left out. Each file is checked against its CRC-32.
#pragma once
#include "mods.h"
#include <compression.h>
#include <strings.h>
#include <sys/mount.h>

typedef struct { char *name; uint64_t csize, usize, off; uint32_t crc; uint16_t method, flags; uint8_t dir, link; } mods_zent;
typedef struct { int fd; uint64_t size; mods_zent *e; size_t n; char *root; int icloud; } mods_zip;   // root: a folder's parent (its entries are files under it); icloud: files still in iCloud

static inline uint16_t mods_rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static inline uint64_t mods_rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
#define MODS_ERR(...) (snprintf(err, errn, __VA_ARGS__), 0)

MODS_FN void mods_zip_close(mods_zip *z) {
    if (z->fd >= 0) close(z->fd);
    for (size_t i = 0; i < z->n; i++) free(z->e[i].name);
    free(z->e); free(z->root); memset(z, 0, sizeof *z); z->fd = -1;
}
// What a file that is not a zip is, for the message
static const char *mods_archive_kind(const uint8_t *h, size_t n) {
    if (n >= 6 && !memcmp(h, "7z\xBC\xAF\x27\x1C", 6)) return "a 7z archive";
    if (n >= 4 && !memcmp(h, "Rar!", 4)) return "a RAR archive";
    if (n >= 2 && h[0] == 0x1f && h[1] == 0x8b) return "a gzip archive";
    if (n >= 6 && !memcmp(h, "\xFD" "7zXZ", 6)) return "an xz archive";
    return NULL;
}
// Reads the central directory. 1, or 0 with the reason in err
MODS_FN int mods_zip_open(mods_zip *z, const char *path, char *err, size_t errn) {
    memset(z, 0, sizeof *z); z->fd = open(path, O_RDONLY);
    struct stat st;
    if (z->fd < 0 || fstat(z->fd, &st)) return MODS_ERR("The file can't be opened (errno %d).", errno);
    z->size = (uint64_t)st.st_size;
    uint8_t head[8] = {0}; romfs_image_read(z->fd, head, z->size < 8 ? (size_t)z->size : 8, 0);
    const char *kind = mods_archive_kind(head, sizeof head);
    if (kind) return MODS_ERR("This is %s. Mods import from a .zip file or a folder: unpack it first with an app that opens it, then import the folder.", kind);
    size_t tail = z->size < 65557 ? (size_t)z->size : 65557; uint8_t *b = malloc(tail ? tail : 1);
    if (!b || tail < 22 || !romfs_image_read(z->fd, b, tail, (off_t)(z->size - tail))) { free(b); return MODS_ERR("This file isn't a zip archive."); }
    ssize_t eo = -1;
    for (ssize_t i = (ssize_t)tail - 22; i >= 0; i--) if (mods_rd32(b + i) == 0x06054b50u) { eo = i; break; }
    if (eo < 0) { free(b); return MODS_ERR("This file isn't a zip archive."); }
    uint64_t count = mods_rd16(b + eo + 10), cdsize = mods_rd32(b + eo + 12), cdoff = mods_rd32(b + eo + 16);
    uint64_t eocd = z->size - tail + (uint64_t)eo;
    if ((count == 0xffff || cdsize == 0xffffffffu || cdoff == 0xffffffffu) && eocd >= 20) {   // Zip64: the locator just before, then the Zip64 end record
        uint8_t loc[20], e64[56];
        if (romfs_image_read(z->fd, loc, 20, (off_t)(eocd - 20)) && mods_rd32(loc) == 0x07064b50u &&
            romfs_image_read(z->fd, e64, 56, (off_t)mods_rd64(loc + 8)) && mods_rd32(e64) == 0x06064b50u) {
            count = mods_rd64(e64 + 32); cdsize = mods_rd64(e64 + 40); cdoff = mods_rd64(e64 + 48);
        }
    }
    free(b);
    if (cdoff > z->size || cdsize > z->size - cdoff || cdsize > (256u << 20) || count > cdsize / 46) return MODS_ERR("The zip archive is damaged (its file list).");
    uint8_t *cd = malloc(cdsize ? (size_t)cdsize : 1);
    if (!cd || !romfs_image_read(z->fd, cd, (size_t)cdsize, (off_t)cdoff)) { free(cd); return MODS_ERR("The zip archive can't be read."); }
    z->e = calloc(count ? count : 1, sizeof *z->e);
    size_t p = 0;
    for (uint64_t i = 0; i < count; i++) {
        if (p + 46 > cdsize || mods_rd32(cd + p) != 0x02014b50u) { free(cd); return MODS_ERR("The zip archive is damaged (entry %llu).", (unsigned long long)i); }
        const uint8_t *c = cd + p; uint16_t nl = mods_rd16(c + 28), xl = mods_rd16(c + 30), cl = mods_rd16(c + 32);
        if (p + 46 + nl + xl + cl > cdsize) { free(cd); return MODS_ERR("The zip archive is damaged (entry %llu).", (unsigned long long)i); }
        mods_zent *e = &z->e[z->n++];
        e->flags = mods_rd16(c + 8); e->method = mods_rd16(c + 10); e->crc = mods_rd32(c + 16);
        e->csize = mods_rd32(c + 20); e->usize = mods_rd32(c + 24); e->off = mods_rd32(c + 42);
        uint32_t ext = mods_rd32(c + 38);
        e->link = (c[5] == 3 || c[5] == 19) && ((ext >> 16) & S_IFMT) == S_IFLNK;   // made by Unix / macOS: the mode in the high half
        for (const uint8_t *x = c + 46 + nl, *xe = x + xl; x + 4 <= xe;) {           // the Zip64 extra field: the 32-bit values that are all ones, in order
            uint16_t id = mods_rd16(x), sz = mods_rd16(x + 2); const uint8_t *v = x + 4, *ve = v + sz;
            if (ve > xe) break;
            if (id == 1) {
                if (e->usize == 0xffffffffu && v + 8 <= ve) { e->usize = mods_rd64(v); v += 8; }
                if (e->csize == 0xffffffffu && v + 8 <= ve) { e->csize = mods_rd64(v); v += 8; }
                if (e->off == 0xffffffffu && v + 8 <= ve) { e->off = mods_rd64(v); }
            }
            x = ve;
        }
        e->name = malloc(nl + 1u); memcpy(e->name, c + 46, nl); e->name[nl] = 0;
        for (char *s = e->name; *s; s++) if (*s == '\\') *s = '/';
        e->dir = nl && e->name[nl - 1] == '/';
        p += 46u + nl + xl + cl;
    }
    free(cd);
    return 1;
}
// A folder as an archive: its files (links left out) as entries "<the folder's name>/<path inside it>". A file the Files app has not downloaded yet is a hidden
// ".<name>.icloud" placeholder: counted in icloud, so the import can say so
static void mods_dir_walk(mods_zip *z, const char *base, const char *rel, size_t *cap, int depth) {
    char dir[2048]; snprintf(dir, sizeof dir, "%s/%s", base, rel);
    DIR *d = opendir(dir); if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (e->d_name[0] == '.' && mods_ends_with(e->d_name, ".icloud")) { z->icloud++; continue; }
        char r[1024], full[2048]; struct stat st;
        if (snprintf(r, sizeof r, "%s/%s", rel, e->d_name) >= (int)sizeof r) continue;
        snprintf(full, sizeof full, "%s/%s", base, r);
        if (lstat(full, &st)) continue;
        if (S_ISDIR(st.st_mode)) { if (depth < 32) mods_dir_walk(z, base, r, cap, depth + 1); continue; }
        if (!S_ISREG(st.st_mode)) continue;
        if (z->n == *cap && !(z->e = realloc(z->e, (*cap = *cap ? 2 * *cap : 256) * sizeof *z->e))) { MODS_LOG("[RED] mods: out of memory"); abort(); }
        mods_zent *x = &z->e[z->n++]; memset(x, 0, sizeof *x);
        x->name = strdup(r); x->usize = x->csize = (uint64_t)st.st_size; x->method = 0xffff;   // 0xffff: a file to copy
    }
    closedir(d);
}
MODS_FN int mods_zip_open_dir(mods_zip *z, const char *path, char *err, size_t errn) {
    memset(z, 0, sizeof *z); z->fd = -1;
    char p[1024]; strlcpy(p, path, sizeof p);
    while (strlen(p) > 1 && p[strlen(p) - 1] == '/') p[strlen(p) - 1] = 0;
    char *slash = strrchr(p, '/'); if (!slash || !slash[1]) return MODS_ERR("This folder can't be read.");
    *slash = 0; z->root = strdup(*p ? p : "/");
    size_t cap = 0; mods_dir_walk(z, z->root, slash + 1, &cap, 0);
    if (!z->n && !z->icloud) return MODS_ERR("This folder can't be read, or it is empty (errno %d).", errno);
    return 1;
}
MODS_FN int mods_copy_file(const char *src, const char *dst, uint64_t size, char *err, size_t errn) {
    int in = open(src, O_RDONLY); if (in < 0) return MODS_ERR("%s can't be read (errno %d).", src, errno);
    int out = open(dst, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (out < 0) { close(in); return MODS_ERR("%s can't be written (errno %d).", dst, errno); }
    enum { B = 1 << 18 }; uint8_t *b = malloc(B); uint64_t got = 0; int ok = !!b;
    while (ok) {
        ssize_t r = read(in, b, B); if (r < 0 && errno == EINTR) continue;
        if (r < 0) { ok = 0; snprintf(err, errn, "%s can't be read (errno %d).", src, errno); break; }
        if (!r) break;
        for (ssize_t w = 0; w < r;) { ssize_t k = write(out, b + w, (size_t)(r - w)); if (k < 0 && errno == EINTR) continue; if (k <= 0) { ok = 0; snprintf(err, errn, "The mod can't be written: the iPhone may be out of space (errno %d).", errno); break; } w += k; }
        got += (uint64_t)r;
    }
    free(b); close(in); if (close(out)) ok = 0;
    if (ok && got != size) { ok = 0; snprintf(err, errn, "%s changed while it was being copied.", src); }
    if (!ok) unlink(dst);
    return ok;
}
// Writes entry e to the new file dst. 1, or 0 with the reason in err (dst removed)
MODS_FN int mods_zip_extract(const mods_zip *z, const mods_zent *e, const char *dst, char *err, size_t errn) {
    if (z->root) { char src[2048]; snprintf(src, sizeof src, "%s/%s", z->root, e->name); return mods_copy_file(src, dst, e->usize, err, errn); }
    if (e->flags & 1) return MODS_ERR("The zip archive is password-protected. Unpack it with an app that knows the password, then import the folder.");
    if (e->method != 0 && e->method != 8) return MODS_ERR("The zip archive uses a kind of compression this app can't read (method %u). Unpack it in the Files app, then import the folder.", e->method);
    uint8_t lh[30];
    if (e->off > z->size || !romfs_image_read(z->fd, lh, 30, (off_t)e->off) || mods_rd32(lh) != 0x04034b50u) return MODS_ERR("The zip archive is damaged (%s).", e->name);
    uint64_t pos = e->off + 30 + mods_rd16(lh + 26) + mods_rd16(lh + 28);
    if (pos > z->size || e->csize > z->size - pos) return MODS_ERR("The zip archive is damaged (%s).", e->name);
    int fd = open(dst, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) return MODS_ERR("%s can't be written (errno %d).", dst, errno);
    enum { IN = 1 << 16, OUT = 1 << 18 };
    uint8_t *in = malloc(IN), *ob = malloc(OUT); uint64_t left = e->csize, wrote = 0; uint32_t crc = 0; int ok = 0;
    compression_stream s; int inited = 0;
    if (!in || !ob) goto done;
    if (e->method == 8) { if (compression_stream_init(&s, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_OK) goto done; inited = 1; s.src_size = 0; }
    for (;;) {
        size_t produced = 0;
        if (e->method == 0) {
            if (!left) { ok = 1; break; }
            size_t k = left < OUT ? (size_t)left : OUT;
            if (!romfs_image_read(z->fd, ob, k, (off_t)pos)) break;
            pos += k; left -= k; produced = k;
        } else {
            if (!s.src_size && left) { size_t k = left < IN ? (size_t)left : IN; if (!romfs_image_read(z->fd, in, k, (off_t)pos)) break; pos += k; left -= k; s.src_ptr = in; s.src_size = k; }
            size_t had = s.src_size; s.dst_ptr = ob; s.dst_size = OUT;
            compression_status cs = compression_stream_process(&s, left ? 0 : COMPRESSION_STREAM_FINALIZE);
            if (cs == COMPRESSION_STATUS_ERROR) break;
            produced = OUT - s.dst_size;
            if (cs == COMPRESSION_STATUS_END) ok = 2;
            else if (!produced && had == s.src_size && !left) break;   // no more input and no progress: cut short
        }
        if (produced) {
            if (wrote + produced > e->usize) { ok = 0; break; }
            for (size_t w = 0; w < produced;) { ssize_t r = write(fd, ob + w, produced - w); if (r < 0 && errno == EINTR) continue; if (r <= 0) { ok = -1; break; } w += (size_t)r; }
            if (ok < 0) { ok = 0; snprintf(err, errn, "The mod can't be written: the iPhone may be out of space (errno %d).", errno); break; }
            crc = mods_crc32(crc, ob, produced); wrote += produced;
        }
        if (ok == 2) { ok = 1; break; }
    }
done:
    if (inited) compression_stream_destroy(&s);
    free(in); free(ob);
    if (close(fd)) ok = 0;
    if (ok && (wrote != e->usize || crc != e->crc)) { ok = 0; snprintf(err, errn, "The zip archive is damaged (%s fails its check).", e->name); }
    else if (!ok && !err[0]) snprintf(err, errn, "The zip archive is damaged (%s).", e->name);
    if (!ok) unlink(dst);
    return ok;
}

// rm -rf
MODS_FN int mods_rm_tree(const char *p) {
    struct stat st; if (lstat(p, &st)) return errno == ENOENT ? 0 : -1;
    if (!S_ISDIR(st.st_mode)) return unlink(p);
    DIR *d = opendir(p); if (!d) return -1;
    struct dirent *e; int r = 0;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char c[2048]; snprintf(c, sizeof c, "%s/%s", p, e->d_name); if (mods_rm_tree(c)) r = -1;
    }
    closedir(d);
    return rmdir(p) ? -1 : r;
}
static int mods_ieq(const char *a, size_t n, const char *b) { return strlen(b) == n && !strncasecmp(a, b, n); }
static int mods_is_tid(const char *a, size_t n) { if (n != 16) return 0; for (size_t i = 0; i < n; i++) if (!strchr("0123456789abcdefABCDEF", a[i])) return 0; return 1; }
// Whether a path inside a mod is one to write: no empty, ".", ".." components, nothing hidden (._ resource forks, .DS_Store), nothing under __MACOSX
static int mods_rel_ok(const char *rel) {
    if (!*rel || *rel == '/') return 0;
    for (const char *s = rel; *s;) {
        const char *e = strchr(s, '/'); size_t n = e ? (size_t)(e - s) : strlen(s);
        if (!n || s[0] == '.' || mods_ieq(s, n, "__MACOSX")) return 0;
        s += n; if (*s) s++;
    }
    return 1;
}
// The length of the prefix ending in name's first "romfs/" component, or -1
static ssize_t mods_romfs_prefix(const char *name) {
    for (const char *s = name; *s;) {
        const char *e = strchr(s, '/'); if (!e) return -1;
        if (mods_ieq(s, (size_t)(e - s), "romfs")) return e + 1 - name;
        s = e + 1;
    }
    return -1;
}
static int mods_utf8_ok(const char *s) {
    for (const unsigned char *p = (const unsigned char *)s; *p;) {
        int k = *p < 0x80 ? 0 : (*p & 0xE0) == 0xC0 ? 1 : (*p & 0xF0) == 0xE0 ? 2 : (*p & 0xF8) == 0xF0 ? 3 : -1;
        if (k < 0 || (k == 1 && *p < 0xC2)) return 0;
        p++; while (k--) { if ((*p & 0xC0) != 0x80) return 0; p++; }
    }
    return 1;
}
// A mod's name from its prefix: the nearest folder above romfs that is not a title ID or one of the loaders' own folders; fallback when there is none
static void mods_name_from(const char *prefix, size_t plen, const char *fallback, char *out, size_t n) {
    const char *skip[] = {"romfs", "contents", "atmosphere", "load", "mods", "sdmc", "switch", "titles", NULL};
    out[0] = 0;
    const char *end = prefix + plen;   // walk back over the components
    while (end > prefix) {
        const char *e = end - 1;       // the '/' after a component
        const char *s = e; while (s > prefix && s[-1] != '/') s--;
        size_t k = (size_t)(e - s); int bad = !k || mods_is_tid(s, k);
        for (int i = 0; skip[i] && !bad; i++) if (mods_ieq(s, k, skip[i])) bad = 1;
        if (!bad) { size_t m = k < n - 1 ? k : n - 1; memcpy(out, s, m); out[m] = 0; break; }
        end = s;
    }
    if (!out[0]) strlcpy(out, fallback && *fallback ? fallback : "Mod", n);
    // a folder name: no /, :, control characters, no leading dot or space; at most 60 bytes, cut at a character boundary
    for (char *c = out; *c; c++) if (*c == '/' || *c == ':' || *c == '\\' || (unsigned char)*c < 0x20) *c = '_';
    if (!mods_utf8_ok(out)) for (char *c = out; *c; c++) if ((unsigned char)*c >= 0x80) *c = '_';   // a name from an old Windows zip (code page bytes): the file system takes only UTF-8
    char *c = out; while (*c == '.' || *c == ' ') c++;
    memmove(out, c, strlen(c) + 1);
    if (strlen(out) > 60) { size_t k = 60; while (k && ((unsigned char)out[k] & 0xC0) == 0x80) k--; out[k] = 0; }
    while (*out && out[strlen(out) - 1] == ' ') out[strlen(out) - 1] = 0;
    if (!*out) strlcpy(out, "Mod", n);
}

// Imports the zip, or the folder, at path into mods_dir (made if needed). fallback: the name for a mod the archive does not name (the archive's file name). bundled/romfs: the game's files as
// mods_prepare takes them, to recognize an archive with no romfs folder. Returns how many mods were added (their names in added, one per line), or 0 with the reason in msg.
// On success msg says what was left out, or is empty
MODS_FN int mods_import_zip(const char *path, const char *mods_dir, const char *fallback, const char *bundled, const char *romfs, char *msg, size_t msgn, char *added, size_t addedn) {
    char *err = msg; size_t errn = msgn; msg[0] = 0; if (added && addedn) added[0] = 0;
    struct stat sp; int folder = !stat(path, &sp) && S_ISDIR(sp.st_mode);
    mods_zip z; if (!(folder ? mods_zip_open_dir(&z, path, msg, msgn) : mods_zip_open(&z, path, msg, msgn))) { mods_zip_close(&z); return 0; }
    if (z.icloud) { mods_zip_close(&z); return MODS_ERR("Some of this folder's files are still in iCloud. In the Files app, touch and hold the folder, tap Download Now, then import it again."); }
    // the prefixes
    enum { MAXP = 16 }; char *pre[MAXP]; size_t plen[MAXP]; int np = 0, exefs = 0, cheats = 0, more = 0;
    for (size_t i = 0; i < z.n; i++) {
        const mods_zent *e = &z.e[i]; if (e->dir || e->link) continue;
        for (const char *s = e->name; *s;) { const char *q = strchr(s, '/'); if (!q) break; size_t k = (size_t)(q - s); if (mods_ieq(s, k, "exefs")) exefs = 1; if (mods_ieq(s, k, "cheats")) cheats = 1; s = q + 1; }
        ssize_t k = mods_romfs_prefix(e->name); if (k < 0 || strstr(e->name, "__MACOSX/")) continue;
        int seen = 0; for (int j = 0; j < np; j++) if (plen[j] == (size_t)k && !strncmp(pre[j], e->name, (size_t)k)) seen = 1;
        if (seen) continue;
        if (np == MAXP) { more = 1; continue; }
        pre[np] = strndup(e->name, (size_t)k); plen[np++] = (size_t)k;
    }
    if (!np) {   // no romfs folder: game files from the top, or from inside the one folder everything is in
        const char *top = NULL; size_t tl = 0; int one = 1, files = 0;
        for (size_t i = 0; i < z.n && one; i++) {
            const mods_zent *e = &z.e[i]; if (e->dir || e->link || strstr(e->name, "__MACOSX/")) continue;
            const char *q = strchr(e->name, '/'); if (!q) { one = 0; break; }
            if (!top) { top = e->name; tl = (size_t)(q + 1 - e->name); } else if (strncmp(top, e->name, tl)) one = 0;
        }
        size_t skip = one && top ? tl : 0;
        mods_base b; mods_base_open(&b, bundled, romfs);
        for (size_t i = 0; i < z.n; i++) {
            const mods_zent *e = &z.e[i]; if (e->dir || e->link || strlen(e->name) <= skip || !mods_rel_ok(e->name + skip)) continue;
            if ((b.img || b.base[0] || b.nroots) && mods_base_size(&b, e->name + skip) >= 0) files++;
        }
        mods_base_close(&b);
        if (!files) { mods_zip_close(&z); return MODS_ERR("No romfs folder in this archive, and none of its files are game files. A mod for this game has a folder named romfs."); }
        pre[np] = strndup(top ? top : "", skip); plen[np++] = skip;
    }
    // room for it
    uint64_t total = 0;
    for (size_t i = 0; i < z.n; i++) for (int j = 0; j < np; j++) if (!z.e[i].dir && !strncmp(z.e[i].name, pre[j], plen[j])) { total += z.e[i].usize; break; }
    mkdir(mods_dir, 0755);
    struct statfs fs;
    if (!statfs(mods_dir, &fs) && (uint64_t)fs.f_bavail * fs.f_bsize < total + (64u << 20)) {
        snprintf(msg, msgn, "Not enough free space: the mod needs %.1f GB, and %.1f GB is free.", total / 1e9, (double)fs.f_bavail * fs.f_bsize / 1e9);
        for (int j = 0; j < np; j++) free(pre[j]);
        mods_zip_close(&z); return 0;
    }
    int n = 0; char names[MAXP][64];
    for (int j = 0; j < np && !msg[0]; j++) {
        char name[64], dst[1200], tmp[1200];
        mods_name_from(pre[j], plen[j], fallback, name, sizeof name);
        for (int k = 2; ; k++) {   // a name no other mod has
            int clash = 0; for (int m = 0; m < n; m++) if (!strcmp(names[m], name)) clash = 1;
            snprintf(dst, sizeof dst, "%s/%s", mods_dir, name);
            if (!clash && access(dst, F_OK)) break;
            char base[64]; mods_name_from(pre[j], plen[j], fallback, base, sizeof base);
            size_t bl = strlen(base); if (bl > 52) { bl = 52; while (bl && ((unsigned char)base[bl] & 0xC0) == 0x80) bl--; base[bl] = 0; }
            snprintf(name, sizeof name, "%s %d", base, k);
        }
        snprintf(tmp, sizeof tmp, "%s/.import-%d-%d", mods_dir, (int)getpid(), j);
        mods_rm_tree(tmp);
        int files = 0;
        for (size_t i = 0; i < z.n && !msg[0]; i++) {
            const mods_zent *e = &z.e[i];
            if (e->dir || e->link || strncmp(e->name, pre[j], plen[j]) || !mods_rel_ok(e->name + plen[j])) continue;
            char out[2400]; snprintf(out, sizeof out, "%s/romfs/%s", tmp, e->name + plen[j]);
            if (mods_mkdirs(out)) { snprintf(msg, msgn, "The mod can't be written (errno %d).", errno); break; }
            if (mods_zip_extract(&z, e, out, msg, msgn)) files++;
        }
        if (!msg[0] && files && !rename(tmp, dst)) { strlcpy(names[n++], name, sizeof names[0]); continue; }
        if (!msg[0] && files) snprintf(msg, msgn, "The mod can't be moved into place (errno %d).", errno);
        mods_rm_tree(tmp);
    }
    for (int j = 0; j < np; j++) free(pre[j]);
    mods_zip_close(&z);
    if (msg[0]) {   // a failure: the mods this import already added go too, so it is all or nothing
        for (int m = 0; m < n; m++) { char d[1200]; snprintf(d, sizeof d, "%s/%s", mods_dir, names[m]); mods_rm_tree(d); }
        return 0;
    }
    if (!n) return MODS_ERR("The romfs folder in this archive is empty.");
    for (int m = 0; m < n && added; m++) { if (m) strlcat(added, "\n", addedn); strlcat(added, names[m], addedn); }
    if (exefs || cheats || more)
        snprintf(msg, msgn, "%s%s%s", exefs ? "Its exefs patches aren't used: only romfs files are. " : "", cheats ? "Its cheats aren't imported here. " : "",
                 more ? "It has more than 16 romfs folders; the first 16 were imported." : "");
    return n;
}
