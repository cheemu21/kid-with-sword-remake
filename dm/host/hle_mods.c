// The launcher's side of mods (mods_api.h): its per-mod check and its import, on the same code the rom mount uses (mods.h, mods_zip.h; hle_fs.c rom_overlay_env)
#include "dm.h"
#include "mods.h"
#include "mods_zip.h"
#include "mods_api.h"

void dm_mods_check(const char *mod_romfs, int32_t out[6]) {
    mods_stat s; mods_prepare(mod_romfs, getenv("DM_ROMFS_OVERLAY"), getenv("DM_ROMFS"), getenv("DM_MODS_RSTB"), NULL, NULL, 0, &s, 1);
    out[0] = s.files; out[1] = s.bigger; out[2] = s.raised; out[3] = s.untracked; out[4] = s.own_table; out[5] = s.no_table;
}
int dm_mods_import(const char *zip, const char *mods_dir, const char *name, char *msg, size_t msgn, char *added, size_t addedn) {
    int n = mods_import_zip(zip, mods_dir, name, getenv("DM_ROMFS_OVERLAY"), getenv("DM_ROMFS"), msg, msgn, added, addedn);
    if (n) LOG("mods: imported %d from %s%s%s", n, zip, msg[0] ? ": " : "", msg);
    else LOG("[RED] mods: import of %s failed: %s", zip, msg);
    return n;
}
