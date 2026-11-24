#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "src/webp/decode.h"
#include "src/webp/demux.h"

#define MAX_SIDE 16384
#define MAX_BYTES (512u << 20)

typedef struct {
  unsigned char *pixels;
  int width, height, channels;
} Canvas;

static int scaled_start(int offset, int side, int scaled_side)
{
  return (int)((long long)offset * scaled_side / side);
}

static int scaled_end(int end, int side, int scaled_side)
{
  return (int)(((long long)end * scaled_side + side - 1) / side);
}

static int decode(const unsigned char *webp, size_t size, int max_side, Canvas *canvas)
{
  WebPData data = {webp, size};
  WebPDemuxer *demux = WebPDemux(&data);
  WebPIterator iter;
  WebPDecoderConfig config;
  size_t stride, offset;
  int width, height, x, y, w, h, animated, rc = VP8_STATUS_BITSTREAM_ERROR;

  canvas->pixels = NULL;
  if (!demux)
    return rc;
  width = canvas->width = WebPDemuxGetI(demux, WEBP_FF_CANVAS_WIDTH);
  height = canvas->height = WebPDemuxGetI(demux, WEBP_FF_CANVAS_HEIGHT);
  while ((canvas->width > max_side || canvas->height > max_side) && canvas->width > 1 && canvas->height > 1) {
    canvas->width = (canvas->width + 1) / 2;
    canvas->height = (canvas->height + 1) / 2;
  }
  animated = (WebPDemuxGetI(demux, WEBP_FF_FORMAT_FLAGS) & ANIMATION_FLAG) != 0;
  if (width <= MAX_SIDE && height <= MAX_SIDE && WebPDemuxGetFrame(demux, 1, &iter)) {
    if (WebPInitDecoderConfig(&config) &&
        (rc = WebPGetFeatures(iter.fragment.bytes, iter.fragment.size, &config.input)) == VP8_STATUS_OK) {
      canvas->channels = animated || config.input.has_alpha ? 4 : 3;
      x = scaled_start(iter.x_offset, width, canvas->width);
      y = scaled_start(iter.y_offset, height, canvas->height);
      w = scaled_end(iter.x_offset + config.input.width, width, canvas->width) - x;
      h = scaled_end(iter.y_offset + config.input.height, height, canvas->height) - y;
      stride = (size_t)canvas->width * canvas->channels;
      offset = (size_t)y * stride + (size_t)x * canvas->channels;
      rc = VP8_STATUS_OUT_OF_MEMORY;
      if (stride * canvas->height <= MAX_BYTES && (canvas->pixels = calloc(stride, canvas->height))) {
        config.output.colorspace = canvas->channels == 4 ? MODE_RGBA : MODE_RGB;
        config.output.is_external_memory = 1;
        config.output.u.RGBA.rgba = canvas->pixels + offset;
        config.output.u.RGBA.stride = (int)stride;
        config.output.u.RGBA.size = stride * canvas->height - offset;
        if (w != config.input.width || h != config.input.height) {
          config.options.use_scaling = 1;
          config.options.scaled_width = w;
          config.options.scaled_height = h;
        }
        rc = WebPDecode(iter.fragment.bytes, iter.fragment.size, &config);
      }
    }
    WebPDemuxReleaseIterator(&iter);
  }
  WebPDemuxDelete(demux);
  if (rc != VP8_STATUS_OK) {
    free(canvas->pixels);
    canvas->pixels = NULL;
  }
  return rc;
}

static unsigned char *read_file(const char *path, size_t *size)
{
  FILE *in = fopen(path, "rb");
  unsigned char *bytes = NULL;
  long len;

  if (!in || fseek(in, 0, SEEK_END) != 0 || (len = ftell(in)) < 0 || fseek(in, 0, SEEK_SET) != 0 ||
      !(bytes = malloc(len + 1)) || fread(bytes, 1, len, in) != (size_t)len || fclose(in) != 0) {
    perror(path);
    exit(1);
  }
  *size = len;
  return bytes;
}

