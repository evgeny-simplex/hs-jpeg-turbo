#include <string.h>
#include "canvas.h"
#include "sandbox.h"

int webp_native_decode(const uint8_t *webp, size_t size, int max_side, webp_result *result)
{
  Canvas canvas;
  int status = webp_canvas_decode(webp, size, max_side, &canvas);

  memset(result, 0, sizeof(*result));
  if (status == 0) {
    result->pixels = canvas.pixels;
    result->width = (uint32_t)canvas.width;
    result->height = (uint32_t)canvas.height;
    result->channels = (uint32_t)canvas.channels;
  }
  return status;
}
