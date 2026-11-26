#ifndef WEBP_SANDBOX_H
#define WEBP_SANDBOX_H

#include <stddef.h>
#include <stdint.h>

#define WEBP_SANDBOX_TRAP (-1)
#define WEBP_SANDBOX_INVALID_OUTPUT (-2)
#define WEBP_SANDBOX_OUT_OF_MEMORY (-3)
#define WEBP_SANDBOX_INVALID_ARGUMENT (-4)
#define WEBP_SANDBOX_BUDGET (-5)
#define WEBP_SANDBOX_DEADLINE (-6)

#define WEBP_SANDBOX_MAX_INTERVAL (1u << 30)

typedef struct {
  uint64_t memory_limit;
  uint64_t budget_base;
  uint64_t budget_per_byte;
  uint64_t budget_per_pixel;
  uint64_t deadline_ns;
  uint32_t check_interval;
} webp_limits;

typedef struct {
  uint8_t *pixels;
  uint32_t width;
  uint32_t height;
  uint32_t channels;
  uint32_t trap;
  uint64_t memory_bytes;
  uint64_t iterations;
  uint64_t stopped_ns;
  uint32_t refuels;
  uint32_t frame_width;
  uint32_t frame_height;
} webp_result;

uint64_t webp_sandbox_now_ns(void);

int webp_native_decode(const uint8_t *webp, size_t size, int max_side, webp_result *result);

int webp_sandbox_decode(const uint8_t *webp, size_t size, int max_side, const webp_limits *limits, webp_result *result);

int webp_sandbox_load(uint32_t address, const webp_limits *limits, uint32_t *value, webp_result *result);

int webp_sandbox_spin(const webp_limits *limits, webp_result *result);

int webp_sandbox_tree(uint32_t depth, const webp_limits *limits, uint32_t *value, webp_result *result);

#endif
