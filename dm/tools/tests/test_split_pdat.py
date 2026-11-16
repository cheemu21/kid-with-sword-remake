"""Kirby Air Riders' asset archives reach the split: a 'PDAT' file whose assets are zstd frames, the shader programs PMAP assets in which each NVN2 control section (version 0x11 at +8)
is followed by its code area at the section plus +0x30. Synthetic bytes only."""
import contextlib
import io
import struct
import tempfile
import unittest
from pathlib import Path

from dm.tools.tests.test_split_gzip import ss
from dm.tools.tests.test_split_viper import nvn2_stage

zstd = ss.zstd_mod()


def phx_stage(sph_type, code_words=0x40):
    """A control section as the PMAP assets hold it: version 0x11 at +8, the code area's offset from the section (0xe0) at +0x30"""
    ctl, code = nvn2_stage(sph_type, code_words)
    ctl = bytearray(ctl); struct.pack_into('<I', ctl, 8, 0x11); struct.pack_into('<Q', ctl, 0x30, len(ctl))
    return bytes(ctl) + code


def pmap(*stages):   # a PMAP asset: a FlatBuffers table ('PMAP' at +4), then its programs, each section 4-aligned
    out = bytearray(struct.pack('<I', 0x18) + b'PMAP' + bytes(0x98))
    for s in stages:
        out += s + bytes(-len(s) % 0x10)
    return bytes(out)


def pdat(*assets):
    """The archive: a 0x40-byte 'PDAT' header, then each asset at a 16-byte boundary (as in assets_a000.dat) a zstd frame, or stored plain; a frame's data may hold the zstd magic itself"""
    out = bytearray(b'PDAT' + struct.pack('<I', 2) + bytes(0x38))
    for a, stored in assets:
        out += a if stored else zstd.compress(a)
        out += bytes(-len(out) % 0x10)
    return bytes(out)


class PdatArchive(unittest.TestCase):
    def scan(self, data, rel='Asset/assets_a000.dat'):
        with tempfile.TemporaryDirectory() as t, contextlib.redirect_stdout(io.StringIO()) as log:
            path = Path(t) / 'assets_a000.dat'; path.write_bytes(data)
            jobs, taken = ss.pdat_jobs([(str(path), rel)])
            self.assertEqual(taken, {str(path)})
            results = [ss.scan_file((str(path), rel, j[2])) for j in jobs]
        keys, pairs = {}, set()
        for _, k, p, extra in results:
            self.assertEqual(extra, {}); keys.update(k); pairs |= p
        return keys, pairs, log.getvalue()

    def test_programs_in_frames_and_stored(self):
        vs, ps, vs2, ps2 = phx_stage(0x0461), phx_stage(0x1462), phx_stage(0x0461, 0x41), phx_stage(0x1462, 0x42)
        noise = ss.ZSTD_FRAME + bytes(range(256)) * 8   # the magic inside a frame's data: no frame of its own
        keys, pairs, log = self.scan(pdat((pmap(vs, ps) + noise, False), (b'PMTR' + bytes(0x100), False), (pmap(vs2, ps2), True), (noise, False)))
        self.assertEqual(log, '')
        self.assertEqual(sorted(v[1] for v in keys.values()), ['ps', 'ps', 'vs', 'vs'])
        self.assertTrue(all('#PHX#var' in v[0] for v in keys.values()))
        by = {(v[1], len(v[3])): k for k, v in keys.items()}
        self.assertEqual(pairs, {(by['vs', 0x80 + 0x200], by['ps', 0x80 + 0x200]), (by['vs', 0x80 + 0x208], by['ps', 0x80 + 0x210])})   # each PMAP's vertex and pixel shader

    def test_a_section_whose_code_does_not_fit_is_left_out(self):
        bad = bytearray(phx_stage(0x0461)); struct.pack_into('<I', bad, 0x44, 0x10000)   # longer than the asset
        keys, pairs, log = self.scan(pdat((pmap(bytes(bad)), False)))
        self.assertEqual((keys, pairs), ({}, set()))


    def test_a_loose_ndsr_pack_is_scanned(self):
        """Its upscaler networks are a loose file, /Bin/Nvn2-upper_left.ndsr, which the prefilter used to drop: 'NDSR', entries from +0x10 (u32 offset, u32 length << 4 | type: 0 a vertex
        control section, 1 its code area), up to a zero entry"""
        ctl, code = nvn2_stage(0x0461)
        c = 0x40; k = c + len(ctl)
        d = bytearray(b'NDSR' + bytes(0xc)); d += struct.pack('<4I', c, len(ctl) << 4, k, len(code) >> 4 << 8 | 1) + bytes(0x10); d += bytes(c - len(d)) + ctl + code
        with tempfile.TemporaryDirectory() as t, contextlib.redirect_stdout(io.StringIO()):
            path = Path(t) / 'Nvn2-upper_left.ndsr'; path.write_bytes(bytes(d))
            rel, keys, pairs, extra = ss.scan_file((str(path), 'Bin/Nvn2-upper_left.ndsr'))
        self.assertEqual([v[1] for v in keys.values()], ['vs'])


if __name__ == '__main__': unittest.main()
