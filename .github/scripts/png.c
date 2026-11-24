#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "juicypixels_spng.h"

static const int formats[2] = {SPNG_FMT_RGBA8, SPNG_FMT_RGB8};

static int decode(const unsigned char *png, size_t size, int fmt, uint32_t max_side, unsigned char **image, size_t *len)
{
  spng_ctx *ctx = spng_ctx_new(0);
  struct spng_ihdr ihdr;
  uint32_t width = 0, height = 0;
  int rc = spng_set_png_buffer(ctx, png, size);

  *image = NULL;
  *len = 0;
  if (!rc)
    rc = spng_set_image_limits(ctx, 16384, 16384);
  if (!rc)
    rc = spng_set_chunk_limits(ctx, 64 << 20, 64 << 20);
  if (!rc)
    rc = spng_get_ihdr(ctx, &ihdr);
  if (!rc) {
    width = ihdr.width;
    height = ihdr.height;
    while (width > max_side || height > max_side) {
      width = (width + 1) / 2;
      height = (height + 1) / 2;
    }
    *len = (size_t)width * height * (fmt == SPNG_FMT_RGBA8 ? 4 : 3);
    if (!(*image = malloc(*len)))
      rc = SPNG_EMEM;
  }
  if (!rc)
    rc = juicypixels_spng_decode(ctx, fmt, *image, width, height);
  if (!rc)
    rc = spng_decode_chunks(ctx);
  spng_ctx_free(ctx);
  return rc;
}

static unsigned char *read_file(const char *path, size_t *size)
{
  FILE *in = fopen(path, "rb");
  unsigned char *data = NULL;
  long length;

  if (!in || fseek(in, 0, SEEK_END) != 0 || (length = ftell(in)) < 0 || fseek(in, 0, SEEK_SET) != 0 ||
      !(data = malloc(length + 1)) || fread(data, 1, length, in) != (size_t)length || fclose(in) != 0) {
    perror(path);
    exit(1);
  }
  *size = length;
  return data;
}

static void write_file(const char *path, const void *data, size_t size)
{
  FILE *out = fopen(path, "wb");

  if (!out || fwrite(data, 1, size, out) != size || fclose(out) != 0) {
    perror(path);
    exit(1);
  }
}

static void check(const char *dir, uint32_t max_side, const char *input)
{
  const char *name = strrchr(input, '/') ? strrchr(input, '/') + 1 : input;
  size_t size, len;
  unsigned char *png = read_file(input, &size), *image;
  int i;

  for (i = 0; i < 2; i++) {
    char path[4096];
    int rc = decode(png, size, formats[i], max_side, &image, &len);
    const char *error = rc ? spng_strerror(rc) : NULL;

    snprintf(path, sizeof(path), "%s/%s.%s", dir, name, formats[i] == SPNG_FMT_RGBA8 ? "rgba" : "rgb");
    write_file(path, rc ? (const void *)error : image, rc ? strlen(error) : len);
    free(image);
  }
  free(png);
}

static void fuzz(uint32_t max_side, const char *input)
{
  size_t size, len, k;
  unsigned char *png = read_file(input, &size), *image;
  int i;

  for (k = 0; k < 128; k++) {
    size_t at = size * (k % 64) / 64;
    unsigned char saved = png[at];

    if (k >= 64)
      png[at] ^= (unsigned char)(0x55 + k);
    for (i = 0; i < 2; i++) {
      decode(png, k < 64 ? at : size, formats[i], max_side, &image, &len);
      free(image);
    }
    png[at] = saved;
  }
  free(png);
}

static uint32_t next_random(uint32_t *state)
{
  *state = *state * 1664525 + 1013904223;
  return *state >> 24;
}

static void encode(const char *dir, const char *name, uint32_t width, uint32_t height, uint8_t depth, uint8_t color_type, uint8_t interlace)
{
  struct spng_ihdr ihdr = {width, height, depth, color_type, 0, 0, interlace};
  size_t channels = color_type == SPNG_COLOR_TYPE_TRUECOLOR_ALPHA ? 4 : 3;
  size_t len = (size_t)width * height * channels * (depth / 8), i, png_size;
  unsigned char *pixels = malloc(len), *png;
  uint32_t state = 1;
  spng_ctx *ctx = spng_ctx_new(SPNG_CTX_ENCODER);
  char path[4096];
  int rc;

  if (!pixels || !ctx) {
    fprintf(stderr, "%s: out of memory\n", name);
    exit(1);
  }
  for (i = 0; i < len; i++)
    pixels[i] = (unsigned char)(i % 7 == 0 ? next_random(&state) : (i / (channels * (depth / 8)) + i) % 256);
  rc = spng_set_option(ctx, SPNG_ENCODE_TO_BUFFER, 1);
  if (!rc)
    rc = spng_set_ihdr(ctx, &ihdr);
  if (!rc)
    rc = spng_encode_image(ctx, pixels, len, SPNG_FMT_PNG, SPNG_ENCODE_FINALIZE);
  if (rc || !(png = spng_get_png_buffer(ctx, &png_size, &rc))) {
    fprintf(stderr, "%s: %s\n", name, spng_strerror(rc));
    exit(1);
  }
  snprintf(path, sizeof(path), "%s/%s", dir, name);
  write_file(path, png, png_size);
  free(png);
  free(pixels);
  spng_ctx_free(ctx);
}

int main(int argc, char **argv)
{
  int i;

  if (argc == 3 && !strcmp(argv[1], "encode")) {
    encode(argv[2], "noise-rgba.png", 4500, 600, 8, SPNG_COLOR_TYPE_TRUECOLOR_ALPHA, 0);
    encode(argv[2], "noise-rgba-adam7.png", 4500, 600, 8, SPNG_COLOR_TYPE_TRUECOLOR_ALPHA, 1);
    encode(argv[2], "noise-rgb16.png", 16384, 9, 16, SPNG_COLOR_TYPE_TRUECOLOR, 0);
    return 0;
  }
  if (argc >= 5 && !strcmp(argv[1], "check")) {
    for (i = 4; i < argc; i++)
      check(argv[2], (uint32_t)strtoul(argv[3], NULL, 10), argv[i]);
    return 0;
  }
  if (argc >= 4 && !strcmp(argv[1], "fuzz")) {
    for (i = 3; i < argc; i++)
      fuzz((uint32_t)strtoul(argv[2], NULL, 10), argv[i]);
    return 0;
  }
  fprintf(stderr, "usage: %s encode DIRECTORY | check DIRECTORY MAX_SIDE PNG... | fuzz MAX_SIDE PNG...\n", argv[0]);
  return 2;
}
