#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sandbox.h"
#ifndef SANDBOX
#include "guest.h"
#endif
#ifndef _WIN32
#include <pthread.h>
#endif
#ifdef __linux__
#include <sys/resource.h>
#endif

typedef struct {
  uint8_t *pixels;
  uint32_t format, image_width, image_height, width, height, channels;
  uint64_t iterations, memory;
  int status;
  char message[SANDBOX_MESSAGE_SIZE];
} Result;

static sandbox_limits limits;
static uint64_t per_pixel, deadline_ms;

static uint64_t setting(const char *name, uint64_t fallback)
{
  const char *value = getenv(name);

  return value && *value ? strtoull(value, NULL, 10) : fallback;
}

static void read_limits(void)
{
  limits.memory_limit = setting("SANDBOX_MEMORY_MB", 256) << 20;
  limits.budget_base = setting("SANDBOX_BUDGET_BASE", 0);
  limits.budget_per_byte = setting("SANDBOX_BUDGET_PER_BYTE", 0);
  limits.check_interval = (uint32_t)setting("SANDBOX_INTERVAL", 4096);
  per_pixel = setting("SANDBOX_BUDGET_PER_PIXEL", 0);
  deadline_ms = setting("SANDBOX_DEADLINE_MS", 0);
}

static const sandbox_limits *call_limits(uint64_t start)
{
  limits.deadline_ns = deadline_ms ? start + deadline_ms * 1000000u : 0;
  return &limits;
}

static unsigned char *read_file(const char *path, size_t *size)
{
  FILE *in = fopen(path, "rb");
  unsigned char *bytes = NULL;
  long len;

  if (!in || fseek(in, 0, SEEK_END) != 0 || (len = ftell(in)) < 0 || fseek(in, 0, SEEK_SET) != 0 || !(bytes = malloc(len + 1)) ||
      fread(bytes, 1, len, in) != (size_t)len || fclose(in) != 0) {
    perror(path);
    exit(1);
  }
  *size = len;
  return bytes;
}

static const char *base_name(const char *path)
{
  return strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
}

static uint32_t layout_channels(uint32_t layout)
{
  return layout == LAYOUT_Y8 ? 1 : layout == LAYOUT_RGB8 ? 3 : 4;
}

static void output_size(uint32_t format, uint32_t width, uint32_t height, uint32_t max_side, uint32_t *w, uint32_t *h)
{
  uint32_t halvings = 0, d;

  *w = width;
  *h = height;
  while ((*w > max_side || *h > max_side) && *w > 1 && *h > 1) {
    *w = (*w + 1) / 2;
    *h = (*h + 1) / 2;
    halvings++;
  }
  if (format == FORMAT_JPEG) {
    d = 1u << (halvings < 3 ? halvings : 3);
    *w = (width + d - 1) / d;
    *h = (height + d - 1) / d;
  }
}

#ifdef SANDBOX
static sandbox *open_and_decode(const uint8_t *data, size_t size, uint32_t max_side, const sandbox_limits *session_limits, Result *r)
{
  sandbox *session = NULL;
  sandbox_header header;
  sandbox_image image;
  uint32_t w, h;

  memset(r, 0, sizeof(*r));
  r->status = sandbox_open(data, size, session_limits, &session, &header);
  if (r->status == 0) {
    r->format = header.format;
    r->image_width = header.width;
    r->image_height = header.height;
    output_size(header.format, header.width, header.height, max_side, &w, &h);
    r->status = sandbox_decode(session, w, h, per_pixel, &image);
    if (r->status == 0) {
      r->pixels = image.pixels;
      r->width = image.width;
      r->height = image.height;
      r->channels = layout_channels(image.layout);
      free(image.icc);
      free(image.exif);
    }
  }
  if (session) {
    if (r->status != 0)
      strncpy(r->message, sandbox_message(session), SANDBOX_MESSAGE_SIZE - 1);
    r->iterations = sandbox_iterations(session);
    r->memory = sandbox_memory_bytes(session);
  }
  return session;
}

