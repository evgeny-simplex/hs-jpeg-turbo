#include <stdlib.h>
#include "guest.h"
#include "turbojpeg.h"

static tjhandle current;

_Noreturn void guest_longjmp(void)
{
  guest_message(current ? tj3GetErrorStr(current) : "JPEG error");
  __builtin_trap();
}

static tjhandle open_decompressor(void)
{
  return current = tjInitDecompress();
}

static const char *read_header(tjhandle tj, const uint8_t *data, size_t size, int *width, int *height, int *colorspace)
{
  if (tj3Set(tj, TJPARAM_STOPONWARNING, 1) || tj3DecompressHeader(tj, data, size))
    return guest_message(tj3GetErrorStr(tj));
  *width = tj3Get(tj, TJPARAM_JPEGWIDTH);
  *height = tj3Get(tj, TJPARAM_JPEGHEIGHT);
  *colorspace = tj3Get(tj, TJPARAM_COLORSPACE);
  if (*width < 1 || *height < 1)
    return "no image in JPEG";
  if (tj3Get(tj, TJPARAM_PRECISION) != 8)
    return "unsupported data precision";
  if (tj3Get(tj, TJPARAM_LOSSLESS) != 0)
    return "unsupported lossless JPEG";
  return NULL;
}

const char *jpeg_header(const uint8_t *data, size_t size, uint32_t *width, uint32_t *height)
{
  tjhandle tj = open_decompressor();
  int w, h, colorspace;
  const char *error;

  if (!tj)
    return "out of memory";
  error = read_header(tj, data, size, &w, &h, &colorspace);
  *width = (uint32_t)w;
  *height = (uint32_t)h;
  tjDestroy(tj);
  return error;
}

static int scaled_size(int w, int h, uint32_t width, uint32_t height)
{
  int d;

  for (d = 1; d <= 8; d *= 2)
    if (width == (uint32_t)((w + d - 1) / d) && height == (uint32_t)((h + d - 1) / d))
      return 1;
  return 0;
}

const char *jpeg_decode(const uint8_t *data, size_t size, uint32_t width, uint32_t height, uint32_t memory_mb, Image *image)
{
  tjhandle tj = open_decompressor();
  int w, h, colorspace, format;
  size_t bytes, i;
  const char *error;

  if (!tj)
    return "out of memory";
  error = read_header(tj, data, size, &w, &h, &colorspace);
  if (!error && tj3Set(tj, TJPARAM_MAXMEMORY, (int)(memory_mb < 2047 ? memory_mb : 2047)))
    error = guest_message(tj3GetErrorStr(tj));
  if (!error && !scaled_size(w, h, width, height))
    error = "invalid decode options";
  if (!error) {
    format = colorspace == TJCS_GRAY ? TJPF_GRAY : colorspace == TJCS_CMYK || colorspace == TJCS_YCCK ? TJPF_CMYK : TJPF_RGB;
    image->layout = format == TJPF_GRAY ? LAYOUT_Y8 : format == TJPF_CMYK ? LAYOUT_CMYK8 : LAYOUT_RGB8;
    bytes = (size_t)width * height * tjPixelSize[format];
    if (!(image->pixels = malloc(bytes)))
      error = "image is too large";
    else if (tjDecompress2(tj, data, (unsigned long)size, image->pixels, (int)width, 0, (int)height, format, TJFLAG_STOPONWARNING | TJFLAG_LIMITSCANS))
      error = guest_message(tjGetErrorStr2(tj));
    else if (colorspace == TJCS_YCCK)
      for (i = 0; i < bytes; i++)
        image->pixels[i] = (uint8_t)~image->pixels[i];
  }
  tjDestroy(tj);
  return error;
}
