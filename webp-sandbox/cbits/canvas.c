#include <stdlib.h>
#include "canvas.h"
#include "src/webp/decode.h"
#include "src/webp/demux.h"

#define MAX_BYTES (512u << 20)

static int scaled_start(int offset, int side, int scaled_side)
{
  return (int)((long long)offset * scaled_side / side);
}

static int scaled_end(int end, int side, int scaled_side)
{
  return (int)(((long long)end * scaled_side + side - 1) / side);
}

int webp_canvas_features(const unsigned char *webp, size_t size, Features *features)
{
  WebPData data = {webp, size};
  WebPDemuxer *demux = WebPDemux(&data);
  WebPIterator iter;
  WebPBitstreamFeatures frame;
  int animated, rc = VP8_STATUS_BITSTREAM_ERROR;

  features->canvas_width = features->canvas_height = features->frame_width = features->frame_height = features->channels = 0;
  if (!demux)
    return rc;
  features->canvas_width = WebPDemuxGetI(demux, WEBP_FF_CANVAS_WIDTH);
  features->canvas_height = WebPDemuxGetI(demux, WEBP_FF_CANVAS_HEIGHT);
  animated = (WebPDemuxGetI(demux, WEBP_FF_FORMAT_FLAGS) & ANIMATION_FLAG) != 0;
  if (features->canvas_width <= WEBP_MAX_SIDE && features->canvas_height <= WEBP_MAX_SIDE && WebPDemuxGetFrame(demux, 1, &iter)) {
    if ((rc = WebPGetFeatures(iter.fragment.bytes, iter.fragment.size, &frame)) == VP8_STATUS_OK) {
      features->frame_width = frame.width;
      features->frame_height = frame.height;
      features->channels = animated || frame.has_alpha ? 4 : 3;
    }
    WebPDemuxReleaseIterator(&iter);
  }
  WebPDemuxDelete(demux);
  return rc;
}

int webp_canvas_decode(const unsigned char *webp, size_t size, int max_side, Canvas *canvas)
{
  WebPData data = {webp, size};
  WebPDemuxer *demux = WebPDemux(&data);
  WebPIterator iter;
  WebPDecoderConfig config;
  size_t stride, offset;
  int width, height, x, y, w, h, animated, rc = VP8_STATUS_BITSTREAM_ERROR;

  canvas->pixels = NULL;
  canvas->width = canvas->height = canvas->channels = 0;
  if (!demux)
    return rc;
  width = canvas->width = WebPDemuxGetI(demux, WEBP_FF_CANVAS_WIDTH);
  height = canvas->height = WebPDemuxGetI(demux, WEBP_FF_CANVAS_HEIGHT);
  while ((canvas->width > max_side || canvas->height > max_side) && canvas->width > 1 && canvas->height > 1) {
    canvas->width = (canvas->width + 1) / 2;
    canvas->height = (canvas->height + 1) / 2;
  }
  animated = (WebPDemuxGetI(demux, WEBP_FF_FORMAT_FLAGS) & ANIMATION_FLAG) != 0;
  if (width <= WEBP_MAX_SIDE && height <= WEBP_MAX_SIDE && WebPDemuxGetFrame(demux, 1, &iter)) {
    if (WebPInitDecoderConfig(&config) &&
        (rc = WebPGetFeatures(iter.fragment.bytes, iter.fragment.size, &config.input)) == VP8_STATUS_OK) {
      canvas->channels = animated || config.input.has_alpha ? 4 : 3;
      x = scaled_start(iter.x_offset, width, canvas->width);
      y = scaled_start(iter.y_offset, height, canvas->height);
      w = scaled_end(iter.x_offset + config.input.width, width, canvas->width) - x;
      h = scaled_end(iter.y_offset + config.input.height, height, canvas->height) - y;
      stride = (size_t)canvas->width * canvas->channels;
      offset = (size_t)y * stride + (size_t)x * canvas->channels;
      rc = VP8_STATUS_OUT_OF_MEMORY;
      if (stride * canvas->height <= MAX_BYTES && (canvas->pixels = calloc(stride, canvas->height))) {
        config.output.colorspace = canvas->channels == 4 ? MODE_RGBA : MODE_RGB;
        config.output.is_external_memory = 1;
        config.output.u.RGBA.rgba = canvas->pixels + offset;
        config.output.u.RGBA.stride = (int)stride;
        config.output.u.RGBA.size = stride * canvas->height - offset;
        if (w != config.input.width || h != config.input.height) {
          config.options.use_scaling = 1;
          config.options.scaled_width = w;
          config.options.scaled_height = h;
        }
        rc = WebPDecode(iter.fragment.bytes, iter.fragment.size, &config);
      }
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
