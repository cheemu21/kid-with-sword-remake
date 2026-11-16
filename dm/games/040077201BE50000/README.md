# Kirby Air Riders (`040077201BE50000`)

A Switch 2 game: update v458752 (the NUP holds no base package: the update is the whole game), SDK 20.5.26 built for the Switch 2 (`Ounce`), NVN2. Bandai Namco and Sora's engine, whose own names start `phx::` (`phx.AssetLoadPipeline`, `phx.JobWorker`, an `AuroraGraphicsDevice` thread, a Prism schema for its data), with PhysX 5 for the Switch 2 ("gimle", `CUDAForOunce`) and NPLN for online play. Modules `main`, `subsdk0` (NVIDIA's CUDA driver: `main` imports 49 `cu*` functions from it) and `sdk`; `subsdk1` (NVIDIA NGX, DLSS) is shipped but `main` imports nothing from it. One NRO, `Bin/Module/EffectScript.nro`, loaded through `nn::ro`.

**Status:** plays on the Mac (M6 MacBook Pro, 32 GB): the title, the main menu, the lessons and Air Ride races against CPU riders on Floria Fields, with input (steering, boost charge, the lessons' prompts) and the shadows right. Played by the user from the installed app at 60 fps, about 10 ms of GPU time a frame. No IPA has been built.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `mem_alias 0x400000000`, `mem_reserve 0x550000000`, `mem_stack 0x10000000`, `app_pool 0x240000000` | [`game.tsv`](game.tsv) | the Switch 2's 9 GB, Star Fox's layout. The provisional profile's 4.38 GB alias region filled within a minute of the title, and mimalloc stopped the game (`unable to allocate OS memory`, 64 MB); with 16 GB it mapped up to +8.02 GB in the first 90 s |
| `sys_resource 0x2000000` | `game.tsv` | the NPDM declares 32 MB of system resource, so virtual address memory is on; `main` never sets a heap |
| `modules main subsdk0 sdk` | `game.tsv` | `main` imports the CUDA driver API from `subsdk0`, nothing from `subsdk1` |
| `depth_mode zero` | `game.tsv` | the game sets near = 0 with `nvnDeviceSetDepthMode` at boot |
| `romfs_marker Asset/assets_a000.dat` | `game.tsv` | the archive that holds nearly all of the game |

There is no game-specific patch.

## Files

- A NUP of 21 GB with one package, v458752: ExeFS and a RomFS of 621 files, 19.8 GB.
- `Asset/assets_a000.dat` (16.6 GB) and `Asset/assets_b000.dat` are `PDAT` archives indexed by the `PARC` catalog `Asset/assets.cat`: [phx's PMAP programs in zstd PDAT archives](../../../docs/reference/shaders.md#phxs-pmap-programs-in-zstd-pdat-archives). `assets_a000.dat` holds 194,047 zstd frames, 39 GB decoded, each an asset: a FlatBuffers table named by the four letters at +4 (`PMAP`, `PMTR`, `PANM`, `PMSH`, `PSND`, `PEFF`, `PASQ`, …). The catalog is not read by any tool here.
- `Asset.Streaming/` holds 611 `.soundstream` files and one 3.8 GB `C93975A2MV.bin` (a movie, by its name; not looked at). `Bin/` holds `config.bin`, `schema.bin` (`Prism_SBg`), the NDSR upscaler pack `Nvn2-upper_left.ndsr` and the NRO.
- The NUP has an icon (`icon.jpg`, from its control data).

## Shaders

27,568 in [`shader_map.tsv`](shader_map.tsv): 27,540 from the `PMAP` assets (6,319 vertex, 13,073 pixel, 8,072 compute, 76 geometry; 18,109 vertex / pixel pairs, one per `PMAP`) and 28 from the NDSR pack. All 1,521 keys the game asked for in its first two minutes are in it. Every vertex shader opens with [Ampere 0x80d, the vertex shaders' cull early-out](../../../docs/reference/shaders.md#ampere-0x80d-the-vertex-shaders-cull-early-out); before the translator took it, 11,121 shaders failed. Then 4,776 failed on [TMML through a uniform register or a register](../../../docs/reference/shaders.md#tmml-through-a-uniform-register-or-a-register-0xf69-0x36a), and 405 had a binding the build could not decode: [a texture word in a uniform buffer with its sampler in c2](../../../docs/reference/shaders.md#a-texture-word-in-a-uniform-buffer-with-its-sampler-in-c2). Now 27,542 of 27,568 build (about 17 minutes on an M6 MacBook Pro with 12 workers); the other 26 are geometry shaders whose translation has no topology buffer (`missing geometry topology buffer`, `dmsh_geometry.py`), two of which the game asked for at the main menu: open.

## Driving it on the Mac

`python3 scripts/build_ipa_from_nsp.py <NUP> --platform mac` builds the Mac shaders and the host and prints the run command. The picture is the top-left 1920x1080 of the 2560x1440 swap chain, as in Star Fox. Headless, through `DM_CTL` (`shot <path>` after each press):

- First boot: the opening (a lit desert scene) and, on a first launch, the "Milestones" banner; `A` goes on. The title shows an attract race behind its logo; `A` opens the main menu, which offers Lessons on a fresh save ("Start your engine in Lessons!"): `A` accepts.
- Lessons: the categories (basics 0/11, City Trial, Copy Abilities, Advanced, Machines); `LLeft` then `A` reached Copy Abilities, `A` starts "1 Proximity Copy Abilities": an explainer video, then the stage. `A` starts the ride: Kirby on the Warp Star, the speedometer, the lesson's prompts ("Get close to an enemy and press B!"); the stick steers and `B` charges a boost.
- Air Ride: from the main menu (cursor on Lessons) `LUp` reaches Air Ride, then `A` (its explainer video), `A`, `A`, `A` to the rider select (Kirby, Warp Star, 3 laps), `+` (Ready), `+` (Take off! against five level-3 CPUs), and the race starts on the meadow course about 10 s later.

## CUDA

`main` links PhysX 5's GPU simulation (its CUDA kernels as PTX for sm_70 in `main`'s data) and NVIDIA's CUDA driver (`subsdk0`, `SDK MW+NVIDIA+CUDA-12040-17_5_0-Release`). The host has no CUDA. Nothing called it from the boot to the first lesson's ride and into an Air Ride race (no `cu*` call reached `subsdk0`'s driver, which would have opened `nvdrv`): which mode PhysX runs in, and whether City Trial initializes CUDA, is not known.

## Found on this game

- [SDK 20's amiibo library with the extended application area](../../../docs/reference/services.md#sdk-20s-amiibo-library-with-the-extended-application-area): the abort a second after the title's first frames.
- [A plain hardware Opus decoder taken for a manager decoder](../../../docs/reference/audio.md#a-plain-hardware-opus-decoder-taken-for-a-manager-decoder): a host crash in `h_codec_HwOpusFini`.
- [phx's PMAP programs in zstd PDAT archives](../../../docs/reference/shaders.md#phxs-pmap-programs-in-zstd-pdat-archives) and [a loose NDSR pack left out by the prefilter](../../../docs/reference/shaders.md#a-loose-ndsr-pack-left-out-by-the-prefilter): the shaders.
- [Ampere 0x80d, the vertex shaders' cull early-out](../../../docs/reference/shaders.md#ampere-0x80d-the-vertex-shaders-cull-early-out): every vertex shader.
- [The shader dump read past a short control section](../../../docs/reference/shaders.md#the-shader-dump-read-past-a-short-control-section): `DM_NVN_SHDUMP` crashed.
- [NVN calls that were red stubs](../../../docs/reference/nvn-objects.md#nvn-calls-that-were-red-stubs): `nvnTextureBuilderGetViewOffset`, `nvnBlendStateSetAdvancedNormalizedDst`.
- [TMML through a uniform register or a register (0xf69, 0x36a)](../../../docs/reference/shaders.md#tmml-through-a-uniform-register-or-a-register-0xf69-0x36a) and [a texture word in a uniform buffer with its sampler in c2](../../../docs/reference/shaders.md#a-texture-word-in-a-uniform-buffer-with-its-sampler-in-c2): 5,181 shaders.
- [Scaling copies of a Depth16Unorm texture](../../../docs/reference/rendering.md#scaling-copies-of-a-depth16unorm-texture): 4096x4096 → 2048x2048 → 1024x1024 at a stage's load.
- [A pool entry of another texture type](../../../docs/reference/shaders.md#a-pool-entry-of-another-texture-type): the purple grass after the shadow fix.
- [A game's handle table longer than the array](../../../docs/reference/shaders.md#a-games-handle-table-longer-than-the-array) and the arrays of [a texture word in a uniform buffer with its sampler in c2](../../../docs/reference/shaders.md#a-texture-word-in-a-uniform-buffer-with-its-sampler-in-c2): the dark road and riders in races.

## Open

- **The track and the riders dark in races** (resolved). Near the camera and in a band further on, the road and every rider were black while the grass beyond and the sky were lit: the shadow lookups. The near cascades are an array of handles in c[7] ORed with a comparison sampler in c[2], whose elements the replay took without the sampler word, so every lookup compared with no comparison and read 0 ([a texture word in a uniform buffer with its sampler in c2](../../../docs/reference/shaders.md#a-texture-word-in-a-uniform-buffer-with-its-sampler-in-c2)); the band was the handles past the 16th entry of that table, which the translator's 32-element array could not reach ([a game's handle table longer than the array](../../../docs/reference/shaders.md#a-games-handle-table-longer-than-the-array)). The pools then left out 2D textures read through 2D-array handles, and the grass drew purple: [a pool entry of another texture type](../../../docs/reference/shaders.md#a-pool-entry-of-another-texture-type) (resolved). Not the [Depth16 scaling copy](../../../docs/reference/rendering.md#scaling-copies-of-a-depth16unorm-texture) (the same with and without it) and not 0x80d. Setting a Metal sampler's comparison from the game's function while its compare mode is off was tried and made the near ground dark again: reverted.
- **A SIGBUS on the title** (current, not reproduced). Once, after about 130 s idle on the title with its VP9 movie looping, the game faulted at `main+0x2ecff24` (`ldarb w8, [x8]`, `x8` = an object + 0x285, a loop that sleeps 100 µs while the object's pointer at `[x22 + 0x20]` is set), in a page the game had unmapped; a guest thread's wait address (`0x1028`, `NuCachedSource2` being created) lay in the same object. Not seen again in a 7-minute idle run with `DM_SVC=1` and other runs; that first run had older shader libraries.
- 68 shaders (`042f6652b14ced1e`, `048f29a21bbfd3be`, …) build with `[RED] … the translator deleted 3 bindless accesses (texture2D 3): their results read 0`. `regress.py check` (2026-11-16, chain 52fec04129ac against d8e22ef4ae5f) counts it as new: on the older chain these shaders built with none deleted; they are probably among the 405 whose binding was not decoded then (those did not load at run time), not checked. Not yet looked at.
- 26 geometry shaders do not build (`missing geometry topology buffer`); the main menu asks for two.
- `[RED] nn::codec VP9: a packet refused with 12 pictures waiting for a released buffer` on the title movie, four times a run; the movie loops (`end of stream after 417 pictures`).
- Memory swings between 5.5 and 10 GB resident on the title (6 GB allocated on the GPU at most), following the attract races; no steady growth in 7 minutes. iOS is not measured.
- City Trial, Top Ride, Road Trip, online and audio not checked; no `pso_manifest.tsv` recorded.
