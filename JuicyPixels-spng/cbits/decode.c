#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "juicypixels_spng.h"

struct span {
  uint32_t first;
  uint32_t weight;
};

struct scaler {
  uint32_t width;
  uint32_t height;
  uint32_t scaled_width;
  uint32_t scaled_height;
  int channels;
  struct span *columns;
  uint32_t *row_sums;
  uint64_t *sums;
  uint64_t *next_sums;
  uint32_t row;
  unsigned char *out;
};

static struct span span_of(uint32_t i, uint32_t side, uint32_t scaled)
{
  uint64_t start = (uint64_t)i * scaled, end = start + scaled;
  uint32_t first = (uint32_t)(start / side);
  uint64_t boundary = ((uint64_t)first + 1) * side;
  struct span span = {first, (uint32_t)((end < boundary ? end : boundary) - start)};

  return span;
}

static void write_row(struct scaler *s)
{
  size_t samples = (size_t)s->scaled_width * s->channels, i;
  unsigned char *pixel = s->out + (size_t)s->row * samples;
  uint64_t area = (uint64_t)s->width * s->height;
  uint64_t *sums;
  int c;

  for (i = 0; i < samples; i += s->channels, pixel += s->channels) {
    const uint64_t *sum = s->sums + i;
    uint64_t total = s->channels == 4 ? sum[3] : area;

    for (c = 0; c < 3; c++)
      pixel[c] = total ? (unsigned char)((sum[c] + total / 2) / total) : 0;
    if (s->channels == 4)
      pixel[3] = (unsigned char)((sum[3] + area / 2) / area);
  }
  memset(s->sums, 0, samples * sizeof(uint64_t));
  sums = s->sums;
  s->sums = s->next_sums;
  s->next_sums = sums;
  s->row++;
}

static void add_row(struct scaler *s, const unsigned char *row, uint32_t y)
{
  size_t samples = (size_t)s->scaled_width * s->channels, i;
  struct span rows = span_of(y, s->height, s->scaled_height);
  uint32_t x;
  int c;

  memset(s->row_sums, 0, samples * sizeof(uint32_t));
  for (x = 0; x < s->width; x++) {
    const unsigned char *pixel = row + (size_t)x * s->channels;
    uint32_t *sum = s->row_sums + (size_t)s->columns[x].first * s->channels;
    uint32_t weight = s->columns[x].weight, rest = s->scaled_width - weight;
    uint32_t alpha = s->channels == 4 ? pixel[3] : 1;
    uint32_t value[4] = {pixel[0] * alpha, pixel[1] * alpha, pixel[2] * alpha, alpha};

    for (c = 0; c < s->channels; c++)
      sum[c] += weight * value[c];
    if (rest)
      for (c = 0; c < s->channels; c++)
        sum[s->channels + c] += rest * value[c];
  }
  if (rows.first > s->row)
    write_row(s);
  for (i = 0; i < samples; i++)
    s->sums[i] += (uint64_t)rows.weight * s->row_sums[i];
  if (rows.weight < s->scaled_height)
    for (i = 0; i < samples; i++)
      s->next_sums[i] += (uint64_t)(s->scaled_height - rows.weight) * s->row_sums[i];
}

int juicypixels_spng_decode(spng_ctx *ctx, int fmt, unsigned char *out, uint32_t width, uint32_t height)
{
  struct spng_ihdr ihdr;
  struct scaler s = {0};
  unsigned char *pixels;
  size_t row_size;
  uint32_t x, y;
  int rc = spng_get_ihdr(ctx, &ihdr);

  if (rc)
    return rc;
  s.channels = fmt == SPNG_FMT_RGBA8 ? 4 : fmt == SPNG_FMT_RGB8 ? 3 : 0;
  if (!s.channels || width < 1 || height < 1 || width > ihdr.width || height > ihdr.height)
    return SPNG_EINVAL;
  if (width == ihdr.width && height == ihdr.height)
    return spng_decode_image(ctx, out, (size_t)width * height * s.channels, fmt, SPNG_DECODE_TRNS);
  if ((uint64_t)ihdr.width * 255 * 255 > UINT32_MAX)
    return SPNG_EOVERFLOW;
  s.width = ihdr.width;
  s.height = ihdr.height;
  s.scaled_width = width;
  s.scaled_height = height;
  s.out = out;
  row_size = (size_t)ihdr.width * s.channels;
  s.columns = malloc((size_t)ihdr.width * sizeof(struct span));
  s.row_sums = malloc((size_t)width * s.channels * sizeof(uint32_t));
  s.sums = calloc((size_t)width * s.channels, sizeof(uint64_t));
  s.next_sums = calloc((size_t)width * s.channels, sizeof(uint64_t));
  pixels = malloc(ihdr.interlace_method ? row_size * ihdr.height : row_size);
  if (!s.columns || !s.row_sums || !s.sums || !s.next_sums || !pixels)
    rc = SPNG_EMEM;
  for (x = 0; !rc && x < ihdr.width; x++)
    s.columns[x] = span_of(x, ihdr.width, width);
  if (!rc && ihdr.interlace_method) {
    rc = spng_decode_image(ctx, pixels, row_size * ihdr.height, fmt, SPNG_DECODE_TRNS);
    for (y = 0; !rc && y < ihdr.height; y++)
      add_row(&s, pixels + y * row_size, y);
  } else if (!rc) {
    rc = spng_decode_image(ctx, NULL, 0, fmt, SPNG_DECODE_TRNS | SPNG_DECODE_PROGRESSIVE);
    for (y = 0; !rc && y < ihdr.height; y++) {
      rc = spng_decode_row(ctx, pixels, row_size);
      if (rc == SPNG_EOI && y + 1 == ihdr.height)
        rc = 0;
      if (!rc)
        add_row(&s, pixels, y);
    }
  }
  if (!rc)
    write_row(&s);
  free(pixels);
  free(s.next_sums);
  free(s.sums);
  free(s.row_sums);
  free(s.columns);
  return rc;
}
