#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "hs_webp.h"
#include "src/utils/palette.h"
#include "src/utils/utils.h"
#include "src/webp/encode.h"

#define BLOCK_HEADER 16

static _Thread_local HsWebPMemory *active;

static void *allocate(size_t size, int zero)
{
  HsWebPMemory *memory = active;
  size_t *block;

  if (!memory)
    return NULL;
  if (memory->used > memory->limit || memory->limit - memory->used < BLOCK_HEADER || size > memory->limit - memory->used - BLOCK_HEADER) {
    memory->refused = 1;
    return NULL;
  }
  block = zero ? calloc(1, size + BLOCK_HEADER) : malloc(size + BLOCK_HEADER);
  if (!block)
    return NULL;
  *block = size + BLOCK_HEADER;
  memory->used += *block;
  if (memory->used > memory->peak)
    memory->peak = memory->used;
  return (unsigned char *)block + BLOCK_HEADER;
}

static void release(void *ptr)
{
  size_t *block;

  if (!ptr)
    return;
  block = (size_t *)((unsigned char *)ptr - BLOCK_HEADER);
  if (active)
    active->used -= *block;
  free(block);
}

#define malloc(size) allocate(size, 0)
#define calloc(count, size) allocate((count) * (size), 1)
#define free(ptr) release(ptr)
#include "libwebp/src/utils/utils.c"
#undef malloc
#undef calloc
#undef free

WebPDemuxer *HsWebPDemux(const uint8_t *data, size_t size, HsWebPMemory *memory)
{
  WebPData webp;
  WebPDemuxer *demux;

  webp.bytes = data;
  webp.size = size;
  memory->used = 0;
  memory->peak = 0;
  memory->refused = 0;
  active = memory;
  demux = WebPDemux(&webp);
  active = NULL;
  return demux;
}

VP8StatusCode HsWebPDecode(const uint8_t *data, size_t size, WebPDecoderConfig *config, HsWebPMemory *memory)
{
  VP8StatusCode status;

  active = memory;
  status = WebPDecode(data, size, config);
  active = NULL;
  return status;
}