static void decode(const uint8_t *data, size_t size, uint32_t max_side, Result *r)
{
  sandbox_close(open_and_decode(data, size, max_side, call_limits(sandbox_now_ns()), r));
}
#else
const char *guest_message(const char *text)
{
  static char message[SANDBOX_MESSAGE_SIZE];

  strncpy(message, text, sizeof(message) - 1);
  return message;
}

static uint32_t native_format(const uint8_t *data, size_t size)
{
  if (size >= 2 && data[0] == 0xFF && data[1] == 0xD8)
    return FORMAT_JPEG;
  if (size >= 8 && !memcmp(data, "\x89PNG", 4))
    return FORMAT_PNG;
  if (size >= 3 && !memcmp(data, "GIF", 3))
    return FORMAT_GIF;
  return FORMAT_WEBP;
}

static const char *native_header(uint32_t format, const uint8_t *data, size_t size, uint32_t *width, uint32_t *height, uint32_t *frames)
{
  uint32_t loops;

  *frames = 1;
  switch (format) {
  case FORMAT_JPEG:
    return jpeg_header(data, size, width, height);
  case FORMAT_PNG:
    return png_header(data, size, width, height);
  case FORMAT_GIF:
    return gif_header(data, size, width, height, frames, &loops);
  default:
    return webp_header(data, size, width, height, frames, &loops);
  }
}

static const char *native_decode(uint32_t format, const uint8_t *data, size_t size, uint32_t width, uint32_t height, Image *image)
{
  switch (format) {
  case FORMAT_JPEG:
    return jpeg_decode(data, size, width, height, (uint32_t)(limits.memory_limit >> 20), image);
  case FORMAT_PNG:
    return png_decode(data, size, width, height, image);
  case FORMAT_GIF:
    return gif_decode(data, size, width, height, image);
  default:
    return webp_decode(data, size, width, height, image);
  }
}

static void decode(const uint8_t *data, size_t size, uint32_t max_side, Result *r)
{
  Image image = {0};
  const char *error;
  uint32_t w, h, frames;

  memset(r, 0, sizeof(*r));
  r->format = native_format(data, size);
  error = native_header(r->format, data, size, &r->image_width, &r->image_height, &frames);
  if (!error) {
    output_size(r->format, r->image_width, r->image_height, max_side, &w, &h);
    error = native_decode(r->format, data, size, w, h, &image);
    r->width = w;
    r->height = h;
  }
  if (error) {
    r->status = SANDBOX_DECODER;
    strncpy(r->message, error, SANDBOX_MESSAGE_SIZE - 1);
    free(image.pixels);
    return;
  }
  r->pixels = image.pixels;
  r->channels = layout_channels(image.layout);
  if (r->format == FORMAT_PNG)
    free((void *)image.icc);
}
#endif

typedef struct {
#ifdef SANDBOX
  sandbox *session;
  uint64_t opened;
#endif
  uint32_t format, image_width, image_height, frames, width, height;
  int status;
  char message[SANDBOX_MESSAGE_SIZE];
} Animated;

static uint64_t call_deadline(void)
{
  return deadline_ms ? sandbox_now_ns() + deadline_ms * 1000000u : 0;
}

#ifdef SANDBOX
static int session_status(Animated *a)
{
  if (a->status != 0 && a->session)
    strncpy(a->message, sandbox_message(a->session), SANDBOX_MESSAGE_SIZE - 1);
  return a->status;
}

