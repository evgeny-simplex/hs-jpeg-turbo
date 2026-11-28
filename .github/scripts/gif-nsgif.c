#include <stdlib.h>
#include <string.h>
#include "guest.h"
#include "nsgif/gif.c"
#include "nsgif/lzw.c"

typedef struct {
  nsgif_t *gif;
  uint8_t *canvas;
  uint32_t width;
  uint32_t height;
  uint32_t frames;
  uint32_t index;
} Gif;

static nsgif_bitmap_t *create_bitmap(int width, int height)
{
  return calloc((size_t)width * (size_t)height, 4);
}

static void destroy_bitmap(nsgif_bitmap_t *bitmap)
{
  free(bitmap);
}

static uint8_t *bitmap_buffer(nsgif_bitmap_t *bitmap)
{
  return bitmap;
}

static const nsgif_bitmap_cb_vt bitmaps = {create_bitmap, destroy_bitmap, bitmap_buffer, NULL, NULL, NULL, NULL};

static const char *open_gif(const uint8_t *data, size_t size, Gif **result, uint32_t *loops)
{
  const nsgif_info_t *info;
  nsgif_error error;
  Gif *gif = calloc(1, sizeof(*gif));

  *result = gif;
  if (!gif)
    return "image is too large";
  if ((error = nsgif_create(&bitmaps, NSGIF_BITMAP_FMT_R8G8B8A8, &gif->gif)) != NSGIF_OK)
    return nsgif_strerror(error);
  error = nsgif_data_scan(gif->gif, size, data);
  nsgif_data_complete(gif->gif);
  info = nsgif_get_info(gif->gif);
  if (info->frame_count == 0)
    return error != NSGIF_OK ? nsgif_strerror(error) : "no image in GIF";
  gif->width = info->width;
  gif->height = info->height;
  gif->frames = info->frame_count;
  if (gif->width == 0 || gif->height == 0)
    return "no image in GIF";
  if (gif->width > SANDBOX_MAX_SIDE || gif->height > SANDBOX_MAX_SIDE)
    return "image side exceeds 16384";
  *loops = gif->frames > 1 ? (uint32_t)info->loop_max : 1;
  return NULL;
}

static void close_gif(void *state)
{
  Gif *gif = state;

  if (gif) {
    nsgif_destroy(gif->gif);
    free(gif->canvas);
  }
  free(gif);
}

const char *gif_header(const uint8_t *data, size_t size, uint32_t *width, uint32_t *height, uint32_t *frames, uint32_t *loops)
{
  Gif *gif;
  const char *error = open_gif(data, size, &gif, loops);

  if (!error) {
    *width = gif->width;
    *height = gif->height;
    *frames = gif->frames;
  }
  close_gif(gif);
  return error;
}

static void rewind_frames(void *state)
{
  ((Gif *)state)->index = 0;
}

static const char *next_frame(void *state, const uint8_t **canvas, uint32_t *duration)
{
  Gif *gif = state;
  nsgif_bitmap_t *bitmap;
  const uint8_t *pixels;
  nsgif_error error;
  size_t i;

  if (gif->index == gif->frames)
    rewind_frames(gif);
  if ((error = nsgif_frame_decode(gif->gif, gif->index, &bitmap)) != NSGIF_OK)
    return nsgif_strerror(error);
  pixels = bitmap;
  for (i = 0; i < (size_t)gif->width * gif->height * 4; i += 4)
    if (pixels[i + 3])
      memcpy(gif->canvas + i, pixels + i, 4);
    else
      memset(gif->canvas + i, 0, 4);
  *duration = nsgif_get_frame_info(gif->gif, gif->index)->delay * 10;
  gif->index++;
  *canvas = gif->canvas;
  return NULL;
}

const char *gif_animation(const uint8_t *data, size_t size, Animation *animation)
{
  uint32_t loops;
  Gif *gif;
  const char *error = open_gif(data, size, &gif, &loops);

  if (!error && !(gif->canvas = malloc((size_t)gif->width * gif->height * 4)))
    error = "image is too large";
  if (error) {
    close_gif(gif);
    return error;
  }
  animation->state = gif;
  animation->width = gif->width;
  animation->height = gif->height;
  animation->next = next_frame;
  animation->rewind = rewind_frames;
  animation->close = close_gif;
  return NULL;
}
