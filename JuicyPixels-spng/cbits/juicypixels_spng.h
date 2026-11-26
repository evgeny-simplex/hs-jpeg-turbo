#ifndef JUICYPIXELS_SPNG_H
#define JUICYPIXELS_SPNG_H

#include <stdint.h>
#include "spng.h"

int juicypixels_spng_decode(spng_ctx *ctx, int fmt, unsigned char *out, uint32_t width, uint32_t height);

#endif
