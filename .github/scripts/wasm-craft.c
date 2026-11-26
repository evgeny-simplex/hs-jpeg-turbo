#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "src/webp/encode.h"

typedef struct {
  uint8_t *data;
  size_t size, capacity;
  uint64_t bits;
  int used;
} Writer;

static void put_byte(Writer *w, uint8_t byte)
{
  if (w->size == w->capacity) {
    w->capacity = w->capacity ? 2 * w->capacity : 1 << 16;
    if (!(w->data = realloc(w->data, w->capacity))) {
      perror("realloc");
      exit(1);
    }
  }
  w->data[w->size++] = byte;
}

static void put(Writer *w, uint32_t value, int n)
{
  w->bits |= (uint64_t)value << w->used;
  w->used += n;
  while (w->used >= 8) {
    put_byte(w, (uint8_t)w->bits);
    w->bits >>= 8;
    w->used -= 8;
  }
}

static void finish(Writer *w)
{
  int i;
  put(w, 0, 7);
  for (i = 0; i < 8; i++)
    put_byte(w, 0);
  w->used = 0;
  w->bits = 0;
}

static uint32_t reversed(uint32_t value)
{
  uint32_t r = 0;
  int i;
  for (i = 0; i < 8; i++)
    r |= ((value >> i) & 1) << (7 - i);
  return r;
}

static void single_symbol_code(Writer *w, uint32_t symbol)
{
  put(w, 1, 1);
  put(w, 0, 1);
  put(w, 1, 1);
  put(w, symbol, 8);
}

static void byte_code(Writer *w)
{
  static const int order[12] = {17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8};
  int i;
  put(w, 0, 1);
  put(w, 12 - 4, 4);
  for (i = 0; i < 12; i++)
    put(w, order[i] == 8 || order[i] == 16, 3);
  put(w, 1, 1);
  put(w, 2, 3);
  put(w, 44 - 2, 6);
  put(w, 0, 1);
  for (i = 0; i < 42; i++) {
    put(w, 1, 1);
    put(w, 3, 2);
  }
  put(w, 1, 1);
  put(w, 0, 2);
}

static void trivial_group(Writer *w, uint32_t green)
{
  single_symbol_code(w, green);
  single_symbol_code(w, 64);
  single_symbol_code(w, 32);
  single_symbol_code(w, 255);
  single_symbol_code(w, 0);
}

static void subsampled_transform(Writer *w, uint32_t type)
{
  put(w, 1, 1);
  put(w, type, 2);
  put(w, 0, 3);
  put(w, 0, 1);
  trivial_group(w, 0);
}

static void image_stream(Writer *w, int width, int height, int groups)
{
  size_t pixels, i;
  if (groups == 0) {
    put(w, 0, 1);
    put(w, 0, 1);
    put(w, 0, 1);
    trivial_group(w, 128);
    return;
  }
  subsampled_transform(w, 0);
  subsampled_transform(w, 1);
  put(w, 0, 1);
  put(w, 0, 1);
  put(w, 1, 1);
  put(w, 0, 3);
  put(w, 0, 1);
  byte_code(w);
  byte_code(w);
  single_symbol_code(w, 0);
  single_symbol_code(w, 0);
  single_symbol_code(w, 0);
  pixels = (size_t)((width + 3) / 4) * ((height + 3) / 4);
  for (i = 0; i < pixels; i++) {
    put(w, reversed((uint32_t)(i % groups) & 0xff), 8);
    put(w, reversed((uint32_t)(i % groups) >> 8), 8);
  }
  for (i = 0; i < (size_t)groups; i++)
    trivial_group(w, (uint32_t)i & 0xff);
}

static void put_le(Writer *w, uint32_t value, int bytes)
{
  int i;
  for (i = 0; i < bytes; i++)
    put_byte(w, (uint8_t)(value >> (8 * i)));
}

