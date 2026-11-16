#!/usr/bin/env python3
"""Make a game's Mac app and put it in /Applications, the way Ocarina of Time's was made.

  python3 scripts/make_mac_app.py ~/Downloads/"Mario Kart World [0400C3F00006E000].nup" --icon ~/Pictures/mkw.png

What it does, in order:
  1. Game files under the home folder (Downloads) move to <root>/<game folder>/ (default root /Users/Shared/nxnative): the repository keeps game files out of the home folder.
     A file (.nup, .nsp, .xci) gets a folder of its own; a folder moves as it is.
  2. The Mac switches go into <game folder>/env_mac.txt the first time (later runs keep your edits): full-detail textures, no heat cap, the guest copies of
     uploaded textures kept. Resolution, upscaling, frame generation and the frame rate stay in the app's own settings window.
  3. scripts/build_ipa_from_nsp.py --platform mac-app builds the app: the whole shader map, the Mac host, the pipeline archive for this Mac's GPU (the smooth first run).
     The icon is --icon, else <game folder>/icon.png or icon.jpg, else the game's own when its files carry one.
  4. The app replaces the one of the same name in /Applications (the old one is kept in the game folder as <name>-old.app until the next run), and Launch Services is told.

The save stays in ~/Library/Application Support/nxnative/<title ID>/ and is not touched. Exit status non-zero on any error.
"""
import argparse, os, re, shutil, subprocess, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
HOME = Path.home().resolve()
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
ENV_DEFAULT = """\
# Mac app switches (scripts/make_mac_app.py writes this once; edit it freely, the next build takes it)
# full-detail textures: a profile that drops the finest level of large compressed textures to save memory keeps it
DM_NVN_TEX_SOFT=0
# no heat cap on the Mac
DM_THERMAL_CAP=0
# keep the guest copies of uploaded textures (docs/reference/memory.md, "The guest copy of uploaded textures given back"): the Mac has the memory
DM_TEX_RELEASE=0
"""


class Fail(Exception): pass


def folder_name(p):   # "Mario Kart World [0400C3F00006E000].nup" -> "MarioKartWorld"
    stem = re.sub(r'\[[^\]]*\]|\([^)]*\)', '', p.stem if p.is_file() else p.name)
    return re.sub(r'[^A-Za-z0-9]+', '', stem.title()) or 'Game'


def under_home(p):
    try: p.resolve().relative_to(HOME); return True
    except ValueError: return False


def place(src, root):   # the game's folder outside the home folder, with the game files in it
    src = src.expanduser().resolve()
    if not src.exists(): raise Fail(f'no such file or folder: {src}')
    if not under_home(src): return src.parent if src.is_file() else src
    dest = root / folder_name(src)
    dest.mkdir(parents=True, exist_ok=True)
    target = dest / src.name if src.is_file() else dest
    if src.is_file():
        if target.exists(): raise Fail(f'{target} already exists; remove one of the two copies')
        print(f'moving {src} -> {target}'); shutil.move(src, target)
    else:
        for f in src.iterdir():
            if (dest / f.name).exists(): raise Fail(f'{dest / f.name} already exists; remove one of the two copies')
            shutil.move(f, dest / f.name)
        print(f'moved the contents of {src} -> {dest}'); src.rmdir()
    return dest


def python():   # the tool venv the builds use (one for every game)
    for c in (os.environ.get('DM_PYTHON'), '/Users/Shared/nxnative/venv/bin/python3'):
        if c and Path(c).is_file(): return c
    return sys.executable


