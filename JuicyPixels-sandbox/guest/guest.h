#ifndef SANDBOX_GUEST_H
#define SANDBOX_GUEST_H

#include <stddef.h>
#include <stdint.h>

#define SANDBOX_MAX_SIDE 16384

enum { FORMAT_JPEG = 1, FORMAT_PNG = 2, FORMAT_WEBP = 3 };

enum { LAYOUT_Y8 = 1, LAYOUT_RGB8 = 2, LAYOUT_RGBA8 = 3, LAYOUT_CMYK8 = 4 };

typedef struct {
  uint8_t *pixels;
  uint32_t layout;
  const uint8_t *icc;
  size_t icc_size;
  const uint8_t *exif;
  size_t exif_size;
} Image;

const char *jpeg_header(const uint8_t *data, size_t size, uint32_t *width, uint32_t *height);

const char *jpeg_decode(const uint8_t *data, size_t size, uint32_t width, uint32_t height, uint32_t memory_mb, Image *image);

const char *png_header(const uint8_t *data, size_t size, uint32_t *width, uint32_t *height);

const char *png_decode(const uint8_t *data, size_t size, uint32_t width, uint32_t height, Image *image);

const char *webp_header(const uint8_t *data, size_t size, uint32_t *width, uint32_t *height);

const char *webp_decode(const uint8_t *data, size_t size, uint32_t width, uint32_t height, Image *image);

const char *guest_message(const char *message);

#endif
