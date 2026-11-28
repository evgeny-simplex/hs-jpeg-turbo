#include <stdlib.h>
#include <string.h>
#include "guest.h"
#include "src/utils/rescaler_utils.h"

static struct {
  Animation animation;
  uint32_t width;
  uint32_t height;
  uint8_t *pixels;
} frames;

static const char *scale_pixels(const uint8_t *source, uint32_t source_width, uint32_t source_height, uint8_t *destination, uint32_t width,
                                uint32_t height)
{
  const int stride = (int)source_width * 4;
  rescaler_t *work = malloc((size_t)WebPRescalerWorkSize((int)source_width, (int)source_height, (int)width, (int)height, 4));
  WebPRescaler rescaler;
  int y = 0;

  if (!work || !WebPRescalerInit(&rescaler, (int)source_width, (int)source_height, destination, (int)width, (int)height, (int)width * 4, 4, work)) {
    free(work);
    return "image is too large";
  }
  while (y < (int)source_height) {
    y += WebPRescalerImport(&rescaler, (int)source_height - y, source + (size_t)y * stride, stride);
    WebPRescalerExport(&rescaler);
  }
  free(work);
  return NULL;
}

static void unpremultiply(uint8_t *pixels, size_t count)
{
  size_t i;
  int c;

  for (i = 0; i < count; i++, pixels += 4)
    for (c = 0; c < 3; c++)
      pixels[c] = pixels[3] ? (uint8_t)(pixels[c] >= pixels[3] ? 255 : (pixels[c] * 255u + pixels[3] / 2u) / pixels[3]) : 0;
}

const char *gif_decode(const uint8_t *data, size_t size, uint32_t width, uint32_t height, Image *image)
{
  Animation animation;
  const uint8_t *canvas;
  uint32_t duration;
  const char *error = gif_animation(data, size, &animation);

  if (error)
    return error;
  if (width < 1 || width > animation.width || height < 1 || height > animation.height)
    error = "invalid decode options";
  if (!error)
    error = animation.next(animation.state, &canvas, &duration);
  if (!error && !(image->pixels = malloc((size_t)width * height * 4)))
    error = "image is too large";
  if (!error && width == animation.width && height == animation.height)
    memcpy(image->pixels, canvas, (size_t)width * height * 4);
  else if (!error)
    error = scale_pixels(canvas, animation.width, animation.height, image->pixels, width, height);
  if (!error) {
    unpremultiply(image->pixels, (size_t)width * height);
    image->layout = LAYOUT_RGBA8;
  }
  animation.close(animation.state);
  return error;
}

static uint8_t multiply(uint32_t value, uint32_t alpha)
{
  return (uint8_t)((value * alpha + 127) / 255);
}

static uint8_t cmyk_channel(uint32_t ink, uint32_t key)
{
  return (uint8_t)((255 - ink) * (255 - key) / 255);
}

static void premultiply(const Image *image, size_t count, uint8_t *out)
{
  const uint8_t *p = image->pixels;
  size_t i;

  switch (image->layout) {
  case LAYOUT_Y8:
    for (i = 0; i < count; i++, p++, out += 4) {
      out[0] = out[1] = out[2] = p[0];
      out[3] = 255;
    }
    break;
  case LAYOUT_RGB8:
    for (i = 0; i < count; i++, p += 3, out += 4) {
      out[0] = p[0];
      out[1] = p[1];
      out[2] = p[2];
      out[3] = 255;
    }
    break;
  case LAYOUT_RGBA8:
    for (i = 0; i < count; i++, p += 4, out += 4) {
      out[0] = multiply(p[0], p[3]);
      out[1] = multiply(p[1], p[3]);
      out[2] = multiply(p[2], p[3]);
      out[3] = p[3];
    }
    break;
  case LAYOUT_CMYK8:
    for (i = 0; i < count; i++, p += 4, out += 4) {
      out[0] = cmyk_channel(p[0], p[3]);
      out[1] = cmyk_channel(p[1], p[3]);
      out[2] = cmyk_channel(p[2], p[3]);
      out[3] = 255;
    }
    break;
  }
}

void frames_close(void)
{
  if (frames.animation.close)
    frames.animation.close(frames.animation.state);
  free(frames.pixels);
  memset(&frames, 0, sizeof(frames));
}

const char *frames_still(Image *image, uint32_t width, uint32_t height)
{
  const size_t count = (size_t)width * height;

  memset(&frames, 0, sizeof(frames));
  frames.width = width;
  frames.height = height;
  frames.pixels = image->layout == LAYOUT_RGBA8 ? image->pixels : malloc(count * 4);
  if (!frames.pixels)
    return "image is too large";
  premultiply(image, count, frames.pixels);
  if (frames.pixels != image->pixels)
    free(image->pixels);
  image->pixels = NULL;
  return NULL;
}

const char *frames_animate(const uint8_t *data, size_t size, uint32_t format, uint32_t width, uint32_t height, Image *metadata)
{
  const char *error;

  memset(&frames, 0, sizeof(frames));
  error = format == FORMAT_WEBP  ? webp_animation(data, size, &frames.animation, metadata)
          : format == FORMAT_GIF ? gif_animation(data, size, &frames.animation)
                                 : "invalid decode options";
  frames.width = width;
  frames.height = height;
  if (!error && (width != frames.animation.width || height != frames.animation.height) && !(frames.pixels = malloc((size_t)width * height * 4))) {
    frames_close();
    error = "image is too large";
  }
  return error;
}

const char *frames_next(uint32_t restart, const uint8_t **pixels, uint32_t *duration)
{
  const uint8_t *canvas;
  const char *error;

  *pixels = frames.pixels;
  *duration = 0;
  if (!frames.animation.next)
    return NULL;
  if (restart)
    frames.animation.rewind(frames.animation.state);
  if ((error = frames.animation.next(frames.animation.state, &canvas, duration)))
    return error;
  if (!frames.pixels) {
    *pixels = canvas;
    return NULL;
  }
  return scale_pixels(canvas, frames.animation.width, frames.animation.height, frames.pixels, frames.width, frames.height);
}
