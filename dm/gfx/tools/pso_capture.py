#!/usr/bin/env python3
# The bases with a vertex layout that a game's prewarm lists need, as rows pso_offline.py compiles into the offline pipeline archive (--layouts; the profile's pso_layouts.tsv).
# The archive made from the pair lists holds each pair's base with no vertex layout (the pulling stand-in's, pso_offline.py plan); a render pipeline of the prewarm lists (an R row of
# pso_manifest.tsv or pso_user.tsv) is built on a base with the draw's vertex layout, which the device compiles itself at its first start: the prepare step waits for every line
# before the game's first frame, so an iPhone's first start after a list grew by 1,728 render pipelines (Ocarina of Time, 2026-11-12) compiled them all before the title screen
# (more than 3.5 minutes on an M-series Mac, which had not finished them).
# Made from a Mac run of the host with DM_PSO_CAPTURE=<folder> (nvn_mtl.m pso_capture_dir) and DM_PSO_ARCHIVE at an empty folder: every base the prepare step compiles is captured as a
# Metal 4 pipelines script, the descriptor exactly as the host makes it. The script names each library loaded from memory by the SHA-256 of its file, which is mapped back to the
# library's name through the Mac libraries (b-<chain>.img or the folder); the iPhone's libraries have the same names and entry points, so pso_offline.py compiles the same descriptor
# for an iPhone's GPU. Kept: render pipeline descriptors with a vertex layout, every colour attachment unspecialized (a base), both functions named, and constants only as the
# host's prebuild sets them (pso_offline.py HOST_CONSTANTS); the rest is counted and left to the device.
# Usage: pso_capture.py --capture <folder of *.mtl4-json> --msl <Mac b-<chain> (.img or folder)> --out <pso_layouts.tsv>
# Row: vertex library <TAB> vertex entry <TAB> pixel library <TAB> pixel entry <TAB> the descriptor's other members as compact JSON (vertex_descriptor, input_primitive_topology, ...)
import argparse, collections, hashlib, json, os, sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romfs, shader_lib
import pso_offline

HEADER = '# pipeline bases with a vertex layout for the offline archive (dm/gfx/tools/pso_capture.py from a DM_PSO_CAPTURE run; pso_offline.py --layouts): vertex library, entry, pixel library, entry, the descriptor\'s other members\n'
SKIP = {'vertex_function_descriptor', 'fragment_function_descriptor', 'color_attachments', 'label', 'enable'}   # the functions are named by row columns; a base's colour attachments are all unspecialized


def library_names(lib_dir, wanted):
    """{SHA-256 (upper-case hex): library name} for the libraries of lib_dir whose hash is in wanted"""
    out, want = {}, {w.upper() for w in wanted}
    for p in sorted(romfs.Path(lib_dir).glob('*.metallib')):
        if len(out) == len(want): break
        h = hashlib.sha256()
        with p.open('rb') as f:
            while chunk := f.read(1 << 20): h.update(chunk)
        d = h.hexdigest().upper()
        if d in want: out[d] = p.name[:-len('.metallib')]
    return out


def host_constants(values):
    """Whether constant_values set exactly what the host's prebuild sets (HOST_CONSTANTS, by index)"""
    want = {i: v for i, v in pso_offline.HOST_CONSTANTS.values()}
    got = {}
    for c in values or ():
        if c.get('id_type') != 'FunctionConstantIndex' or c.get('value_type') != 'ConstantBool': return False
        got[(c.get('id') or {}).get('data')] = (c.get('value') or {}).get('data')
    return got == want


def convert(scripts, lib_dir):
    """[(vertex library, entry, pixel library, entry, members JSON)] from the captured scripts, and the counts of what was left out"""
    left = collections.Counter(); docs = [json.loads(Path(s).read_text()) for s in scripts]
    hashes = {lib['label'] for d in docs for lib in d.get('libraries', [])}
    names = library_names(lib_dir, hashes)
    rows, seen = [], set()
    for d in docs:
        libs = {lib['label']: names.get(lib['label'].upper()) for lib in d.get('libraries', [])}
        fds = d.get('function_descriptors', {})
        plain = {f['label']: (libs.get(f['library']), f['name'], None) for f in fds.get('library_function_descriptors', [])}
        spec = {f['label']: (f['function_descriptor'].split(':', 1)[-1], f.get('constant_values')) for f in fds.get('specialized_function_descriptors', [])}
        def resolve(ref):   # → (library, entry, ok) for a function descriptor reference
            label = (ref or '').split(':', 1)[-1]
            if label in plain: lib, name, _ = plain[label]; return lib, name, 'plain'
            if label in spec:
                base, values = spec[label]
                if base not in plain: return None, None, 'unknown'
                lib, name, _ = plain[base]; return lib, name, 'host' if host_constants(values) else 'constants'
            return None, None, 'unknown'
        for p in d.get('pipeline_descriptors', {}).get('render_pipeline_descriptors', []):
            if not p.get('vertex_descriptor'): left['no vertex layout (a pair base)'] += 1; continue
            if any(set(a.values()) - {'Unspecialized'} for a in p.get('color_attachments', [])): left['colour attachments specialized'] += 1; continue
            if not p.get('fragment_function_descriptor'): left['no fragment function'] += 1; continue
            vl, ve, vk = resolve(p.get('vertex_function_descriptor')); fl, fe, fk = resolve(p.get('fragment_function_descriptor'))
            if 'unknown' in (vk, fk) or not vl or not fl: left['library not among the Mac libraries'] += 1; continue
            if 'constants' in (vk, fk): left['other function constants'] += 1; continue
            members = {k: v for k, v in p.items() if k not in SKIP}
            row = (vl, ve, fl, fe, json.dumps(members, sort_keys=True, separators=(',', ':')))
            if row in seen: left['repeated'] += 1; continue
            seen.add(row); rows.append(row)
    return rows, left


def main(argv=None):
    ap = argparse.ArgumentParser(description='Bases with a vertex layout from a DM_PSO_CAPTURE run, for pso_offline.py --layouts')
    ap.add_argument('--capture', required=True, help='the DM_PSO_CAPTURE folder (its *.mtl4-json)')
    ap.add_argument('--msl', required=True, help='the Mac shader libraries the run loaded, b-<chain> (.img or folder)')
    ap.add_argument('--out', required=True, help='the rows, e.g. the profile\'s pso_layouts.tsv')
    a = ap.parse_args(argv)
    scripts = sorted(Path(a.capture).glob('*.mtl4-json'))
    if not scripts: sys.exit(f'[RED] pso_capture: no *.mtl4-json in {a.capture}')
    rows, left = convert(scripts, shader_lib.view(a.msl))
    rows.sort()
    Path(a.out).write_text(HEADER + ''.join('\t'.join(r) + '\n' for r in rows), encoding='utf-8')
    print(f'pso_capture: {len(scripts)} scripts: {len(rows)} bases with a vertex layout written to {a.out}; left out: ' + (', '.join(f'{k} {v}' for k, v in left.items()) or 'none'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
