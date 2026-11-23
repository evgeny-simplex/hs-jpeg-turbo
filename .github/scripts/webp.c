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

static int decode(const unsigned char *webp, size_t size, Canvas *canvas)
{
  WebPData data = {webp, size};
  WebPDemuxer *demux = WebPDemux(&data);
  WebPIterator iter;
  WebPDecoderConfig config;
  size_t stride, offset;
  int animated, rc = VP8_STATUS_BITSTREAM_ERROR;

  canvas->pixels = NULL;
  if (!demux)
    return rc;
  canvas->width = WebPDemuxGetI(demux, WEBP_FF_CANVAS_WIDTH);
  canvas->height = WebPDemuxGetI(demux, WEBP_FF_CANVAS_HEIGHT);
  animated = (WebPDemuxGetI(demux, WEBP_FF_FORMAT_FLAGS) & ANIMATION_FLAG) != 0;
  if (canvas->width <= MAX_SIDE && canvas->height <= MAX_SIDE && WebPDemuxGetFrame(demux, 1, &iter)) {
    canvas->channels = animated || iter.has_alpha ? 4 : 3;
    stride = (size_t)canvas->width * canvas->channels;
    offset = (size_t)iter.y_offset * stride + (size_t)iter.x_offset * canvas->channels;
    if (stride * canvas->height <= MAX_BYTES && (canvas->pixels = calloc(stride, canvas->height)) &&
        WebPInitDecoderConfig(&config)) {
      config.output.colorspace = canvas->channels == 4 ? MODE_RGBA : MODE_RGB;
      config.output.is_external_memory = 1;
      config.output.u.RGBA.rgba = canvas->pixels + offset;
      config.output.u.RGBA.stride = (int)stride;
      config.output.u.RGBA.size = stride * canvas->height - offset;
      rc = WebPDecode(iter.fragment.bytes, iter.fragment.size, &config);
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

static void write_netpbm(const char *dir, const char *path)
{
  const char *name = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
  char output[4096];
  size_t size;
  unsigned char *webp = read_file(path, &size);
  Canvas canvas;
  int rc = decode(webp, size, &canvas);
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

static int decode_copy(const unsigned char *webp, size_t size, size_t changed, unsigned char mask)
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
  rc = decode(copy, size, &canvas);
  free(canvas.pixels);
  free(copy);
  return rc == VP8_STATUS_OK;
}

static void fuzz(const char *path, int *runs, int *decoded)
{
  size_t size, k;
  unsigned char *webp = read_file(path, &size);

  for (k = 0; k < 64; k++) {
    *decoded += decode_copy(webp, size * k / 64, size, 0);
    *decoded += decode_copy(webp, size, (size - 1) * k / 63, (unsigned char)(1u << (k % 8)));
    *runs += 2;
  }
  free(webp);
}

int main(int argc, char **argv)
{
  int i, runs = 0, decoded = 0;

  if (argc >= 4 && !strcmp(argv[1], "check")) {
    for (i = 3; i < argc; i++)
      write_netpbm(argv[2], argv[i]);
    return 0;
  }
  if (argc >= 3 && !strcmp(argv[1], "fuzz")) {
    for (i = 2; i < argc; i++)
      fuzz(argv[i], &runs, &decoded);
    printf("%d truncated and changed inputs: %d decoded, %d refused with a decoder status\n", runs, decoded, runs - decoded);
    return 0;
  }
  fprintf(stderr, "usage: %s check DIRECTORY WEBP... | fuzz WEBP...\n", argv[0]);
  return 2;
}
