#ifndef WEBP_SANDBOX_CANVAS_H
#define WEBP_SANDBOX_CANVAS_H

#include <stddef.h>

#define WEBP_MAX_SIDE 16384

typedef struct {
  unsigned char *pixels;
  int width, height, channels;
} Canvas;

int webp_canvas_decode(const unsigned char *webp, size_t size, int max_side, Canvas *canvas);

#endif