static void write_netpbm(const char *dir, int max_side, const char *path)
{
  const char *name = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
  char output[4096];
  size_t size;
  unsigned char *webp = read_file(path, &size);
  Canvas canvas;
  int rc = decode(webp, size, max_side, &canvas);
  FILE *out;

  snprintf(output, sizeof(output), "%s/%s.%s", dir, name, rc ? "err" : canvas.channels == 4 ? "pam" : "ppm");
  if (!(out = fopen(output, "wb")) ||
      (rc ? fprintf(out, "status %d\n", rc) < 0
          : (canvas.channels == 4
                 ? fprintf(out, "P7\nWIDTH %d\nHEIGHT %d\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n", canvas.width, canvas.height)
                 : fprintf(out, "P6\n%d %d\n255\n", canvas.width, canvas.height)) < 0 ||
                fwrite(canvas.pixels, (size_t)canvas.width * canvas.channels, canvas.height, out) != (size_t)canvas.height) ||
      fclose(out) != 0) {
    perror(output);
    exit(1);
  }
  free(canvas.pixels);
  free(webp);
}

static void set_le32(unsigned char *p, size_t value)
{
  p[0] = (unsigned char)value;
  p[1] = (unsigned char)(value >> 8);
  p[2] = (unsigned char)(value >> 16);
  p[3] = (unsigned char)(value >> 24);
}

static size_t fit_container(unsigned char *webp, size_t size)
{
  size_t pos = 12, payload;

  if (size < pos)
    return size;
  while (pos + 8 <= size) {
    payload = webp[pos + 4] | webp[pos + 5] << 8 | webp[pos + 6] << 16 | (size_t)webp[pos + 7] << 24;
    if ((unsigned long long)payload + (payload & 1) > size - pos - 8) {
      payload = (size - pos - 8) & ~(size_t)1;
      set_le32(webp + pos + 4, payload);
    }
    pos += 8 + payload + (payload & 1);
  }
  set_le32(webp + 4, pos - 8);
  return pos;
}

static int decode_copy(const unsigned char *webp, size_t size, size_t changed, unsigned char mask, int max_side)
{
  unsigned char *copy = malloc(size ? size : 1);
  Canvas canvas;
  int rc;

  if (!copy) {
    perror("malloc");
    exit(1);
  }
  memcpy(copy, webp, size);
  if (changed < size)
    copy[changed] ^= mask;
  else
    size = fit_container(copy, size);
  rc = decode(copy, size, max_side, &canvas);
  free(canvas.pixels);
  free(copy);
  return rc == VP8_STATUS_OK;
}

static void fuzz(const char *path, int max_side, int *runs, int *decoded)
{
  size_t size, k;
  unsigned char *webp = read_file(path, &size);

  for (k = 0; k < 64; k++) {
    *decoded += decode_copy(webp, size * k / 64, size, 0, max_side);
    *decoded += decode_copy(webp, size, (size - 1) * k / 63, (unsigned char)(1u << (k % 8)), max_side);
    *runs += 2;
  }
  free(webp);
}

int main(int argc, char **argv)
{
  int i, runs = 0, decoded = 0;

  if (argc >= 5 && !strcmp(argv[1], "check")) {
    for (i = 4; i < argc; i++)
      write_netpbm(argv[2], atoi(argv[3]), argv[i]);
    return 0;
  }
  if (argc >= 4 && !strcmp(argv[1], "fuzz")) {
    for (i = 3; i < argc; i++)
      fuzz(argv[i], atoi(argv[2]), &runs, &decoded);
    printf("%d truncated and changed inputs decoded with sides of at most %s: %d decoded, %d refused with a decoder status\n", runs, argv[2], decoded, runs - decoded);
    return 0;
  }
  fprintf(stderr, "usage: %s check DIRECTORY MAX_SIDE WEBP... | fuzz MAX_SIDE WEBP...\n", argv[0]);
  return 2;
}
