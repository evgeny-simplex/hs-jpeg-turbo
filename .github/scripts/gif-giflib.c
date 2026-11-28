#include <stdlib.h>
#include <string.h>
#include "guest.h"
#include "giflib/dgif_lib.c"
#include "giflib/gif_err.c"
#include "giflib/gifalloc.c"
#include "giflib/openbsd-reallocarray.c"

typedef struct {
  const uint8_t *data;
  size_t size;
  size_t position;
} Input;

typedef struct {
  GifFileType *file;
  Input input;
  uint8_t *canvas;
  uint8_t *previous;
  uint8_t *line;
  uint32_t width;
  uint32_t height;
  uint32_t frames;
  uint32_t index;
  uint32_t x0, y0, x1, y1;
  int disposal;
} Gif;

static int read_input(GifFileType *file, GifByteType *bytes, int length)
{
  Input *input = file->UserData;
  const size_t left = input->size - input->position, n = left < (size_t)length ? left : (size_t)length;

  memcpy(bytes, input->data + input->position, n);
  input->position += n;
  return (int)n;
}

static const char *reopen(Gif *gif)
{
  int error;

  if (gif->file)
    DGifCloseFile(gif->file, &error);
  gif->input.position = 0;
  if (!(gif->file = DGifOpen(&gif->input, read_input, &error)))
    return GifErrorString(error);
  return NULL;
}

static int skip_blocks(GifFileType *file, GifByteType *block, int (*next)(GifFileType *, GifByteType **))
{
  while (block)
    if (next(file, &block) == GIF_ERROR)
      return GIF_ERROR;
  return GIF_OK;
}

static uint32_t scan(Gif *gif, uint32_t *loops)
{
  GifRecordType record;
  GifByteType *block;
  int code;

  *loops = 1;
  while (DGifGetRecordType(gif->file, &record) == GIF_OK && record != TERMINATE_RECORD_TYPE) {
    if (record == IMAGE_DESC_RECORD_TYPE) {
      if (DGifGetImageDesc(gif->file) == GIF_ERROR || DGifGetCode(gif->file, &code, &block) == GIF_ERROR ||
          skip_blocks(gif->file, block, DGifGetCodeNext) == GIF_ERROR)
        break;
      gif->frames++;
    } else if (record == EXTENSION_RECORD_TYPE) {
      if (DGifGetExtension(gif->file, &code, &block) == GIF_ERROR)
        break;
      if (code == APPLICATION_EXT_FUNC_CODE && block && block[0] == 11 && !memcmp(block + 1, "NETSCAPE2.0", 11)) {
        if (DGifGetExtensionNext(gif->file, &block) == GIF_ERROR)
          break;
        if (block && block[0] >= 3 && block[1] == 1)
          *loops = (uint32_t)(block[2] | block[3] << 8) ? (uint32_t)(block[2] | block[3] << 8) + 1 : 0;
      }
      if (skip_blocks(gif->file, block, DGifGetExtensionNext) == GIF_ERROR)
        break;
    }
  }
  return gif->frames;
}

static const char *open_gif(const uint8_t *data, size_t size, Gif **result, uint32_t *loops)
{
  Gif *gif = calloc(1, sizeof(*gif));
  const char *error;

  *result = gif;
  if (!gif)
    return "image is too large";
  gif->input.data = data;
  gif->input.size = size;
  if ((error = reopen(gif)))
    return error;
  gif->width = (uint32_t)gif->file->SWidth;
  gif->height = (uint32_t)gif->file->SHeight;
  if (gif->width == 0 || gif->height == 0)
    return "no image in GIF";
  if (gif->width > SANDBOX_MAX_SIDE || gif->height > SANDBOX_MAX_SIDE)
    return "image side exceeds 16384";
  if (scan(gif, loops) == 0)
    return GifErrorString(gif->file->Error ? gif->file->Error : D_GIF_ERR_NO_IMAG_DSCR);
  if (gif->frames == 1)
    *loops = 1;
  return reopen(gif);
}

