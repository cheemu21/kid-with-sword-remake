// The mods functions the launcher calls (hle_mods.c; Mods.swift through DmIOS-Bridging-Header.h). The game files they compare against come from the environment main.m sets
// before the launcher: DM_ROMFS, DM_ROMFS_OVERLAY (the app's own replacements) and DM_MODS_RSTB (the size table, mods.h).
#pragma once
#include <stddef.h>
#include <stdint.h>
// What the mod whose romfs folder is mod_romfs does on its own: out[0] files, [1] bigger than the files they replace, [2] size table entries raised for them at Play,
// [3] bigger files the table cannot cover (the game may run out of room loading them), [4] it carries its own size table (not served), [5] this app has no size table
void dm_mods_check(const char *mod_romfs, int32_t out[6]);
// Imports a .zip into mods_dir; name: the name for a mod the archive does not name. Returns how many mods were added (their folder names in added, one per line),
// or 0 with the reason in msg. After a success msg may say what was left out
int dm_mods_import(const char *zip, const char *mods_dir, const char *name, char *msg, size_t msgn, char *added, size_t addedn);