static int open_frames(const uint8_t *data, size_t size, uint32_t max_side, Animated *a)
{
  sandbox_header header;
  sandbox_frames info;

  memset(a, 0, sizeof(*a));
  a->status = sandbox_open(data, size, call_limits(sandbox_now_ns()), &a->session, &header);
  if (a->status == 0) {
    a->opened = sandbox_iterations(a->session);
    a->format = header.format;
    a->image_width = header.width;
    a->image_height = header.height;
    a->frames = header.frames;
    output_size(header.format, header.width, header.height, max_side, &a->width, &a->height);
    a->status = sandbox_start(a->session, a->width, a->height, header.frames > 1 ? PLAYBACK_ANIMATION : PLAYBACK_STILL, call_deadline(), per_pixel,
                              &info);
    free(info.icc);
    free(info.exif);
  }
  return session_status(a);
}

static int read_frame(Animated *a, uint8_t *pixels, uint32_t *duration)
{
  a->status = sandbox_next(a->session, call_deadline(), per_pixel, PIXELS_RGBA, pixels, (size_t)a->width * 4, duration);
  return session_status(a);
}

static void close_frames(Animated *a)
{
  sandbox_close(a->session);
}
#else
static int native_status(Animated *a, const char *error)
{
  if (error) {
    a->status = SANDBOX_DECODER;
    strncpy(a->message, error, SANDBOX_MESSAGE_SIZE - 1);
  }
  return a->status;
}

static int open_frames(const uint8_t *data, size_t size, uint32_t max_side, Animated *a)
{
  Image image = {0};
  const char *error;

  memset(a, 0, sizeof(*a));
  a->format = native_format(data, size);
  error = native_header(a->format, data, size, &a->image_width, &a->image_height, &a->frames);
  if (!error) {
    output_size(a->format, a->image_width, a->image_height, max_side, &a->width, &a->height);
    if (a->frames > 1) {
      error = frames_animate(data, size, a->format, a->width, a->height, &image);
    } else {
      if (!(error = native_decode(a->format, data, size, a->width, a->height, &image)))
        error = frames_still(&image, a->width, a->height);
      free(image.pixels);
      if (a->format == FORMAT_PNG)
        free((void *)image.icc);
    }
  }
  return native_status(a, error);
}

static int read_frame(Animated *a, uint8_t *pixels, uint32_t *duration)
{
  const uint8_t *frame;
  const char *error = frames_next(0, &frame, duration);

  if (!error)
    memcpy(pixels, frame, (size_t)a->width * a->height * 4);
  return native_status(a, error);
}

static void close_frames(Animated *a)
{
  (void)a;
  frames_close();
}
#endif

static void frame_path(char *output, size_t size, const char *dir, const char *path, uint32_t frame)
{
  const char *name = base_name(path), *dot = strrchr(name, '.');

  snprintf(output, size, "%s/%.*s-frame%u%s.out", dir, dot ? (int)(dot - name) : (int)strlen(name), name, frame, dot ? dot : "");
}

static void check_frames(const char *dir, uint32_t max_side, int count, char **paths)
{
  char output[4096];
  size_t size;
  unsigned char *data;
  uint8_t *pixels;
  uint32_t frame, duration;
  Animated a;
  FILE *out;
  int i;

  for (i = 0; i < count; i++) {
    data = read_file(paths[i], &size);
    open_frames(data, size, max_side, &a);
    pixels = malloc(a.status == 0 ? (size_t)a.width * a.height * 4 : 1);
    for (frame = 0; frame == 0 || (a.status == 0 && frame < a.frames); frame++) {
      duration = 0;
      if (a.status == 0)
        read_frame(&a, pixels, &duration);
      frame_path(output, sizeof(output), dir, paths[i], frame);
      if (!(out = fopen(output, "wb")) || fprintf(out, "%d %u %u 4 %u\n", a.status, a.width, a.height, duration) < 0 ||
          (a.status == 0 && fwrite(pixels, (size_t)a.width * 4, a.height, out) != a.height) || fclose(out) != 0) {
        perror(output);
        exit(1);
      }
    }
    close_frames(&a);
    free(pixels);
    free(data);
  }
}

static int compare_doubles(const void *a, const void *b);

