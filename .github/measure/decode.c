#include <stdio.h>
#include <stdlib.h>
#include "spng.h"

int main(int argc, char **argv)
{
  FILE *in, *out;
  unsigned char *png, *image = NULL;
  long size;
  size_t len = 0;
  struct spng_ihdr ihdr;
  spng_ctx *ctx = spng_ctx_new(0);
  int rc;

  if (argc != 3) {
    fprintf(stderr, "usage: %s PNG RGBA\n", argv[0]);
    return 2;
  }
  in = fopen(argv[1], "rb");
  if (!in || fseek(in, 0, SEEK_END) != 0 || (size = ftell(in)) < 0 || fseek(in, 0, SEEK_SET) != 0 ||
      !(png = malloc(size)) || fread(png, 1, size, in) != (size_t)size || fclose(in) != 0) {
    perror(argv[1]);
    return 1;
  }
  rc = spng_set_png_buffer(ctx, png, size);
  if (!rc)
    rc = spng_set_image_limits(ctx, 16384, 16384);
  if (!rc)
    rc = spng_set_chunk_limits(ctx, 1048576, 64 << 20);
  if (!rc)
    rc = spng_get_ihdr(ctx, &ihdr);
  if (!rc)
    rc = spng_decoded_image_size(ctx, SPNG_FMT_RGBA8, &len);
  if (!rc && !(image = malloc(len)))
    rc = SPNG_EMEM;
  if (!rc)
    rc = spng_decode_image(ctx, image, len, SPNG_FMT_RGBA8, SPNG_DECODE_TRNS);
  if (rc) {
    fprintf(stderr, "%s: %s\n", argv[1], spng_strerror(rc));
    return 1;
  }
  if (!(out = fopen(argv[2], "wb")) || fwrite(image, 1, len, out) != len || fclose(out) != 0) {
    perror(argv[2]);
    return 1;
  }
  printf("%u %u\n", ihdr.width, ihdr.height);
  spng_ctx_free(ctx);
  free(image);
  free(png);
  return 0;
}
