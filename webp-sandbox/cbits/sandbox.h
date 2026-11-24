#ifndef WEBP_SANDBOX_H
#define WEBP_SANDBOX_H

#include <stddef.h>
#include <stdint.h>

#define WEBP_SANDBOX_TRAP (-1)
#define WEBP_SANDBOX_INVALID_OUTPUT (-2)
#define WEBP_SANDBOX_OUT_OF_MEMORY (-3)
#define WEBP_SANDBOX_INVALID_ARGUMENT (-4)

typedef struct {
  uint8_t *pixels;
  uint32_t width;
  uint32_t height;
  uint32_t channels;
  uint32_t trap;
  uint64_t memory_bytes;
} webp_result;

int webp_native_decode(const uint8_t *webp, size_t size, int max_side, webp_result *result);

int webp_sandbox_decode(const uint8_t *webp, size_t size, int max_side, uint64_t memory_limit, webp_result *result);

int webp_sandbox_load(uint32_t address, uint64_t memory_limit, uint32_t *value, webp_result *result);

#endif
