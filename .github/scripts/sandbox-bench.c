#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sandbox.h"
#ifndef SANDBOX
#include "guest.h"
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
  return layout == 1 ? 1 : layout == 2 ? 3 : 4;
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
  if (format == 1) {
    d = 1u << (halvings < 3 ? halvings : 3);
    *w = (width + d - 1) / d;
    *h = (height + d - 1) / d;
  }
}

#ifdef SANDBOX
static void decode(const uint8_t *data, size_t size, uint32_t max_side, Result *r)
{
  sandbox *session = NULL;
  sandbox_header header;
  sandbox_image image;
  uint32_t w, h;

  memset(r, 0, sizeof(*r));
  r->status = sandbox_open(data, size, call_limits(sandbox_now_ns()), &session, &header);
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
  sandbox_close(session);
}
#else
const char *guest_message(const char *text)
{
  static char message[SANDBOX_MESSAGE_SIZE];

  strncpy(message, text, sizeof(message) - 1);
  return message;
}

static void decode(const uint8_t *data, size_t size, uint32_t max_side, Result *r)
{
  Image image = {0};
  const char *error;
  uint32_t w, h;

  memset(r, 0, sizeof(*r));
  r->format = size >= 2 && data[0] == 0xFF && data[1] == 0xD8 ? 1 : size >= 8 && !memcmp(data, "\x89PNG", 4) ? 2 : 3;
  error = r->format == 1 ? jpeg_header(data, size, &r->image_width, &r->image_height)
          : r->format == 2 ? png_header(data, size, &r->image_width, &r->image_height)
                           : webp_header(data, size, &r->image_width, &r->image_height);
  if (!error) {
    output_size(r->format, r->image_width, r->image_height, max_side, &w, &h);
    error = r->format == 1 ? jpeg_decode(data, size, w, h, (uint32_t)(limits.memory_limit >> 20), &image)
            : r->format == 2 ? png_decode(data, size, w, h, &image)
                             : webp_decode(data, size, w, h, &image);
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
  if (r->format == 2)
    free((void *)image.icc);
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
    if (!(out = fopen(output, "wb")) || fprintf(out, "%d %u %u %u\n", r.status == 0 ? 0 : 1, r.width, r.height, r.channels) < 0 ||
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
        count_file(name, data, size * k / 32, max_side);
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
static void report_stops(const char *what, int repeat, double *elapsed, double *late, int *statuses, int expected)
{
  int i, unexpected = 0;

  for (i = 0; i < repeat; i++)
    unexpected += statuses[i] != expected;
  qsort(elapsed, repeat, sizeof(double), compare_doubles);
  qsort(late, repeat, sizeof(double), compare_doubles);
  printf("%s\tinterval %u\tstatus %d\t%d of %d with another status\telapsed ms median %.3f max %.3f\tafter the deadline ms median %.3f max %.3f\n", what,
         limits.check_interval, statuses[repeat - 1], unexpected, repeat, elapsed[repeat / 2] / 1e6, elapsed[repeat - 1] / 1e6, late[repeat / 2] / 1e6,
         late[repeat - 1] / 1e6);
}

static void stop(const char *what, int repeat, const char *path)
{
  double *elapsed = malloc(sizeof(double) * repeat), *late = malloc(sizeof(double) * repeat);
  int *statuses = malloc(sizeof(int) * repeat);
  char message[SANDBOX_MESSAGE_SIZE];
  unsigned char *data = NULL;
  size_t size = 0;
  uint64_t start, end;
  Result r;
  int i;

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
  report_stops(what, repeat, elapsed, late, statuses, deadline_ms ? SANDBOX_DEADLINE : SANDBOX_BUDGET);
  free(data);
  free(statuses);
  free(late);
  free(elapsed);
}

static void tree(uint32_t depth)
{
  char message[SANDBOX_MESSAGE_SIZE];
  uint64_t start = sandbox_now_ns();
  uint32_t value = 0;
  int status = sandbox_tree(call_limits(start), depth, &value, message);

  printf("tree of depth %u\tstatus %d\t%s\telapsed ms %.3f\n", depth, status, message, (sandbox_now_ns() - start) / 1e6);
}
#endif

int main(int argc, char **argv)
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
#ifdef SANDBOX
  if (argc == 3 && !strcmp(argv[1], "spin")) {
    stop("spin", atoi(argv[2]), NULL);
    return 0;
  }
  if (argc == 4 && !strcmp(argv[1], "stop")) {
    stop(base_name(argv[3]), atoi(argv[2]), argv[3]);
    return 0;
  }
  if (argc == 3 && !strcmp(argv[1], "tree")) {
    tree((uint32_t)atoi(argv[2]));
    return 0;
  }
#endif
  fprintf(stderr, "usage: %s check DIR MAXSIDE FILE... | time REPEAT MAXSIDE FILE... | count MAXSIDE FILE... | count-changed MAXSIDE FILE... | spin REPEAT | "
                  "stop REPEAT FILE | tree DEPTH\n",
          argv[0]);
  return 2;
}
