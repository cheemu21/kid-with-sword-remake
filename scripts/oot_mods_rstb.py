#!/usr/bin/env python3
# oot_mods_rstb.py <RomFS.img> <out mods_rstb.bin> [romfs_overlay folder]
# The game's resource size table, uncompressed, for mods (dm/host/mods.h): when a mod's file is bigger than the one it replaces, the host raises that file's entry in a copy of
# this table and serves it zstd-framed over the game's. The phone has no zstd decoder, so the build (which has the player's RomFS and Python's zstandard) stores it here:
# "<the table's RomFS path>\n" then the RESTBL bytes. The table the game reads without mods is the one stored: the overlay's (amiibo-nolimit/ first, scripts/oot_amiibo_overlay.py
# raises the amiibo file's entry) where it has one, else the RomFS's. Exit 1 with a reason when the game has no RESTBL table (then mods still work, without raised entries).
# The game's files are read from your own dump; nothing of the game is in this repository.
import sys, os, struct

def unzstd(z):
    try:
        import zstandard
        return zstandard.ZstdDecompressor().decompress(z, max_output_size=1 << 28)
    except ImportError:   # the zstd tool, where Python has no zstandard
        import subprocess
        return subprocess.run(['zstd', '-q', '-d', '-c'], input=z, capture_output=True, check=True).stdout

def check(t):
    # RESTBL: magic, u32 version 1, u32 name slot size, u32 CRC entries, u32 name entries; the sizes must add up (mods.h mods_rstb_parse)
    assert t[:6] == b'RESTBL', 'not a RESTBL resource size table'
    ver, slot, nc, nn = struct.unpack_from('<IIII', t, 6)
    assert ver == 1 and 22 + nc * 8 + nn * (slot + 4) == len(t), 'RESTBL version %d with %d + %d entries does not add up to %d bytes' % (ver, nc, nn, len(t))
    return nc, nn

if __name__ == '__main__':
    img, out = sys.argv[1], sys.argv[2]; ovl = sys.argv[3] if len(sys.argv) > 3 else ''
    sys.path.insert(0, os.environ.get('DMT') or os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'dm', 'tools')); import romfs_image as r
    idx = r.read_index(img)
    tables = sorted(k for k in idx if k.startswith('System/Resource/') and k.endswith('.rsizetable.zs'))
    if not tables: sys.exit('no System/Resource/*.rsizetable.zs in the RomFS')
    path = tables[-1]
    src = None
    for d in (os.path.join(ovl, 'amiibo-nolimit'), ovl):
        if ovl and os.path.isfile(os.path.join(d, path)): src = os.path.join(d, path); break
    if src:
        with open(src, 'rb') as f: z = f.read()
    else:
        _, o, n = idx[path]
        with open(img, 'rb') as f: f.seek(o); z = f.read(n)
    t = unzstd(z); nc, nn = check(t)
    with open(out, 'wb') as f: f.write(path.encode() + b'\n' + t)
    print('%s: %d entries, %d by name, %d bytes (from %s)' % (path, nc, nn, len(t), 'the overlay' if src else 'the RomFS'))
