#include <stdio.h>
#include <stdlib.h>
#include "guest.h"
#include "src/webp/decode.h"
#include "src/webp/demux.h"

#define MAX_SCALE_DOWN 256

static const char *status_error(VP8StatusCode status)
{
  char text[32];

  switch (status) {
  case VP8_STATUS_OUT_OF_MEMORY:
    return "out of memory";
  case VP8_STATUS_INVALID_PARAM:
    return "invalid parameter";
  case VP8_STATUS_BITSTREAM_ERROR:
    return "bitstream error";
  case VP8_STATUS_UNSUPPORTED_FEATURE:
    return "unsupported feature";
  case VP8_STATUS_USER_ABORT:
    return "output aborted";
  case VP8_STATUS_NOT_ENOUGH_DATA:
    return "not enough data";
  default:
    snprintf(text, sizeof(text), "decoding status %d", (int)status);
    return guest_message(text);
  }
}

static const char *open_demuxer(const uint8_t *data, size_t size, WebPDemuxer **demux, uint32_t *width, uint32_t *height)
{
  WebPData input = {data, size};

  if (!(*demux = WebPDemux(&input)))
    return "invalid WebP container";
  *width = WebPDemuxGetI(*demux, WEBP_FF_CANVAS_WIDTH);
  *height = WebPDemuxGetI(*demux, WEBP_FF_CANVAS_HEIGHT);
  if (*width > SANDBOX_MAX_SIDE || *height > SANDBOX_MAX_SIDE)
    return "image side exceeds 16384";
  return NULL;
}

const char *webp_header(const uint8_t *data, size_t size, uint32_t *width, uint32_t *height, uint32_t *frames, uint32_t *loops)
{
  WebPDemuxer *demux;
  const char *error = open_demuxer(data, size, &demux, width, height);

  if (!error) {
    *frames = WebPDemuxGetI(demux, WEBP_FF_FRAME_COUNT);
    *loops = WebPDemuxGetI(demux, WEBP_FF_FORMAT_FLAGS) & ANIMATION_FLAG ? WebPDemuxGetI(demux, WEBP_FF_LOOP_COUNT) : 1;
  }
  WebPDemuxDelete(demux);
  return error;
}

static void scaled_span(uint32_t side, uint32_t scaled_side, int offset, int size, int *start, int *length)
{
  *start = (int)((uint64_t)offset * scaled_side / side);
  *length = (int)(((uint64_t)(offset + size) * scaled_side + side - 1) / side) - *start;
}

static void read_chunk(const WebPDemuxer *demux, const char *fourcc, const uint8_t **payload, size_t *size)
{
  WebPChunkIterator chunk;

  if (WebPDemuxGetChunk(demux, fourcc, 1, &chunk)) {
    *payload = chunk.chunk.bytes;
    *size = chunk.chunk.size;
    WebPDemuxReleaseChunkIterator(&chunk);
  }
}

static const char *decode_frame(const WebPIterator *iter, uint32_t canvas_width, uint32_t canvas_height, uint32_t width, uint32_t height,
                                int animated, Image *image)
{
  WebPDecoderConfig config;
  VP8StatusCode status;
  size_t channels, stride, bytes, offset;
  int x, y, w, h;

  if (!WebPInitDecoderConfig(&config))
    return status_error(VP8_STATUS_INVALID_PARAM);
  if ((status = WebPGetFeatures(iter->fragment.bytes, iter->fragment.size, &config.input)) != VP8_STATUS_OK)
    return status_error(status);
  channels = animated || config.input.has_alpha ? 4 : 3;
  image->layout = channels == 4 ? LAYOUT_RGBA8 : LAYOUT_RGB8;
  scaled_span(canvas_width, width, iter->x_offset, config.input.width, &x, &w);
  scaled_span(canvas_height, height, iter->y_offset, config.input.height, &y, &h);
  stride = width * channels;
  bytes = stride * height;
  offset = (size_t)y * stride + (size_t)x * channels;
  if (!(image->pixels = calloc(bytes, 1)))
    return "image is too large";
  config.output.colorspace = channels == 4 ? MODE_RGBA : MODE_RGB;
  config.output.is_external_memory = 1;
  config.output.u.RGBA.rgba = image->pixels + offset;
  config.output.u.RGBA.stride = (int)stride;
  config.output.u.RGBA.size = bytes - offset;
  if (w != config.input.width || h != config.input.height) {
    config.options.use_scaling = 1;
    config.options.scaled_width = w;
    config.options.scaled_height = h;
  }
  if ((status = WebPDecode(iter->fragment.bytes, iter->fragment.size, &config)) != VP8_STATUS_OK)
    return status_error(status);
  return NULL;
}