static void time_frames(int repeat, uint32_t max_side, int count, char **paths)
{
  double *totals = malloc(sizeof(double) * repeat), *slowest = malloc(sizeof(double) * repeat);
  size_t size;
  unsigned char *data;
  uint8_t *pixels;
  uint64_t start, frame_start;
  uint32_t frame, duration;
  Animated a;
  int i, k;

  for (k = 0; k < count; k++) {
    data = read_file(paths[k], &size);
    for (i = 0; i < repeat; i++) {
      start = sandbox_now_ns();
      slowest[i] = 0;
      open_frames(data, size, max_side, &a);
      pixels = malloc(a.status == 0 ? (size_t)a.width * a.height * 4 : 1);
      for (frame = 0; a.status == 0 && frame < a.frames; frame++) {
        frame_start = sandbox_now_ns();
        read_frame(&a, pixels, &duration);
        __asm__ volatile("" : : "r"(pixels) : "memory");
        if ((double)(sandbox_now_ns() - frame_start) > slowest[i])
          slowest[i] = (double)(sandbox_now_ns() - frame_start);
      }
      totals[i] = (double)(sandbox_now_ns() - start);
      close_frames(&a);
      free(pixels);
    }
    qsort(totals, repeat, sizeof(double), compare_doubles);
    qsort(slowest, repeat, sizeof(double), compare_doubles);
    printf("%s\t%u\t%u\t%u\t%u\t%u\t%u\t%zu\t%.0f\t%.0f\t%d\t%s\n", base_name(paths[k]), a.format, a.image_width, a.image_height, a.frames, a.width,
           a.height, size, totals[repeat / 2], slowest[repeat / 2], a.status, a.message);
    free(data);
  }
  free(slowest);
  free(totals);
}

#ifdef SANDBOX
static void count_frames_of(const char *name, const unsigned char *data, size_t size, uint32_t max_side)
{
  uint8_t *pixels;
  uint64_t before, start = sandbox_now_ns();
  uint32_t frame, duration;
  Animated a;

  open_frames(data, size, max_side, &a);
  printf("%s#start\t%u\t%u\t%zu\t%llu\t%llu\t%d\t%llu\t%llu\t%s\n", name, a.format, max_side, size, (unsigned long long)a.image_width * a.image_height,
         (unsigned long long)a.width * a.height, a.status, (unsigned long long)(a.session ? sandbox_iterations(a.session) - a.opened : 0),
         (unsigned long long)(sandbox_now_ns() - start), a.message);
  pixels = malloc(a.status == 0 ? (size_t)a.width * a.height * 4 : 1);
  for (frame = 0; a.status == 0 && frame < a.frames; frame++) {
    before = sandbox_iterations(a.session);
    start = sandbox_now_ns();
    read_frame(&a, pixels, &duration);
    printf("%s#frame%u\t%u\t%u\t%zu\t%llu\t%llu\t%d\t%llu\t%llu\t%s\n", name, frame, a.format, max_side, size, (unsigned long long)a.image_width * a.image_height,
           (unsigned long long)a.width * a.height, a.status, (unsigned long long)(sandbox_iterations(a.session) - before),
           (unsigned long long)(sandbox_now_ns() - start), a.message);
  }
  close_frames(&a);
  free(pixels);
}

static void count_frames(uint32_t max_side, int changed, int count, char **paths)
{
  char name[4200];
  size_t size, k;
  unsigned char *data, *copy;
  int i;

  for (i = 0; i < count; i++) {
    data = read_file(paths[i], &size);
    if (!changed) {
      count_frames_of(base_name(paths[i]), data, size, max_side);
    } else {
      copy = malloc(size ? size : 1);
      for (k = 0; k < 32; k++) {
        snprintf(name, sizeof(name), "%s#truncated%zu", base_name(paths[i]), k);
        count_frames_of(name, k ? data : NULL, size * k / 32, max_side);
        memcpy(copy, data, size);
        copy[(size - 1) * k / 31] ^= (unsigned char)(1u << (k % 8));
        snprintf(name, sizeof(name), "%s#changed%zu", base_name(paths[i]), k);
        count_frames_of(name, copy, size, max_side);
      }
      free(copy);
    }
    free(data);
  }
}
#endif

