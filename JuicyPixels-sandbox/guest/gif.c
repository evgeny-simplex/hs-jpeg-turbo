#include <stdlib.h>
#include <string.h>
#include "guest.h"

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__STATIC_FUNCTIONS
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__GIF
#define WUFFS_CONFIG__MODULE__LZW
#include "wuffs/release/c/wuffs-v0.3.c"

typedef struct {
  wuffs_gif__decoder decoder;
  wuffs_base__io_buffer source;
  wuffs_base__pixel_buffer buffer;
  const uint8_t *data;
  size_t size;
  uint8_t *canvas;
  uint8_t *previous;
  uint32_t width;
  uint32_t height;
  uint64_t frames;
  uint64_t index;
  wuffs_base__rect_ie_u32 shown;
  wuffs_base__animation_disposal disposal;
} Gif;

static const char *reset(Gif *gif, wuffs_base__image_config *image)
{
  wuffs_base__status status;

  memset(&gif->decoder, 0, sizeof(gif->decoder));
  status = wuffs_gif__decoder__initialize(&gif->decoder, sizeof(gif->decoder), WUFFS_VERSION, WUFFS_INITIALIZE__ALREADY_ZEROED);
  if (status.repr)
    return wuffs_base__status__message(&status);
  wuffs_gif__decoder__set_quirk_enabled(&gif->decoder, WUFFS_GIF__QUIRK_IGNORE_TOO_MUCH_PIXEL_DATA, true);
  gif->source = wuffs_base__ptr_u8__reader((uint8_t *)gif->data, gif->size, true);
  status = wuffs_gif__decoder__decode_image_config(&gif->decoder, image, &gif->source);
  if (wuffs_base__status__is_error(&status))
    return wuffs_base__status__message(&status);
  return status.repr ? "no image in GIF" : NULL;
}

static const char *open_gif(const uint8_t *data, size_t size, Gif **result, uint32_t *loops)
{
  wuffs_base__image_config image;
  wuffs_base__frame_config frame;
  wuffs_base__status status;
  Gif *gif = calloc(1, sizeof(*gif));
  const char *error;

  *result = gif;
  if (!gif)
    return "image is too large";
  gif->data = data;
  gif->size = size;
  if ((error = reset(gif, &image)))
    return error;
  gif->width = wuffs_base__pixel_config__width(&image.pixcfg);
  gif->height = wuffs_base__pixel_config__height(&image.pixcfg);
  if (gif->width == 0 || gif->height == 0)
    return "no image in GIF";
  if (gif->width > SANDBOX_MAX_SIDE || gif->height > SANDBOX_MAX_SIDE)
    return "image side exceeds 16384";
  while (!(status = wuffs_gif__decoder__decode_frame_config(&gif->decoder, &frame, &gif->source)).repr)
    gif->frames++;
  if (gif->frames == 0)
    return wuffs_base__status__is_error(&status) ? wuffs_base__status__message(&status) : "no image in GIF";
  *loops = gif->frames > 1 ? wuffs_gif__decoder__num_animation_loops(&gif->decoder) : 1;
  return reset(gif, &image);
}

const char *gif_header(const uint8_t *data, size_t size, uint32_t *width, uint32_t *height, uint32_t *frames, uint32_t *loops)
{
  Gif *gif;
  const char *error = open_gif(data, size, &gif, loops);

  if (!error) {
    *width = gif->width;
    *height = gif->height;
    *frames = (uint32_t)gif->frames;
  }
  free(gif);
  return error;
}

static void copy_shown(const Gif *gif, uint8_t *destination, const uint8_t *source)
{
  const size_t stride = (size_t)gif->width * 4, length = (size_t)wuffs_base__rect_ie_u32__width(&gif->shown) * 4;
  size_t offset = (size_t)gif->shown.min_incl_y * stride + (size_t)gif->shown.min_incl_x * 4;
  uint32_t y;

  for (y = gif->shown.min_incl_y; y < gif->shown.max_excl_y; y++, offset += stride)
    memcpy(destination + offset, source + offset, length);
}

static void clear_shown(const Gif *gif)
{
  const size_t stride = (size_t)gif->width * 4, length = (size_t)wuffs_base__rect_ie_u32__width(&gif->shown) * 4;
  size_t offset = (size_t)gif->shown.min_incl_y * stride + (size_t)gif->shown.min_incl_x * 4;
  uint32_t y;

  for (y = gif->shown.min_incl_y; y < gif->shown.max_excl_y; y++, offset += stride)
    memset(gif->canvas + offset, 0, length);
}

static void rewind_frames(void *state)
{
  Gif *gif = state;
  wuffs_base__image_config image;

  reset(gif, &image);
  memset(gif->canvas, 0, (size_t)gif->width * gif->height * 4);
  gif->index = 0;
  gif->disposal = WUFFS_BASE__ANIMATION_DISPOSAL__NONE;
}

static const char *next_frame(void *state, const uint8_t **canvas, uint32_t *duration)
{
  Gif *gif = state;
  wuffs_base__frame_config frame;
  wuffs_base__status status;

  if (gif->index == gif->frames)
    rewind_frames(gif);
  if (gif->disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_BACKGROUND)
    clear_shown(gif);
  else if (gif->disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_PREVIOUS)
    copy_shown(gif, gif->canvas, gif->previous);
  status = wuffs_gif__decoder__decode_frame_config(&gif->decoder, &frame, &gif->source);
  if (status.repr)
    return wuffs_base__status__message(&status);
  gif->shown = wuffs_base__frame_config__bounds(&frame);
  gif->disposal = wuffs_base__frame_config__disposal(&frame);
  if (gif->disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_PREVIOUS) {
    if (!gif->previous && !(gif->previous = malloc((size_t)gif->width * gif->height * 4)))
      return "image is too large";
    copy_shown(gif, gif->previous, gif->canvas);
  }
  status = wuffs_gif__decoder__decode_frame(&gif->decoder, &gif->buffer, &gif->source, WUFFS_BASE__PIXEL_BLEND__SRC_OVER, wuffs_base__empty_slice_u8(), NULL);
  if (wuffs_base__status__is_error(&status))
    return wuffs_base__status__message(&status);
  gif->index++;
  *duration = (uint32_t)((uint64_t)wuffs_base__frame_config__duration(&frame) / WUFFS_BASE__FLICKS_PER_MILLISECOND);
  *canvas = gif->canvas;
  return NULL;
}

static void close_gif(void *state)
{
  Gif *gif = state;

  if (gif) {
    free(gif->canvas);
    free(gif->previous);
  }
  free(gif);
}

const char *gif_animation(const uint8_t *data, size_t size, Animation *animation)
{
  wuffs_base__pixel_config config;
  wuffs_base__status status;
  uint32_t loops;
  Gif *gif;
  const char *error = open_gif(data, size, &gif, &loops);

  if (!error && !(gif->canvas = calloc((size_t)gif->width * gif->height, 4)))
    error = "image is too large";
  if (!error) {
    wuffs_base__pixel_config__set(&config, WUFFS_BASE__PIXEL_FORMAT__RGBA_PREMUL, WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, gif->width, gif->height);
    status = wuffs_base__pixel_buffer__set_from_slice(&gif->buffer, &config, wuffs_base__make_slice_u8(gif->canvas, (size_t)gif->width * gif->height * 4));
    error = wuffs_base__status__message(&status);
  }
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
