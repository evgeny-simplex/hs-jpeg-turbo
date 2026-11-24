#include <stdint.h>
#include <stdlib.h>
#include "canvas.h"

typedef struct {
  uint32_t status;
  uint32_t width;
  uint32_t height;
  uint32_t channels;
  uint32_t pixels;
} Output;

static Output output;

__attribute__((export_name("input"))) uint32_t guest_input(uint32_t size)
{
  return (uint32_t)(uintptr_t)malloc(size ? size : 1);
}

__attribute__((export_name("decode"))) uint32_t guest_decode(uint32_t webp, uint32_t size, int32_t max_side)
{
  Canvas canvas;

  output.status = (uint32_t)webp_canvas_decode((const unsigned char *)(uintptr_t)webp, size, max_side, &canvas);
  output.width = (uint32_t)canvas.width;
  output.height = (uint32_t)canvas.height;
  output.channels = (uint32_t)canvas.channels;
  output.pixels = (uint32_t)(uintptr_t)canvas.pixels;
  return (uint32_t)(uintptr_t)&output;
}

__attribute__((export_name("load"))) uint32_t guest_load(uint32_t address)
{
  return *(volatile const uint8_t *)(uintptr_t)address;
}

_Noreturn void __assert_fail(const char *expr, const char *file, int line, const char *func)
{
  (void)expr;
  (void)file;
  (void)line;
  (void)func;
  __builtin_trap();
}