static int compare_doubles(const void *a, const void *b)
{
  const double x = *(const double *)a, y = *(const double *)b;

  return (x > y) - (x < y);
}

static void check(const char *dir, uint32_t max_side, int count, char **paths)
{
  char output[4096];
  size_t size;
  unsigned char *data;
  Result r;
  FILE *out;
  int k;

  for (k = 0; k < count; k++) {
    data = read_file(paths[k], &size);
    decode(data, size, max_side, &r);
    snprintf(output, sizeof(output), "%s/%s.out", dir, base_name(paths[k]));
    if (!(out = fopen(output, "wb")) || fprintf(out, "%d %u %u %u\n", r.status, r.width, r.height, r.channels) < 0 ||
        (r.status == 0 && fwrite(r.pixels, (size_t)r.width * r.channels, r.height, out) != r.height) || fclose(out) != 0) {
      perror(output);
      exit(1);
    }
    free(r.pixels);
    free(data);
  }
}

static void time_files(int repeat, uint32_t max_side, int count, char **paths)
{
  double *times = malloc(sizeof(double) * repeat);
  size_t size;
  unsigned char *data;
  uint64_t start;
  Result r;
  int i, k;

  for (k = 0; k < count; k++) {
    data = read_file(paths[k], &size);
    for (i = 0; i < repeat; i++) {
      start = sandbox_now_ns();
      decode(data, size, max_side, &r);
      times[i] = (double)(sandbox_now_ns() - start);
      free(r.pixels);
      if (r.status != 0) {
        fprintf(stderr, "%s: status %d %s\n", paths[k], r.status, r.message);
        exit(1);
      }
    }
    qsort(times, repeat, sizeof(double), compare_doubles);
    printf("%s\t%u\t%u\t%u\t%u\t%u\t%zu\t%.0f\t%.0f\t%llu\t%llu\n", base_name(paths[k]), r.image_width, r.image_height, r.width, r.height, r.channels,
           size, times[0], times[repeat / 2], (unsigned long long)r.memory, (unsigned long long)r.iterations);
    free(data);
  }
  free(times);
}

static void count_file(const char *name, const unsigned char *data, size_t size, uint32_t max_side)
{
  Result r;
  uint64_t start = sandbox_now_ns();

  decode(data, size, max_side, &r);
  printf("%s\t%u\t%u\t%zu\t%llu\t%llu\t%d\t%llu\t%llu\t%s\n", name, r.format, max_side, size, (unsigned long long)r.image_width * r.image_height,
         (unsigned long long)r.width * r.height, r.status, (unsigned long long)r.iterations, (unsigned long long)(sandbox_now_ns() - start),
         r.message);
  free(r.pixels);
}

static void count_files(uint32_t max_side, int changed, int count, char **paths)
{
  char name[4200];
  size_t size, k;
  unsigned char *data, *copy;
  int i;

  for (i = 0; i < count; i++) {
    data = read_file(paths[i], &size);
    if (!changed) {
      count_file(base_name(paths[i]), data, size, max_side);
    } else {
      copy = malloc(size ? size : 1);
      for (k = 0; k < 32; k++) {
        snprintf(name, sizeof(name), "%s#truncated%zu", base_name(paths[i]), k);
        count_file(name, k ? data : NULL, size * k / 32, max_side);
        memcpy(copy, data, size);
        copy[(size - 1) * k / 31] ^= (unsigned char)(1u << (k % 8));
        snprintf(name, sizeof(name), "%s#changed%zu", base_name(paths[i]), k);
        count_file(name, copy, size, max_side);
      }
      free(copy);
    }
    free(data);
  }
}

