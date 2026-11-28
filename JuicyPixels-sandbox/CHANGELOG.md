# Changelog for `JuicyPixels-sandbox`

## Unreleased

- JPEG, PNG and WebP decoding of JuicyPixels images in a WebAssembly sandbox: the decoders of libjpeg-turbo (bundled mozjpeg 08265790, libjpeg-turbo 3.0.5), libspng 0.7.4 with miniz and the one-pass scaler of JuicyPixels-spng, and libwebp 68dd1c30, compiled by wasi-sdk 34 into one module and translated to C by wasm2c 1.0.42; the C is generated in CI and committed.
- Each decode runs in a new instance: every memory access is bounds-checked; the linear memory is limited by memoryLimitMB; on 32-bit targets, it is allocated at the module's initial size and grown as the decode needs it; on 64-bit targets, address space is reserved at the limit and pages are committed as the decode needs them; an iteration budget of 1 Mi, 16 per input byte and a rate per format per image and output pixel (JPEG 256, PNG and WebP 64) is checked at loop headers, function entries and bulk memory operations; the deadline of timeoutMs is read from the monotonic clock every checkInterval iterations.
- The host copies the pixels out only when their size equals the requested one and their layout is valid for the format; a trap, the memory limit, the budget or the deadline returns an error.
- Outputs of 2^30 pixels or more are refused with "image is too large".
- Memory limits above PTRDIFF_MAX bytes, 2048 MiB or more on 32-bit targets, are refused with "invalid argument".
- The C is compiled at -O3 for Android and Apple aarch64 and at -O2 elsewhere: with the clang of the Android aarch64 build, WebP decodes at 4.2 times the native time at -O2 and 1.8 to 1.9 at -O3.

## 0.1.0.0 - YYYY-MM-DD
