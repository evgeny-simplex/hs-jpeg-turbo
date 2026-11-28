#ifndef SANDBOX_H
#define SANDBOX_H

#include <stddef.h>
#include <stdint.h>

#define SANDBOX_TRAP (-1)
#define SANDBOX_INVALID_OUTPUT (-2)
#define SANDBOX_OUT_OF_MEMORY (-3)
#define SANDBOX_INVALID_ARGUMENT (-4)
#define SANDBOX_BUDGET (-5)
#define SANDBOX_DEADLINE (-6)
#define SANDBOX_DECODER (-7)
#define SANDBOX_MEMORY_LIMIT (-8)

#define SANDBOX_MAX_INTERVAL (1u << 30)

#define SANDBOX_MESSAGE_SIZE 256

enum { FORMAT_JPEG = 1, FORMAT_PNG = 2, FORMAT_WEBP = 3, FORMAT_GIF = 4 };

enum { LAYOUT_Y8 = 1, LAYOUT_RGB8 = 2, LAYOUT_RGBA8 = 3, LAYOUT_CMYK8 = 4 };

enum { PLAYBACK_STILL = 0, PLAYBACK_ANIMATION = 1 };

enum { PIXELS_RGBA = 0, PIXELS_BGRA = 1 };

typedef struct {
  uint64_t memory_limit;
  uint64_t deadline_ns;
  uint64_t budget_base;
  uint64_t budget_per_byte;
  uint32_t check_interval;
} sandbox_limits;

typedef struct {
  uint32_t format;
  uint32_t width;
  uint32_t height;
  uint32_t frames;
  uint32_t loops;
} sandbox_header;

typedef struct {
  uint8_t *pixels;
  uint32_t width;
  uint32_t height;
  uint32_t layout;
  uint8_t *icc;
  uint32_t icc_size;
  uint8_t *exif;
  uint32_t exif_size;
} sandbox_image;

typedef struct {
  uint32_t alpha;
  uint8_t *icc;
  uint32_t icc_size;
  uint8_t *exif;
  uint32_t exif_size;
} sandbox_frames;

typedef struct sandbox sandbox;

uint64_t sandbox_now_ns(void);

int sandbox_open(const uint8_t *data, size_t size, const sandbox_limits *limits, sandbox **session, sandbox_header *header);

int sandbox_decode(sandbox *session, uint32_t width, uint32_t height, uint64_t budget_per_pixel, sandbox_image *image);

int sandbox_start(sandbox *session, uint32_t width, uint32_t height, uint32_t playback, uint64_t deadline_ns, uint64_t budget_per_pixel,
                  sandbox_frames *frames);

int sandbox_next(sandbox *session, uint64_t deadline_ns, uint64_t budget_per_pixel, uint32_t order, uint8_t *pixels, size_t row_bytes,
                 uint32_t *duration);

void sandbox_rewind(sandbox *session);

void sandbox_close(sandbox *session);

const char *sandbox_message(const sandbox *session);

uint64_t sandbox_iterations(const sandbox *session);

uint64_t sandbox_memory_bytes(const sandbox *session);

int sandbox_load(const sandbox_limits *limits, uint32_t address, uint32_t *value, char *message);

int sandbox_spin(const sandbox_limits *limits, char *message);

int sandbox_tree(const sandbox_limits *limits, uint32_t depth, uint32_t *value, char *message);

int sandbox_read_header(const sandbox_limits *limits, uint32_t address, const uint8_t *data, uint32_t length, sandbox_header *header, char *message);

int sandbox_read_output(const sandbox_limits *limits, uint32_t size, uint32_t format, uint32_t width, uint32_t height, uint32_t address,
                        const uint8_t *data, uint32_t length, char *message);

int sandbox_read_start(const sandbox_limits *limits, uint32_t size, uint32_t address, const uint8_t *data, uint32_t length, char *message);

int sandbox_read_frame(const sandbox_limits *limits, uint32_t width, uint32_t height, uint32_t address, const uint8_t *data, uint32_t length,
                       char *message);

#endif