#ifdef SANDBOX
static int report_stops(const char *what, int repeat, double *elapsed, double *late, int *statuses, int expected)
{
  int i, unexpected = 0;

  for (i = 0; i < repeat; i++)
    unexpected += statuses[i] != expected;
  qsort(elapsed, repeat, sizeof(double), compare_doubles);
  qsort(late, repeat, sizeof(double), compare_doubles);
  printf("%s\tinterval %u\tstatus %d\t%d of %d with another status\telapsed ms median %.3f max %.3f\tafter the deadline ms median %.3f max %.3f\n", what,
         limits.check_interval, statuses[repeat - 1], unexpected, repeat, elapsed[repeat / 2] / 1e6, elapsed[repeat - 1] / 1e6, late[repeat / 2] / 1e6,
         late[repeat - 1] / 1e6);
  return unexpected;
}

static int stop(const char *what, int repeat, const char *path)
{
  double *elapsed = malloc(sizeof(double) * repeat), *late = malloc(sizeof(double) * repeat);
  int *statuses = malloc(sizeof(int) * repeat);
  char message[SANDBOX_MESSAGE_SIZE];
  unsigned char *data = NULL;
  size_t size = 0;
  uint64_t start, end;
  Result r;
  int i, unexpected;

  if (path)
    data = read_file(path, &size);
  for (i = 0; i < repeat; i++) {
    start = sandbox_now_ns();
    if (path) {
      decode(data, size, 4320, &r);
      free(r.pixels);
      statuses[i] = r.status;
    } else {
      statuses[i] = sandbox_spin(call_limits(start), message);
    }
    end = sandbox_now_ns();
    elapsed[i] = (double)(end - start);
    late[i] = deadline_ms ? (double)end - (double)(start + deadline_ms * 1000000u) : 0;
  }
  unexpected = report_stops(what, repeat, elapsed, late, statuses, deadline_ms ? SANDBOX_DEADLINE : SANDBOX_BUDGET);
  free(data);
  free(statuses);
  free(late);
  free(elapsed);
  return unexpected;
}

static int tree(uint32_t depth, const char *expected)
{
  char message[SANDBOX_MESSAGE_SIZE];
  uint64_t start = sandbox_now_ns();
  uint32_t value = 0;
  int status = sandbox_tree(call_limits(start), depth, &value, message);

  printf("tree of depth %u\tstatus %d\t%s\telapsed ms %.3f\n", depth, status, message, (sandbox_now_ns() - start) / 1e6);
  return strcmp(message, expected) != 0;
}

static int limit(void)
{
  sandbox_limits large = limits;
  char message[SANDBOX_MESSAGE_SIZE];
  uint32_t value = 0;
  int status;

  large.memory_limit = (uint64_t)PTRDIFF_MAX + 1;
  status = sandbox_load(&large, 0, &value, message);
  printf("memory limit of %llu bytes, above PTRDIFF_MAX\tstatus %d\n", (unsigned long long)large.memory_limit, status);
  return status != SANDBOX_INVALID_ARGUMENT;
}

#ifdef __linux__
static uint64_t data_bytes(void)
{
  FILE *status = fopen("/proc/self/status", "r");
  char line[256];
  unsigned long long kib = 0;

  while (status && fgets(line, sizeof(line), status))
    if (sscanf(line, "VmData: %llu kB", &kib) == 1)
      break;
  if (status)
    fclose(status);
  return (uint64_t)kib << 10;
}