const char *webp_decode(const uint8_t *data, size_t size, uint32_t width, uint32_t height, Image *image)
{
  WebPDemuxer *demux;
  WebPIterator iter;
  uint32_t canvas_width, canvas_height;
  int animated;
  const char *error = open_demuxer(data, size, &demux, &canvas_width, &canvas_height);

  if (!error && ((uint64_t)width * MAX_SCALE_DOWN < canvas_width || width > canvas_width || (uint64_t)height * MAX_SCALE_DOWN < canvas_height ||
                 height > canvas_height))
    error = "invalid decode options";
  if (!error) {
    animated = (WebPDemuxGetI(demux, WEBP_FF_FORMAT_FLAGS) & ANIMATION_FLAG) != 0;
    if (!WebPDemuxGetFrame(demux, 1, &iter)) {
      error = "invalid WebP container";
    } else {
      error = decode_frame(&iter, canvas_width, canvas_height, width, height, animated, image);
      WebPDemuxReleaseIterator(&iter);
    }
  }
  if (!error) {
    read_chunk(demux, "ICCP", &image->icc, &image->icc_size);
    read_chunk(demux, "EXIF", &image->exif, &image->exif_size);
  }
  WebPDemuxDelete(demux);
  return error;
}

typedef struct {
  WebPAnimDecoder *decoder;
  uint32_t timestamp;
} Animated;

static void rewind_animation(void *state)
{
  Animated *animated = state;

  WebPAnimDecoderReset(animated->decoder);
  animated->timestamp = 0;
}

static const char *next_frame(void *state, const uint8_t **canvas, uint32_t *duration)
{
  Animated *animated = state;
  uint8_t *pixels;
  int timestamp;

  if (!WebPAnimDecoderHasMoreFrames(animated->decoder))
    rewind_animation(animated);
  if (!WebPAnimDecoderGetNext(animated->decoder, &pixels, &timestamp))
    return "invalid WebP frame";
  *duration = (uint32_t)timestamp - animated->timestamp;
  animated->timestamp = (uint32_t)timestamp;
  *canvas = pixels;
  return NULL;
}

static void close_animation(void *state)
{
  Animated *animated = state;

  WebPAnimDecoderDelete(animated->decoder);
  free(animated);
}

const char *webp_animation(const uint8_t *data, size_t size, Animation *animation, Image *metadata)
{
  WebPData input = {data, size};
  WebPAnimDecoderOptions options;
  WebPAnimInfo info;
  Animated *animated;

  if (!WebPAnimDecoderOptionsInit(&options))
    return status_error(VP8_STATUS_INVALID_PARAM);
  options.color_mode = MODE_rgbA;
  if (!(animated = calloc(1, sizeof(*animated))))
    return "image is too large";
  if (!(animated->decoder = WebPAnimDecoderNew(&input, &options)) || !WebPAnimDecoderGetInfo(animated->decoder, &info)) {
    close_animation(animated);
    return "invalid WebP container";
  }
  read_chunk(WebPAnimDecoderGetDemuxer(animated->decoder), "ICCP", &metadata->icc, &metadata->icc_size);
  read_chunk(WebPAnimDecoderGetDemuxer(animated->decoder), "EXIF", &metadata->exif, &metadata->exif_size);
  animation->state = animated;
  animation->width = info.canvas_width;
  animation->height = info.canvas_height;
  animation->next = next_frame;
  animation->rewind = rewind_animation;
  animation->close = close_animation;
  return NULL;
}
