# GIF decoders compared in the sandbox

The GIF decoder of the module is Wuffs.

| Decoder | Version | Glue |
|---|---|---|
| Wuffs | 0.3.6 at 3bbda65f, the commit of Chrome 158 | guest/gif.c |
| libnsgif | b9e3b0aa of 2026-11-18 | .github/scripts/gif-nsgif.c |
| giflib | 5.2.2 | .github/scripts/gif-giflib.c |

Each glue returns the frames composited on a transparent canvas, so that the module is the same apart from the decoder.

Measured in run [46140881885](https://github.com/evgeny-simplex/hs-jpeg-turbo/actions/runs/46140881885), job "GIF decoders compared in the sandbox", at 91655ca, on Linux x86-64 (ubuntu-24.04), by .github/scripts/gif-compare.sh.

## Conformance

The 84 tests of the GIF test suite of pygif at 741b2820; every frame decoded at full size, compared with the expected frame, its size and its duration; a test without expected frames passes when the decode is refused.

| Decoder | Passed | Failed |
|---|---|---|
| Wuffs | 67 | 17 |
| libnsgif | 65 | 19 |
| giflib | 69 | 15 |

Tests failed by all three decoders, 14:

| Tests | Expected | Decoded |
|---|---|---|
| no-data<br>image-zero-width<br>image-zero-height<br>image-zero-size | a transparent pixel | refused |
| max-width<br>max-height | a frame of 65535 x 1 or 1 x 65535 | refused: the module refuses sides above 16384 |
| images-combine<br>images-overlap<br>high-color<br>dispose-restore-previous<br>animation-multi-image<br>animation-multi-image-explicit-zero-delay | an image without a graphic control extension combined with the images after it into one frame | each image as a frame, one without a graphic control extension of 0 ms; with Wuffs, the frame of the last image of each expected frame equal to it, with its duration (unit_gifConformance) |
| invalid-colors<br>plain-text | refused | decoded |

Tests failed by some decoders:

| Test | Wuffs | libnsgif | giflib |
|---|---|---|---|
| image-overlap-bg | canvas 3x3, enlarged to the first frame | canvas 3x3 | passed: canvas 2x2 |
| image-outside-bg | canvas 4x4, enlarged to the first frame | canvas 4x4 | passed: canvas 2x2 |
| max-codes | refused: literal width above 8 | passed | refused |
| animation-no-delays | passed | 100 ms in place of 0 ms | passed |
| gif87a-animation | passed | 100 ms in place of 0 ms | passed |
| dispose-restore-background | passed | the background colour in place of transparency | passed |

The canvas enlarged to the first frame and the refused literal width are Chrome's behaviour, since Chrome decodes GIF with this Wuffs commit.

## Code size

| Decoder | Glue lines | WebAssembly code of decoder and glue, bytes | checked.wasm, bytes | image-wasm.c, bytes | Native text of the sandbox harness, bytes |
|---|---|---|---|---|---|
| Wuffs | 187 | 26492 | 800539 | 12567646 | 1801705 |
| libnsgif | 133 | 12789 | 782690 | 12326386 | 1767993 |
| giflib | 282 | 18022 | 783433 | 12345921 | 1773721 |

## Decode time in the sandbox

Every frame at full size, median of 9 runs, ms: the session, opened and every frame read / the slowest frame. A still image is decoded when the session opens.

| Workload | Canvas | Frames | Wuffs | libnsgif | giflib |
|---|---|---|---|---|---|
| still-4320x4320.gif | 4320x4320 | 1 | 456.1 / 37.3 | 686.2 / 37.2 | 669.2 / 36.7 |
| noise-1920x1920.gif | 1920x1920 | 4 | 120.0 / 25.8 | 322.8 / 87.9 | 299.8 / 69.9 |
| noise-1920x1080.gif | 1920x1080 | 10 | 163.4 / 14.4 | 454.4 / 50.3 | 415.3 / 39.7 |
| interlaced-1920x1080.gif | 1920x1080 | 4 | 67.2 / 14.8 | 199.4 / 53.8 | 169.0 / 39.3 |
| previous-1920x1920.gif | 1920x1920 | 8 | 307.0 / 39.4 | 696.7 / 100.6 | 612.7 / 76.6 |
| two-colors-1920x1080.gif | 1920x1080 | 4 | 24.6 / 5.1 | 56.9 / 19.5 | 104.3 / 25.0 |
| clears-1024x1024.gif | 1024x1024 | 1 | 26.4 / 0.2 | 43.2 / 0.2 | 668.6 / 0.3 |
| partial-480x270.gif | 480x270 | 60 | 3.8 / 0.1 | 20.2 / 0.8 | 8.6 / 0.2 |
| dots-1024x1024.gif | 1024x1024 | 1000 | 118.5 / 0.2 | 1808.9 / 5.4 | 126.2 / 0.2 |

The workloads are made by .github/scripts/gif-workloads.py. In dots-1024x1024.gif, the libnsgif glue copies the whole canvas at each frame.

## Choice

Wuffs decodes every workload in the least time; the next fastest decoder takes 1.07 to 2.54 times as long. Wuffs shows GIFs as Chrome shows them. Its code is 13.7 KB larger in WebAssembly than libnsgif's and 33.7 KB larger in the native text of the sandbox.