static int memory(const char *failure, const char *path)
{
  sandbox_limits session_limits = limits;
  struct rlimit initial, limited;
  size_t size;
  unsigned char *data = read_file(path, &size);
  Result full, r;
  sandbox *session = open_and_decode(data, size, 16384, &limits, &full);
  int expected = SANDBOX_OUT_OF_MEMORY, grown = 0, failed;

  getrlimit(RLIMIT_DATA, &initial);
  limited = initial;
  if (!strcmp(failure, "limit")) {
    session_limits.memory_limit = full.memory / 2;
    expected = SANDBOX_MEMORY_LIMIT;
  } else if (!strcmp(failure, "growth")) {
    limited.rlim_cur = data_bytes() + full.memory / 2;
  } else if (!strcmp(failure, "copy")) {
    limited.rlim_cur = data_bytes() + full.memory + (uint64_t)full.width * full.height * full.channels / 2;
    grown = 1;
  }
  setrlimit(RLIMIT_DATA, &limited);
  sandbox_close(open_and_decode(data, size, 16384, &session_limits, &r));
  setrlimit(RLIMIT_DATA, &initial);
  failed = full.status != 0 || r.status != expected || (r.memory == full.memory) != grown;
  printf("memory %s\t%s\tstatus %d %s\tlinear memory %llu of %llu bytes\n", failure, base_name(path), r.status, r.message, (unsigned long long)r.memory,
         (unsigned long long)full.memory);
  free(r.pixels);
  free(full.pixels);
  sandbox_close(session);
  free(data);
  return failed;
}
#endif

#ifndef _WIN32
typedef struct {
  const uint8_t *data;
  size_t size;
  Result result;
} Job;

static pthread_mutex_t jobs_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t jobs_decoded = PTHREAD_COND_INITIALIZER;
static int jobs_left;

static void wait_for_jobs(int finished)
{
  pthread_mutex_lock(&jobs_lock);
  jobs_left -= finished;
  if (jobs_left == 0)
    pthread_cond_broadcast(&jobs_decoded);
  while (jobs_left > 0)
    pthread_cond_wait(&jobs_decoded, &jobs_lock);
  pthread_mutex_unlock(&jobs_lock);
}

static void *decode_job(void *argument)
{
  Job *job = argument;
  sandbox *session = open_and_decode(job->data, job->size, 4320, &limits, &job->result);

  wait_for_jobs(1);
  free(job->result.pixels);
  sandbox_close(session);
  return NULL;
}

static int concurrent(int threads, const char *path)
{
  Job *jobs = calloc(threads, sizeof(*jobs));
  pthread_t *ids = calloc(threads, sizeof(*ids));
  pthread_attr_t attributes;
  size_t size;
  unsigned char *data = read_file(path, &size);
  int i, started, decoded = 0, out_of_memory = 0;
  const char *other = "";

  if (threads < 1 || !jobs || !ids || pthread_attr_init(&attributes) || pthread_attr_setstacksize(&attributes, 1u << 20))
    return 1;
  jobs_left = threads;
  for (started = 0; started < threads; started++) {
    jobs[started].data = data;
    jobs[started].size = size;
    if (pthread_create(&ids[started], &attributes, decode_job, &jobs[started]))
      break;
  }
  wait_for_jobs(threads - started);
  for (i = 0; i < started; i++) {
    pthread_join(ids[i], NULL);
    if (jobs[i].result.status == 0)
      decoded++;
    else if (jobs[i].result.status == SANDBOX_OUT_OF_MEMORY)
      out_of_memory++;
    else
      other = jobs[i].result.message;
  }
  printf("%s\t%d decodes at once, %llu MiB each, %u-bit pointers\t%d started\t%d decoded\t%d out of memory\t%d other %s\n", base_name(path), threads,
         (unsigned long long)(limits.memory_limit >> 20), (unsigned)(sizeof(void *) * 8), started, decoded, out_of_memory, started - decoded - out_of_memory,
         other);
  free(data);
  free(ids);
  free(jobs);
  return 0;
}
#endif
#endif