static void close_gif(void *state)
{
  Gif *gif = state;
  int ignored;

  if (gif) {
    if (gif->file)
      DGifCloseFile(gif->file, &ignored);
    free(gif->canvas);
    free(gif->previous);
    free(gif->line);
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

static void copy_rect(const Gif *gif, uint8_t *destination, const uint8_t *source)
{
  const size_t stride = (size_t)gif->width * 4;
  uint32_t y;

  for (y = gif->y0; y < gif->y1; y++)
    memcpy(destination + y * stride + gif->x0 * 4, source + y * stride + gif->x0 * 4, (size_t)(gif->x1 - gif->x0) * 4);
}

static void clear_rect(const Gif *gif)
{
  const size_t stride = (size_t)gif->width * 4;
  uint32_t y;

  for (y = gif->y0; y < gif->y1; y++)
    memset(gif->canvas + y * stride + gif->x0 * 4, 0, (size_t)(gif->x1 - gif->x0) * 4);
}

static void rewind_frames(void *state)
{
  Gif *gif = state;

  reopen(gif);
  memset(gif->canvas, 0, (size_t)gif->width * gif->height * 4);
  gif->index = 0;
  gif->disposal = DISPOSAL_UNSPECIFIED;
}

static uint32_t interlaced_row(uint32_t row, uint32_t height)
{
  static const uint32_t starts[] = {0, 4, 2, 1}, steps[] = {8, 8, 4, 2};
  uint32_t pass, rows;

  for (pass = 0; pass < 4; pass++) {
    rows = height > starts[pass] ? (height - starts[pass] + steps[pass] - 1) / steps[pass] : 0;
    if (row < rows)
      return starts[pass] + row * steps[pass];
    row -= rows;
  }
  return 0;
}

static uint32_t clip(int value, uint32_t limit)
{
  return value < 0 ? 0 : (uint32_t)value > limit ? limit : (uint32_t)value;
}

static const char *next_frame(void *state, const uint8_t **canvas, uint32_t *duration)
{
  Gif *gif = state;
  GraphicsControlBlock control = {DISPOSAL_UNSPECIFIED, false, 0, NO_TRANSPARENT_COLOR};
  const ColorMapObject *colors;
  const GifImageDesc *image;
  GifRecordType record;
  GifByteType *block;
  uint32_t row, x, y;
  int code;

  if (gif->index == gif->frames)
    rewind_frames(gif);
  if (gif->disposal == DISPOSE_BACKGROUND)
    clear_rect(gif);
  else if (gif->disposal == DISPOSE_PREVIOUS)
    copy_rect(gif, gif->canvas, gif->previous);
  for (;;) {
    if (DGifGetRecordType(gif->file, &record) == GIF_ERROR)
      return GifErrorString(gif->file->Error);
    if (record == IMAGE_DESC_RECORD_TYPE)
      break;
    if (record != EXTENSION_RECORD_TYPE)
      return GifErrorString(D_GIF_ERR_NO_IMAG_DSCR);
    if (DGifGetExtension(gif->file, &code, &block) == GIF_ERROR)
      return GifErrorString(gif->file->Error);
    if (code == GRAPHICS_EXT_FUNC_CODE && block)
      DGifExtensionToGCB(block[0], block + 1, &control);
    if (skip_blocks(gif->file, block, DGifGetExtensionNext) == GIF_ERROR)
      return GifErrorString(gif->file->Error);
  }
  if (DGifGetImageDesc(gif->file) == GIF_ERROR)
    return GifErrorString(gif->file->Error);
  image = &gif->file->Image;
  colors = image->ColorMap ? image->ColorMap : gif->file->SColorMap;
  gif->x0 = clip(image->Left, gif->width);
  gif->y0 = clip(image->Top, gif->height);
  gif->x1 = clip(image->Left + image->Width, gif->width);
  gif->y1 = clip(image->Top + image->Height, gif->height);
  gif->disposal = control.DisposalMode;
  if (gif->disposal == DISPOSE_PREVIOUS) {
    if (!gif->previous && !(gif->previous = malloc((size_t)gif->width * gif->height * 4)))
      return "image is too large";
    copy_rect(gif, gif->previous, gif->canvas);
  }
  if (!(gif->line = realloc(gif->line, image->Width > 0 ? (size_t)image->Width : 1)))
    return "image is too large";
  for (row = 0; row < (uint32_t)image->Height; row++) {
    if (DGifGetLine(gif->file, gif->line, image->Width) == GIF_ERROR)
      return GifErrorString(gif->file->Error);
    y = (uint32_t)image->Top + (image->Interlace ? interlaced_row(row, (uint32_t)image->Height) : row);
    for (x = 0; y < gif->height && x < (uint32_t)image->Width; x++) {
      const uint32_t column = (uint32_t)image->Left + x;
      const int index = gif->line[x];
      uint8_t *pixel = gif->canvas + ((size_t)y * gif->width + column) * 4;

      if (column >= gif->width || index == control.TransparentColor)
        continue;
      if (colors && index < colors->ColorCount) {
        pixel[0] = colors->Colors[index].Red;
        pixel[1] = colors->Colors[index].Green;
        pixel[2] = colors->Colors[index].Blue;
      } else {
        pixel[0] = pixel[1] = pixel[2] = 0;
      }
      pixel[3] = 255;
    }
  }
  gif->index++;
  *duration = (uint32_t)control.DelayTime * 10;
  *canvas = gif->canvas;
  return NULL;
}

const char *gif_animation(const uint8_t *data, size_t size, Animation *animation)
{
  uint32_t loops;
  Gif *gif;
  const char *error = open_gif(data, size, &gif, &loops);

  if (!error && !(gif->canvas = calloc((size_t)gif->width * gif->height, 4)))
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