def build(folder, a):
    env_file = folder / 'env_mac.txt'
    if not env_file.exists(): env_file.write_text(ENV_DEFAULT); print(f'wrote {env_file}')
    for kv in a.env:
        if '=' not in kv: raise Fail(f'--env takes KEY=VALUE: {kv}')
        k = kv.split('=', 1)[0]
        lines = [ln for ln in env_file.read_text().splitlines() if not ln.startswith(k + '=')]
        env_file.write_text('\n'.join(lines + [kv]) + '\n')
    icon = Path(a.icon).expanduser().resolve() if a.icon else next((folder / n for n in ('icon.png', 'icon.jpg') if (folder / n).is_file()), None)
    if icon and not icon.is_file(): raise Fail(f'no such icon: {icon}')
    games = [p for p in folder.iterdir() if p.suffix.lower() in ('.nup', '.nsp', '.nsz', '.xci') and not p.name.startswith('._')]
    target = games[0] if len(games) == 1 and games[0].suffix.lower() == '.nup' else folder   # a NUP is given as the file itself
    cmd = [python(), REPO / 'scripts/build_ipa_from_nsp.py', target, '--platform', 'mac-app', '--env-file', env_file, '-l', a.language, '--progress', 'lines']
    if icon: cmd += ['--icon', icon]
    if a.name: cmd += ['--app-name', a.name]
    if a.keys: cmd += ['-k', a.keys]
    if a.seen_shaders: cmd += ['--seen-shaders']
    log = folder / 'build-mac-app.log'
    print(f'building (log: {log}); a first build of a game takes 20-60 minutes, mostly shaders')
    done = None
    with open(log, 'w') as out:
        p = subprocess.Popen([str(c) for c in cmd], cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for ln in p.stdout:
            out.write(ln); out.flush(); sys.stdout.write(ln)
            m = re.match(r'\[[\d:]+\] done: (.+\.app) \(', ln)
            if m: done = Path(m.group(1))
        rc = p.wait()
    if rc or not done: raise Fail(f'the build failed (exit {rc}); the reasons are at the end of {log}')
    return done


def install(app, folder):
    dest = Path('/Applications') / app.name
    if dest.exists():
        old = folder / f'{app.stem}-old.app'
        if old.exists(): shutil.rmtree(old)
        shutil.move(dest, old); print(f'the previous app is kept at {old} (the next run removes it)')
    shutil.move(app, dest)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', dest], check=True)
    subprocess.run([LSREGISTER, '-f', dest], check=False)
    return dest


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('game', help='the game: a .nup / .nsp / .xci file, or a folder holding its NSPs or a dump')
    ap.add_argument('--icon', help='the app icon: a square PNG or JPEG (default: icon.png / icon.jpg in the game folder, else the game\'s own)')
    ap.add_argument('--name', help='the app name (default: the game name in its files, else its profile)')
    ap.add_argument('-l', '--language', default='es-419', help='game language (default es-419)')
    ap.add_argument('-k', '--keys', help='prod.keys, for NSPs or an XCI (a NUP or a dump needs none)')
    ap.add_argument('--env', action='append', default=[], metavar='KEY=VALUE', help='one more switch for env_mac.txt (repeatable)')
    ap.add_argument('--root', default='/Users/Shared/nxnative', help='where game folders moved out of the home folder go (default /Users/Shared/nxnative)')
    ap.add_argument('--seen-shaders', action='store_true', help='only the shaders the profile\'s playtests used: minutes instead of the full map; areas outside it draw incomplete')
    ap.add_argument('--no-install', action='store_true', help='leave the app in the game folder instead of /Applications')
    a = ap.parse_args(argv)
    sys.stdout.reconfigure(line_buffering=True)   # the build's lines as they come, also into a file
    try:
        folder = place(Path(a.game), Path(a.root))
        app = build(folder, a)
        if '-provisional' in app.name:
            print(f'[NOTE] this game has no profile in dm/games: the app is from a provisional profile and may not boot ({app}); it stays in the game folder')
            return 0
        if not a.no_install: app = install(app, folder)
        print(f'ready: {app}')
        return 0
    except Fail as e:
        print(f'error: {e}', file=sys.stderr); return 1
    except subprocess.CalledProcessError as e:
        print(f'error: {e}', file=sys.stderr); return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
