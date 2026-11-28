#ifndef SANDBOX_GUEST_H
#define SANDBOX_GUEST_H

#include <stddef.h>
#include <stdint.h>
#include "../cbits/sandbox.h"

#define SANDBOX_MAX_SIDE 16384

typedef struct {
  uint8_t *pixels;
  uint32_t layout;
  const uint8_t *icc;
  size_t icc_size;
  const uint8_t *exif;
  size_t exif_size;
} Image;

typedef struct {
  void *state;
  uint32_t width;
  uint32_t height;
  const char *(*next)(void *state, const uint8_t **canvas, uint32_t *duration);
  void (*rewind)(void *state);
  void (*close)(void *state);
} Animation;

const char *jpeg_header(const uint8_t *data, size_t size, uint32_t *width, uint32_t *height);

const char *jpeg_decode(const uint8_t *data, size_t size, uint32_t width, uint32_t height, uint32_t memory_mb, Image *image);

const char *png_header(const uint8_t *data, size_t size, uint32_t *width, uint32_t *height);

const char *png_decode(const uint8_t *data, size_t size, uint32_t width, uint32_t height, Image *image);

const char *webp_header(const uint8_t *data, size_t size, uint32_t *width, uint32_t *height, uint32_t *frames, uint32_t *loops);

const char *webp_decode(const uint8_t *data, size_t size, uint32_t width, uint32_t height, Image *image);

const char *webp_animation(const uint8_t *data, size_t size, Animation *animation, Image *metadata);

const char *gif_header(const uint8_t *data, size_t size, uint32_t *width, uint32_t *height, uint32_t *frames, uint32_t *loops);

const char *gif_decode(const uint8_t *data, size_t size, uint32_t width, uint32_t height, Image *image);

const char *gif_animation(const uint8_t *data, size_t size, Animation *animation);

const char *frames_still(Image *image, uint32_t width, uint32_t height);

const char *frames_animate(const uint8_t *data, size_t size, uint32_t format, uint32_t width, uint32_t height, Image *metadata);

const char *frames_next(uint32_t restart, const uint8_t **pixels, uint32_t *duration);

void frames_close(void);

const char *guest_message(const char *message);

#endif
