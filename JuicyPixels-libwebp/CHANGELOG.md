# Changelog for `JuicyPixels-libwebp`

## Unreleased

- WebP decoding of JuicyPixels images with libwebp f054d0c3: still images, the first frame of animations and alpha; the payloads of the ICCP and EXIF chunks.
- decodeWebp refuses a canvas with a side above 16384 pixels or with pixels above maxMemoryMB, before allocating it; each allocation of libwebp is limited to 512 MiB.

## 0.1.0.0 - YYYY-MM-DD