static void chunk(Writer *w, const char *fourcc, const uint8_t *payload, size_t size)
{
  size_t i;
  for (i = 0; i < 4; i++)
    put_byte(w, (uint8_t)fourcc[i]);
  put_le(w, (uint32_t)size, 4);
  for (i = 0; i < size; i++)
    put_byte(w, payload[i]);
  if (size & 1)
    put_byte(w, 0);
}

static void lossy_frame(int width, int height, WebPMemoryWriter *writer)
{
  WebPConfig config;
  WebPPicture picture;
  uint8_t *rgb = malloc((size_t)width * height * 3);

  if (!rgb || !WebPConfigInit(&config) || !WebPPictureInit(&picture)) {
    fprintf(stderr, "lossy frame: initialisation failed\n");
    exit(1);
  }
  memset(rgb, 128, (size_t)width * height * 3);
  config.method = 0;
  picture.width = width;
  picture.height = height;
  picture.writer = WebPMemoryWrite;
  picture.custom_ptr = writer;
  WebPMemoryWriterInit(writer);
  if (!WebPPictureImportRGB(&picture, rgb, width * 3) || !WebPEncode(&config, &picture)) {
    fprintf(stderr, "lossy frame: encoding error %d\n", picture.error_code);
    exit(1);
  }
  WebPPictureFree(&picture);
  free(rgb);
}

int main(int argc, char **argv)
{
  Writer stream = {0}, file = {0};
  WebPMemoryWriter lossy;
  uint8_t vp8x[10] = {0x10};
  size_t fixed, total, filler, i;
  int width, height, groups, alpha;
  FILE *out;

  if (argc != 7 || (strcmp(argv[2], "lossless") && strcmp(argv[2], "alpha"))) {
    fprintf(stderr, "usage: %s OUTPUT lossless|alpha WIDTH HEIGHT GROUPS FILE_BYTES\n", argv[0]);
    return 2;
  }
  alpha = !strcmp(argv[2], "alpha");
  width = atoi(argv[3]);
  height = atoi(argv[4]);
  groups = atoi(argv[5]);
  total = strtoull(argv[6], NULL, 10);
  if (alpha) {
    put_byte(&stream, 1);
  } else {
    put_byte(&stream, 0x2f);
    put(&stream, width - 1, 14);
    put(&stream, height - 1, 14);
    put(&stream, 1, 1);
    put(&stream, 0, 3);
  }
  image_stream(&stream, width, height, groups);
  finish(&stream);
  if (alpha)
    lossy_frame(width, height, &lossy);
  for (i = 0; i < 3; i++) {
    vp8x[4 + i] = (uint8_t)((width - 1) >> (8 * i));
    vp8x[7 + i] = (uint8_t)((height - 1) >> (8 * i));
  }
  fixed = 12 + 18 + 8 + stream.size + (stream.size & 1) + (alpha ? lossy.size - 12 : 0);
  filler = total > fixed ? (total - fixed) / 8 : 0;
  put_byte(&file, 'R');
  put_byte(&file, 'I');
  put_byte(&file, 'F');
  put_byte(&file, 'F');
  put_le(&file, (uint32_t)(fixed + 8 * filler - 8), 4);
  put_byte(&file, 'W');
  put_byte(&file, 'E');
  put_byte(&file, 'B');
  put_byte(&file, 'P');
  chunk(&file, "VP8X", vp8x, sizeof(vp8x));
  for (i = 0; i < filler; i++)
    chunk(&file, "ABCD", NULL, 0);
  chunk(&file, alpha ? "ALPH" : "VP8L", stream.data, stream.size);
  if (alpha) {
    for (i = 12; i < lossy.size; i++)
      put_byte(&file, lossy.mem[i]);
    WebPMemoryWriterClear(&lossy);
  }
  if (!(out = fopen(argv[1], "wb")) || fwrite(file.data, 1, file.size, out) != file.size || fclose(out) != 0) {
    perror(argv[1]);
    return 1;
  }
  printf("%s: %s %dx%d, %d Huffman groups, %lu bytes, %lu empty chunks\n", argv[1], argv[2], width, height, groups, (unsigned long)file.size,
         (unsigned long)filler);
  return 0;
}
