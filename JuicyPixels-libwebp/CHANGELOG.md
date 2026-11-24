# Changelog for `JuicyPixels-libwebp`

## Unreleased

- WebP decoding of JuicyPixels images with libwebp 1.6.0: still images, the first frame of animations and alpha; the payloads of the ICCP and EXIF chunks.
- The image is decoded at the size that outputSize returns for the canvas size, scaled by libwebp in the same pass.
- decodeWebp refuses a canvas with a side above 16384 pixels, and a frame whose libwebp buffers and output image exceed maxMemoryMB, before allocating them; each allocation of libwebp is limited to 64 MiB.

## 0.1.0.0 - YYYY-MM-DD
