#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sandbox.h"

typedef struct {
  int runs, decoded, trapped, other;
} Counts;

static webp_limits limits;

static uint64_t deadline_ms;

static uint64_t setting(const char *name, uint64_t fallback)
{
  const char *value = getenv(name);

  return value && *value ? strtoull(value, NULL, 10) : fallback;
}

static void read_limits(void)
{
  limits.memory_limit = setting("WEBP_MEMORY_MB", 256) << 20;
  limits.budget_base = setting("WEBP_BUDGET_BASE", 0);
  limits.budget_per_byte = setting("WEBP_BUDGET_PER_BYTE", 0);
  limits.budget_per_pixel = setting("WEBP_BUDGET_PER_PIXEL", 0);
  limits.check_interval = (uint32_t)setting("WEBP_INTERVAL", 1u << 20);
  deadline_ms = setting("WEBP_DEADLINE_MS", 0);
}

static const webp_limits *call_limits(uint64_t start)
{
  limits.deadline_ns = deadline_ms ? start + deadline_ms * 1000000u : 0;
  return &limits;
}

static unsigned char *read_file(const char *path, size_t *size)
{
  FILE *in = fopen(path, "rb");
  unsigned char *bytes = NULL;
  long len;

  if (!in || fseek(in, 0, SEEK_END) != 0 || (len = ftell(in)) < 0 || fseek(in, 0, SEEK_SET) != 0 ||
      !(bytes = malloc(len + 1)) || fread(bytes, 1, len, in) != (size_t)len || fclose(in) != 0) {
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

static int decode(const unsigned char *webp, size_t size, int max_side, webp_result *result)
{
#ifdef SANDBOX
  return webp_sandbox_decode(webp, size, max_side, call_limits(webp_sandbox_now_ns()), result);
#else
  return webp_native_decode(webp, size, max_side, result);
#endif
}

static int compare_doubles(const void *a, const void *b)
{
  const double x = *(const double *)a, y = *(const double *)b;

  return (x > y) - (x < y);
}

static void write_netpbm(const char *dir, int max_side, const char *path)
{
  char output[4096];
  size_t size;
  unsigned char *webp = read_file(path, &size);
  webp_result r;
  int rc = decode(webp, size, max_side, &r);
  FILE *out;

  snprintf(output, sizeof(output), "%s/%s.%s", dir, base_name(path), rc ? "err" : r.channels == 4 ? "pam" : "ppm");
  if (!(out = fopen(output, "wb")) ||
      (rc ? fprintf(out, "status %d trap %u\n", rc, r.trap) < 0
          : (r.channels == 4
                 ? fprintf(out, "P7\nWIDTH %u\nHEIGHT %u\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n", r.width, r.height)
                 : fprintf(out, "P6\n%u %u\n255\n", r.width, r.height)) < 0 ||
                fwrite(r.pixels, (size_t)r.width * r.channels, r.height, out) != r.height) ||
      fclose(out) != 0) {
    perror(output);
    exit(1);
  }
  free(r.pixels);
  free(webp);
}

static void time_file(int repeat, const char *path)
{
  size_t size;
  unsigned char *webp = read_file(path, &size);
  double *times = malloc(sizeof(double) * repeat);
  uint64_t start;
  webp_result r;
  int i, rc = 0;

  for (i = 0; i < repeat; i++) {
    start = webp_sandbox_now_ns();
    rc = decode(webp, size, 16384, &r);
    times[i] = (double)(webp_sandbox_now_ns() - start);
    free(r.pixels);
    if (rc != 0) {
      fprintf(stderr, "%s: status %d trap %u\n", path, rc, r.trap);
      exit(1);
    }
  }
  qsort(times, repeat, sizeof(double), compare_doubles);
  printf("%s\t%u\t%u\t%u\t%zu\t%.0f\t%.0f\t%llu\t%llu\n", base_name(path), r.width, r.height, r.channels, size, times[0], times[repeat / 2],
         (unsigned long long)r.memory_bytes, (unsigned long long)r.iterations);
  free(times);
  free(webp);
}

static void time_set(int repeat, int count, char **paths)
{
  size_t *sizes = malloc(sizeof(size_t) * count), total = 0;
  unsigned char **files = malloc(sizeof(unsigned char *) * count);
  double *times = malloc(sizeof(double) * repeat);
  uint64_t start, iterations = 0;
  webp_result r;
  int i, k;

  for (k = 0; k < count; k++) {
    files[k] = read_file(paths[k], &sizes[k]);
    total += sizes[k];
  }
  for (i = 0; i < repeat; i++) {
    iterations = 0;
    start = webp_sandbox_now_ns();
    for (k = 0; k < count; k++) {
      decode(files[k], sizes[k], 16384, &r);
      iterations += r.iterations;
      free(r.pixels);
    }
    times[i] = (double)(webp_sandbox_now_ns() - start);
  }
  qsort(times, repeat, sizeof(double), compare_doubles);
  printf("conformance-%d-files\t0\t0\t0\t%zu\t%.0f\t%.0f\t0\t%llu\n", count, total, times[0], times[repeat / 2], (unsigned long long)iterations);
  for (k = 0; k < count; k++)
    free(files[k]);
  free(files);
  free(sizes);
  free(times);
}

static void count_file(const char *name, const unsigned char *webp, size_t size, int max_side)
{
  webp_result r;
  uint64_t start = webp_sandbox_now_ns();
  int rc = decode(webp, size, max_side, &r);
  uint64_t elapsed = webp_sandbox_now_ns() - start;

  printf("%s\t%d\t%zu\t%llu\t%llu\t%d\t%llu\t%u\t%llu\n", name, max_side, size, (unsigned long long)r.frame_width * r.frame_height,
         (unsigned long long)r.width * r.height, rc, (unsigned long long)r.iterations, r.refuels, (unsigned long long)elapsed);
  free(r.pixels);
}

static void count_files(int max_side, int count, char **paths)
{
  size_t size;
  unsigned char *webp;
  int k;

  for (k = 0; k < count; k++) {
    webp = read_file(paths[k], &size);
    count_file(base_name(paths[k]), webp, size, max_side);
    free(webp);
  }
}

static void count_changed(int max_side, int count, char **paths)
{
  char name[4200];
  size_t size, k;
  unsigned char *webp, *copy;
  int i;

  for (i = 0; i < count; i++) {
    webp = read_file(paths[i], &size);
    copy = malloc(size ? size : 1);
    for (k = 0; k < 64; k++) {
      snprintf(name, sizeof(name), "%s#truncated%zu", base_name(paths[i]), k);
      count_file(name, webp, size * k / 64, max_side);
      memcpy(copy, webp, size);
      copy[(size - 1) * k / 63] ^= (unsigned char)(1u << (k % 8));
      snprintf(name, sizeof(name), "%s#changed%zu", base_name(paths[i]), k);
      count_file(name, copy, size, max_side);
    }
    free(copy);
    free(webp);
  }
}

static void decode_copy(const char *path, const unsigned char *webp, size_t size, size_t changed, unsigned char mask, int max_side,
                        Counts *counts)
{
  unsigned char *copy = malloc(size ? size : 1);
  webp_result r;
  int rc;

  memcpy(copy, webp, size);
  if (changed < size)
    copy[changed] ^= mask;
  rc = decode(copy, size, max_side, &r);
  counts->runs++;
  counts->decoded += rc == 0;
  counts->trapped += rc == WEBP_SANDBOX_TRAP;
  if (rc < 0 && rc != WEBP_SANDBOX_TRAP && counts->other++ < 5)
    printf("%s, %zu bytes, byte %zu changed by 0x%02x: status %d\n", base_name(path), size, changed, mask, rc);
  free(r.pixels);
  free(copy);
}

static void fuzz(const char *path, int max_side, Counts *counts)
{
  size_t size, k;
  unsigned char *webp = read_file(path, &size);

  for (k = 0; k < 64; k++) {
    decode_copy(path, webp, size * k / 64, size, 0, max_side, counts);
    decode_copy(path, webp, size, (size - 1) * k / 63, (unsigned char)(1u << (k % 8)), max_side, counts);
  }
  free(webp);
}

static void limit(const char *path, int mib)
{
  size_t size;
  unsigned char *webp = read_file(path, &size);
  webp_result r;
  int rc;

  limits.memory_limit = (uint64_t)mib << 20;
  rc = decode(webp, size, 16384, &r);
  printf("%s\tlimit %d MiB\tstatus %d\ttrap %u\tlinear memory %.1f MiB\n", base_name(path), mib, rc, r.trap, r.memory_bytes / 1048576.0);
  free(r.pixels);
  free(webp);
}

#ifdef SANDBOX
static void instantiate(int repeat)
{
  double *times = malloc(sizeof(double) * repeat);
  uint64_t start;
  webp_result r;
  uint32_t value;
  int i;

  for (i = 0; i < repeat; i++) {
    start = webp_sandbox_now_ns();
    webp_sandbox_load(0, call_limits(start), &value, &r);
    times[i] = (double)(webp_sandbox_now_ns() - start);
  }
  qsort(times, repeat, sizeof(double), compare_doubles);
  printf("instantiate, call and free\t%.0f ns minimum\t%.0f ns median\tlinear memory %.1f MiB\n", times[0], times[repeat / 2],
         r.memory_bytes / 1048576.0);
  free(times);
}

static void trap(void)
{
  webp_result r;
  uint32_t value = 0;
  int rc = webp_sandbox_load(0, call_limits(webp_sandbox_now_ns()), &value, &r);
  uint64_t end;

  printf("load at 0: status %d trap %u value %u linear memory %llu\n", rc, r.trap, value, (unsigned long long)r.memory_bytes);
  end = r.memory_bytes;
  rc = webp_sandbox_load((uint32_t)end, call_limits(webp_sandbox_now_ns()), &value, &r);
  printf("load at %llu: status %d trap %u\n", (unsigned long long)end, rc, r.trap);
  if (rc != WEBP_SANDBOX_TRAP || r.trap == 0)
    exit(1);
  rc = webp_sandbox_load(0xFFFFFFFFu, call_limits(webp_sandbox_now_ns()), &value, &r);
  printf("load at 4294967295: status %d trap %u\n", rc, r.trap);
  if (rc != WEBP_SANDBOX_TRAP || r.trap == 0)
    exit(1);
}

static void report_stops(const char *what, int repeat, double *elapsed, double *late, double *found, double *returned, int expected,
                         int *statuses, webp_result *r)
{
  int i, unexpected = 0;

  for (i = 0; i < repeat; i++)
    unexpected += statuses[i] != expected;
  qsort(elapsed, repeat, sizeof(double), compare_doubles);
  qsort(late, repeat, sizeof(double), compare_doubles);
  qsort(found, repeat, sizeof(double), compare_doubles);
  qsort(returned, repeat, sizeof(double), compare_doubles);
  printf("%s\tinterval %u\tstatus %d\t%d of %d calls with another status\titerations %llu\trefuels %u\telapsed ms min %.3f median %.3f max %.3f"
         "\tafter the deadline us min %.1f median %.1f max %.1f\tdeadline to stop us median %.1f max %.1f\tstop to return us median %.1f max %.1f\n",
         what, limits.check_interval, statuses[repeat - 1], unexpected, repeat, (unsigned long long)r->iterations, r->refuels, elapsed[0] / 1e6,
         elapsed[repeat / 2] / 1e6, elapsed[repeat - 1] / 1e6, late[0] / 1e3, late[repeat / 2] / 1e3, late[repeat - 1] / 1e3,
         found[repeat / 2] / 1e3, found[repeat - 1] / 1e3, returned[repeat / 2] / 1e3, returned[repeat - 1] / 1e3);
}

static void stop(const char *what, int repeat, const char *path)
{
  double *elapsed = malloc(sizeof(double) * repeat), *late = malloc(sizeof(double) * repeat);
  double *found = malloc(sizeof(double) * repeat), *returned = malloc(sizeof(double) * repeat);
  int *statuses = malloc(sizeof(int) * repeat);
  const int expected = deadline_ms ? WEBP_SANDBOX_DEADLINE : WEBP_SANDBOX_BUDGET;
  unsigned char *webp = NULL;
  size_t size = 0;
  uint64_t start, end;
  webp_result r;
  int i;

  if (path)
    webp = read_file(path, &size);
  for (i = 0; i < repeat; i++) {
    start = webp_sandbox_now_ns();
    statuses[i] = path ? webp_sandbox_decode(webp, size, 16384, call_limits(start), &r) : webp_sandbox_spin(call_limits(start), &r);
    end = webp_sandbox_now_ns();
    free(r.pixels);
    elapsed[i] = (double)(end - start);
    late[i] = deadline_ms ? (double)end - (double)(start + deadline_ms * 1000000u) : 0;
    found[i] = deadline_ms && r.stopped_ns ? (double)r.stopped_ns - (double)(start + deadline_ms * 1000000u) : 0;
    returned[i] = r.stopped_ns ? (double)end - (double)r.stopped_ns : 0;
  }
  report_stops(what, repeat, elapsed, late, found, returned, expected, statuses, &r);
  free(webp);
  free(statuses);
  free(returned);
  free(found);
  free(late);
  free(elapsed);
}

static void tree(uint32_t depth)
{
  uint64_t start = webp_sandbox_now_ns();
  webp_result r;
  uint32_t value = 0;
  int rc = webp_sandbox_tree(depth, call_limits(start), &value, &r);

  printf("tree of depth %u\tstatus %d\ttrap %u\tvalue %u\titerations %llu\trefuels %u\telapsed ms %.3f\n", depth, rc, r.trap, value,
         (unsigned long long)r.iterations, r.refuels, (webp_sandbox_now_ns() - start) / 1e6);
}
#endif

int main(int argc, char **argv)
{
  Counts counts = {0, 0, 0, 0};
  int i;

  read_limits();
  if (argc >= 5 && !strcmp(argv[1], "check")) {
    for (i = 4; i < argc; i++)
      write_netpbm(argv[2], atoi(argv[3]), argv[i]);
    return 0;
  }
  if (argc >= 4 && !strcmp(argv[1], "time")) {
    for (i = 3; i < argc; i++)
      time_file(atoi(argv[2]), argv[i]);
    return 0;
  }
  if (argc >= 4 && !strcmp(argv[1], "time-set")) {
    time_set(atoi(argv[2]), argc - 3, argv + 3);
    return 0;
  }
  if (argc >= 4 && !strcmp(argv[1], "count")) {
    count_files(atoi(argv[2]), argc - 3, argv + 3);
    return 0;
  }
  if (argc >= 4 && !strcmp(argv[1], "count-changed")) {
    count_changed(atoi(argv[2]), argc - 3, argv + 3);
    return 0;
  }
  if (argc >= 4 && !strcmp(argv[1], "fuzz")) {
    for (i = 3; i < argc; i++)
      fuzz(argv[i], atoi(argv[2]), &counts);
    printf("%d truncated and changed inputs decoded with sides of at most %s: %d decoded, %d refused by the decoder, %d trapped, %d refused by "
           "the host\n",
           counts.runs, argv[2], counts.decoded, counts.runs - counts.decoded - counts.trapped - counts.other, counts.trapped, counts.other);
    return counts.other != 0;
  }
  if (argc == 4 && !strcmp(argv[1], "limit")) {
    limit(argv[2], atoi(argv[3]));
    return 0;
  }
#ifdef SANDBOX
  if (argc == 3 && !strcmp(argv[1], "instantiate")) {
    instantiate(atoi(argv[2]));
    return 0;
  }
  if (argc == 2 && !strcmp(argv[1], "trap")) {
    trap();
    return 0;
  }
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
  fprintf(stderr, "usage: %s check DIR MAX_SIDE WEBP... | time REPEAT WEBP... | time-set REPEAT WEBP... | count MAX_SIDE WEBP... | "
                  "count-changed MAX_SIDE WEBP... | fuzz MAX_SIDE WEBP... | limit WEBP MIB | instantiate REPEAT | trap | spin REPEAT | "
                  "stop REPEAT WEBP | tree DEPTH\n",
          argv[0]);
  return 2;
}
