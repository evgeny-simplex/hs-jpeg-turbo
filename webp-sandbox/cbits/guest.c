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

typedef struct {
  uint32_t status;
  uint32_t canvas_width;
  uint32_t canvas_height;
  uint32_t frame_width;
  uint32_t frame_height;
  uint32_t channels;
} Probe;

static Output output;

static Probe probe;

static volatile uint32_t sink;

__attribute__((export_name("input"))) uint32_t guest_input(uint32_t size)
{
  return (uint32_t)(uintptr_t)malloc(size ? size : 1);
}

__attribute__((export_name("probe"))) uint32_t guest_probe(uint32_t webp, uint32_t size)
{
  Features features;

  probe.status = (uint32_t)webp_canvas_features((const unsigned char *)(uintptr_t)webp, size, &features);
  probe.canvas_width = (uint32_t)features.canvas_width;
  probe.canvas_height = (uint32_t)features.canvas_height;
  probe.frame_width = (uint32_t)features.frame_width;
  probe.frame_height = (uint32_t)features.frame_height;
  probe.channels = (uint32_t)features.channels;
  return (uint32_t)(uintptr_t)&probe;
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

__attribute__((export_name("spin"))) void guest_spin(void)
{
  for (;;)
    sink++;
}

static uint32_t tree(uint32_t depth);

static uint32_t (*volatile branch)(uint32_t) = tree;

static uint32_t tree(uint32_t depth)
{
  uint32_t left, right;

  sink++;
  if (depth == 0)
    return 1;
  left = branch(depth - 1);
  right = branch(depth - 1);
  return left - right + 1;
}

__attribute__((export_name("tree"))) uint32_t guest_tree(uint32_t depth)
{
  return branch(depth);
}

_Noreturn void __assert_fail(const char *expr, const char *file, int line, const char *func)
{
  (void)expr;
  (void)file;
  (void)line;
  (void)func;
  __builtin_trap();
}
