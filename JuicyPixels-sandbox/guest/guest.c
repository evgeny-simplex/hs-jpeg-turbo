#include <stdlib.h>
#include <string.h>
#include "guest.h"

typedef struct {
  uint32_t message;
  uint32_t format;
  uint32_t width;
  uint32_t height;
  uint32_t frames;
  uint32_t loops;
} Header;

typedef struct {
  uint32_t message;
  uint32_t width;
  uint32_t height;
  uint32_t layout;
  uint32_t pixels;
  uint32_t icc;
  uint32_t icc_size;
  uint32_t exif;
  uint32_t exif_size;
} Output;

typedef struct {
  uint32_t message;
  uint32_t alpha;
  uint32_t icc;
  uint32_t icc_size;
  uint32_t exif;
  uint32_t exif_size;
} Start;

typedef struct {
  uint32_t message;
  uint32_t width;
  uint32_t height;
  uint32_t pixels;
  uint32_t duration;
} Frame;

static Header header;

static Output output;

static Start start;

static Frame frame;

static char message[256];

static volatile uint32_t sink;

#define ADDRESS(p) ((uint32_t)(uintptr_t)(p))

const char *guest_message(const char *text)
{
  strncpy(message, text, sizeof(message) - 1);
  return message;
}

static uint32_t image_format(const uint8_t *data, size_t size)
{
  if (size >= 2 && !memcmp(data, "\xFF\xD8", 2))
    return FORMAT_JPEG;
  if (size >= 8 && !memcmp(data, "\x89PNG\r\n\x1a\n", 8))
    return FORMAT_PNG;
  if (size >= 12 && !memcmp(data, "RIFF", 4) && !memcmp(data + 8, "WEBP", 4))
    return FORMAT_WEBP;
  if (size >= 6 && (!memcmp(data, "GIF87a", 6) || !memcmp(data, "GIF89a", 6)))
    return FORMAT_GIF;
  return 0;
}

__attribute__((export_name("input"))) uint32_t guest_input(uint32_t size)
{
  return ADDRESS(malloc(size ? size : 1));
}

__attribute__((export_name("probe"))) uint32_t guest_probe(uint32_t data, uint32_t size)
{
  const uint8_t *bytes = (const uint8_t *)(uintptr_t)data;
  const char *error;

  header.format = image_format(bytes, size);
  header.width = header.height = 0;
  header.frames = header.loops = 1;
  switch (header.format) {
  case FORMAT_JPEG:
    error = jpeg_header(bytes, size, &header.width, &header.height);
    break;
  case FORMAT_PNG:
    error = png_header(bytes, size, &header.width, &header.height);
    break;
  case FORMAT_WEBP:
    error = webp_header(bytes, size, &header.width, &header.height, &header.frames, &header.loops);
    break;
  case FORMAT_GIF:
    error = gif_header(bytes, size, &header.width, &header.height, &header.frames, &header.loops);
    break;
  default:
    error = "unsupported image format";
  }
  header.message = ADDRESS(error);
  return ADDRESS(&header);
}

static const char *decode_image(const uint8_t *bytes, size_t size, uint32_t width, uint32_t height, uint32_t memory_mb, Image *image)
{
  switch (image_format(bytes, size)) {
  case FORMAT_JPEG:
    return jpeg_decode(bytes, size, width, height, memory_mb, image);
  case FORMAT_PNG:
    return png_decode(bytes, size, width, height, image);
  case FORMAT_WEBP:
    return webp_decode(bytes, size, width, height, image);
  case FORMAT_GIF:
    return gif_decode(bytes, size, width, height, image);
  default:
    return "unsupported image format";
  }
}

__attribute__((export_name("decode"))) uint32_t guest_decode(uint32_t data, uint32_t size, uint32_t width, uint32_t height, uint32_t memory_mb)
{
  Image image = {0};
  const char *error = decode_image((const uint8_t *)(uintptr_t)data, size, width, height, memory_mb, &image);

  output.message = ADDRESS(error);
  output.width = width;
  output.height = height;
  output.layout = image.layout;
  output.pixels = ADDRESS(image.pixels);
  output.icc = ADDRESS(image.icc);
  output.icc_size = (uint32_t)image.icc_size;
  output.exif = ADDRESS(image.exif);
  output.exif_size = (uint32_t)image.exif_size;
  return ADDRESS(&output);
}

__attribute__((export_name("start"))) uint32_t guest_start(uint32_t data, uint32_t size, uint32_t width, uint32_t height, uint32_t memory_mb,
                                                           uint32_t playback)
{
  const uint8_t *bytes = (const uint8_t *)(uintptr_t)data;
  Image image = {0};
  const char *error;

  if (playback == PLAYBACK_STILL) {
    error = decode_image(bytes, size, width, height, memory_mb, &image);
    if (!error)
      error = frames_still(&image, width, height);
  } else {
    error = frames_animate(bytes, size, image_format(bytes, size), width, height, &image);
  }
  start.message = ADDRESS(error);
  start.alpha = playback == PLAYBACK_ANIMATION || image.layout == LAYOUT_RGBA8;
  start.icc = ADDRESS(image.icc);
  start.icc_size = (uint32_t)image.icc_size;
  start.exif = ADDRESS(image.exif);
  start.exif_size = (uint32_t)image.exif_size;
  frame.width = width;
  frame.height = height;
  return ADDRESS(&start);
}

__attribute__((export_name("next"))) uint32_t guest_next(uint32_t restart)
{
  const uint8_t *pixels;

  frame.message = ADDRESS(frames_next(restart, &pixels, &frame.duration));
  frame.pixels = ADDRESS(pixels);
  return ADDRESS(&frame);
}

__attribute__((export_name("error"))) uint32_t guest_error(void)
{
  return ADDRESS(message);
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
