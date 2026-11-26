# Changelog for `JuicyPixels-sandbox`

## Unreleased

- JPEG, PNG and WebP decoding of JuicyPixels images in a WebAssembly sandbox: the decoders of libjpeg-turbo (bundled mozjpeg 08265790, libjpeg-turbo 3.0.5), libspng 0.7.4 with miniz and the one-pass scaler of JuicyPixels-spng, and libwebp 68dd1c30, compiled by wasi-sdk 34 into one module and translated to C by wasm2c 1.0.42; the C is generated in CI and committed.
- Each decode runs in a new instance: every memory access is bounds-checked; the linear memory is limited by memoryLimitMB; an iteration budget from the input bytes and the pixels is checked at loop headers, function entries and bulk memory operations; the deadline of timeoutMs is read from the monotonic clock every checkInterval iterations.
- The host copies the pixels out only when their size and layout equal the requested ones; a trap, the memory limit, the budget or the deadline returns an error.

## 0.1.0.0 - YYYY-MM-DD