static int run(int argc, char **argv)
{
  read_limits();
  if (argc >= 4 && !strcmp(argv[1], "check")) {
    check(argv[2], (uint32_t)atoi(argv[3]), argc - 4, argv + 4);
    return 0;
  }
  if (argc >= 4 && !strcmp(argv[1], "time")) {
    time_files(atoi(argv[2]), (uint32_t)atoi(argv[3]), argc - 4, argv + 4);
    return 0;
  }
  if (argc >= 3 && !strcmp(argv[1], "count")) {
    count_files((uint32_t)atoi(argv[2]), 0, argc - 3, argv + 3);
    return 0;
  }
  if (argc >= 3 && !strcmp(argv[1], "count-changed")) {
    count_files((uint32_t)atoi(argv[2]), 1, argc - 3, argv + 3);
    return 0;
  }
  if (argc >= 4 && !strcmp(argv[1], "frames")) {
    check_frames(argv[2], (uint32_t)atoi(argv[3]), argc - 4, argv + 4);
    return 0;
  }
  if (argc >= 4 && !strcmp(argv[1], "frames-time")) {
    time_frames(atoi(argv[2]), (uint32_t)atoi(argv[3]), argc - 4, argv + 4);
    return 0;
  }
#ifdef SANDBOX
  if (argc >= 3 && !strcmp(argv[1], "frames-count")) {
    count_frames((uint32_t)atoi(argv[2]), 0, argc - 3, argv + 3);
    return 0;
  }
  if (argc >= 3 && !strcmp(argv[1], "frames-count-changed")) {
    count_frames((uint32_t)atoi(argv[2]), 1, argc - 3, argv + 3);
    return 0;
  }
  if (argc == 3 && !strcmp(argv[1], "spin"))
    return stop("spin", atoi(argv[2]), NULL) != 0;
  if (argc == 4 && !strcmp(argv[1], "stop"))
    return stop(base_name(argv[3]), atoi(argv[2]), argv[3]) != 0;
  if (argc == 4 && !strcmp(argv[1], "tree"))
    return tree((uint32_t)atoi(argv[2]), argv[3]);
  if (argc == 2 && !strcmp(argv[1], "limit"))
    return limit();
#ifdef __linux__
  if (argc == 4 && !strcmp(argv[1], "memory"))
    return memory(argv[2], argv[3]);
#endif
#ifndef _WIN32
  if (argc == 4 && !strcmp(argv[1], "concurrent"))
    return concurrent(atoi(argv[2]), argv[3]);
#endif
#endif
  fprintf(stderr, "usage: %s check DIR MAXSIDE FILE... | time REPEAT MAXSIDE FILE... | count MAXSIDE FILE... | count-changed MAXSIDE FILE... | "
                  "frames DIR MAXSIDE FILE... | frames-time REPEAT MAXSIDE FILE... | frames-count MAXSIDE FILE... | frames-count-changed MAXSIDE FILE... | "
                  "spin REPEAT | "
                  "stop REPEAT FILE | tree DEPTH MESSAGE | limit | memory limit|growth|copy FILE | concurrent THREADS FILE\n",
          argv[0]);
  return 2;
}

typedef struct {
  int argc;
  char **argv;
  int status;
} Command;

static void *run_command(void *argument)
{
  Command *command = argument;

  command->status = run(command->argc, command->argv);
  return NULL;
}

int main(int argc, char **argv)
{
  Command command = {argc, argv, 2};
#ifndef _WIN32
  const uint64_t stack_kb = setting("SANDBOX_STACK_KB", 0);
  pthread_attr_t attributes;
  pthread_t thread;

  if (stack_kb) {
    if (pthread_attr_init(&attributes) || pthread_attr_setstacksize(&attributes, (size_t)stack_kb << 10) ||
        pthread_create(&thread, &attributes, run_command, &command) || pthread_join(thread, NULL)) {
      fprintf(stderr, "%s: no thread with a stack of %llu KiB\n", argv[0], (unsigned long long)stack_kb);
      return 1;
    }
    return command.status;
  }
#endif
  run_command(&command);
  return command.status;
}
