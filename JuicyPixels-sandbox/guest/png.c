#include <stdlib.h>
#include <string.h>
#include "guest.h"
#include "juicypixels_spng.h"

static const char *spng_error(int rc)
{
  return guest_message(spng_strerror(rc));
}

static const char *open_decoder(const uint8_t *data, size_t size, spng_ctx **ctx, struct spng_ihdr *ihdr)
{
  int rc;

  if (!(*ctx = spng_ctx_new(0)))
    return "out of memory";
  if ((rc = spng_set_png_buffer(*ctx, data, size)) || (rc = spng_set_image_limits(*ctx, SANDBOX_MAX_SIDE, SANDBOX_MAX_SIDE)) ||
      (rc = spng_set_chunk_limits(*ctx, 1048576, 64 * 1048576)) || (rc = spng_get_ihdr(*ctx, ihdr)))
    return spng_error(rc);
  return NULL;
}

const char *png_header(const uint8_t *data, size_t size, uint32_t *width, uint32_t *height)
{
  spng_ctx *ctx;
  struct spng_ihdr ihdr;
  const char *error = open_decoder(data, size, &ctx, &ihdr);

  if (!error) {
    *width = ihdr.width;
    *height = ihdr.height;
  }
  spng_ctx_free(ctx);
  return error;
}

static const char *read_icc_profile(spng_ctx *ctx, Image *image)
{
  struct spng_iccp iccp;
  uint8_t *profile;
  int rc = spng_get_iccp(ctx, &iccp);

  if (rc == SPNG_ECHUNKAVAIL)
    return NULL;
  if (rc)
    return spng_error(rc);
  if (!(profile = malloc(iccp.profile_len ? iccp.profile_len : 1)))
    return "image is too large";
  memcpy(profile, iccp.profile, iccp.profile_len);
  image->icc = profile;
  image->icc_size = iccp.profile_len;
  return NULL;
}

const char *png_decode(const uint8_t *data, size_t size, uint32_t width, uint32_t height, Image *image)
{
  spng_ctx *ctx;
  struct spng_ihdr ihdr;
  struct spng_trns trns;
  int rc, alpha, format;
  size_t channels;
  const char *error = open_decoder(data, size, &ctx, &ihdr);

  if (!error && (width < 1 || width > ihdr.width || height < 1 || height > ihdr.height))
    error = "invalid decode options";
  if (!error) {
    rc = spng_get_trns(ctx, &trns);
    if (rc && rc != SPNG_ECHUNKAVAIL)
      error = spng_error(rc);
    alpha = rc != SPNG_ECHUNKAVAIL || ihdr.color_type == SPNG_COLOR_TYPE_GRAYSCALE_ALPHA || ihdr.color_type == SPNG_COLOR_TYPE_TRUECOLOR_ALPHA;
    format = alpha ? SPNG_FMT_RGBA8 : SPNG_FMT_RGB8;
    channels = alpha ? 4 : 3;
    image->layout = alpha ? LAYOUT_RGBA8 : LAYOUT_RGB8;
  }
  if (!error && !(image->pixels = malloc((size_t)width * height * channels)))
    error = "image is too large";
  if (!error && ((rc = juicypixels_spng_decode(ctx, format, image->pixels, width, height)) || (rc = spng_decode_chunks(ctx))))
    error = spng_error(rc);
  if (!error)
    error = read_icc_profile(ctx, image);
  spng_ctx_free(ctx);
  return error;
}
