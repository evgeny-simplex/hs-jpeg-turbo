#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "src/webp/encode.h"

int main(int argc, char **argv)
{
  WebPConfig config;
  WebPPicture picture;
  WebPMemoryWriter writer;
  WebPAuxStats stats;
  FILE *out;
  int width, height, lossless, alpha, method, x, y;
  uint8_t *rgba, *pixel;

  if (argc != 7) {
    fprintf(stderr, "usage: %s OUTPUT WIDTH HEIGHT LOSSLESS ALPHA METHOD\n", argv[0]);
    return 2;
  }
  width = atoi(argv[2]);
  height = atoi(argv[3]);
  lossless = atoi(argv[4]);
  alpha = atoi(argv[5]);
  method = atoi(argv[6]);
  if (!(rgba = malloc((size_t)width * height * 4)))
    return 1;
  for (y = 0, pixel = rgba; y < height; y++) {
    for (x = 0; x < width; x++, pixel += 4) {
      pixel[0] = (uint8_t)x;
      pixel[1] = (uint8_t)y;
      pixel[2] = (uint8_t)(x ^ y);
      pixel[3] = alpha == 2 ? (uint8_t)(x + y) : alpha ? (uint8_t)(128 + ((x / 64 + y / 64) & 127)) : 255;
    }
  }
  if (!WebPConfigInit(&config) || !WebPPictureInit(&picture))
    return 1;
  config.lossless = lossless;
  config.method = method;
  config.partition_limit = 100;
  config.alpha_filtering = alpha == 2 ? 0 : config.alpha_filtering;
  picture.use_argb = lossless;
  picture.width = width;
  picture.height = height;
  picture.writer = WebPMemoryWrite;
  picture.custom_ptr = &writer;
  picture.stats = &stats;
  WebPMemoryWriterInit(&writer);
  if (!WebPPictureImportRGBA(&picture, rgba, width * 4) || !WebPEncode(&config, &picture)) {
    fprintf(stderr, "encoding error %d\n", picture.error_code);
    return 1;
  }
  if (!(out = fopen(argv[1], "wb")) || fwrite(writer.mem, 1, writer.size, out) != writer.size || fclose(out) != 0) {
    perror(argv[1]);
    return 1;
  }
  printf("%s: %dx%d, %s%s, method %d, %lu bytes; %s stream: transforms 0x%x, predictor bits %d, cross-colour bits %d, histogram bits %d, cache bits %d\n", argv[1], width, height,
         lossless ? "lossless" : "lossy", alpha ? " with alpha" : "", method, (unsigned long)writer.size, lossless ? "lossless" : "alpha", stats.lossless_features,
         stats.transform_bits, stats.cross_color_transform_bits, stats.histogram_bits, stats.cache_bits);
  return 0;
}
