#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "sandbox.h"

#define MEMORY_LIMIT (256ull << 20)

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

static int decode(const unsigned char *webp, size_t size, int max_side, uint64_t memory_limit, webp_result *result)
{
#ifdef SANDBOX
  return webp_sandbox_decode(webp, size, max_side, memory_limit, result);
#else
  (void)memory_limit;
  return webp_native_decode(webp, size, max_side, result);
#endif
}

static double now_ns(void)
{
  struct timespec t;

  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e9 + t.tv_nsec;
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
  int rc = decode(webp, size, max_side, MEMORY_LIMIT, &r);
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
  double *times = malloc(sizeof(double) * repeat), start;
  webp_result r;
  int i, rc = 0;

  for (i = 0; i < repeat; i++) {
    start = now_ns();
    rc = decode(webp, size, 16384, MEMORY_LIMIT, &r);
    times[i] = now_ns() - start;
    free(r.pixels);
    if (rc != 0) {
      fprintf(stderr, "%s: status %d trap %u\n", path, rc, r.trap);
      exit(1);
    }
  }
  qsort(times, repeat, sizeof(double), compare_doubles);
  printf("%s\t%u\t%u\t%u\t%zu\t%.0f\t%.0f\t%llu\n", base_name(path), r.width, r.height, r.channels, size, times[0], times[repeat / 2],
         (unsigned long long)r.memory_bytes);
  free(times);
  free(webp);
}

static void time_set(int repeat, int count, char **paths)
{
  size_t *sizes = malloc(sizeof(size_t) * count), total = 0;
  unsigned char **files = malloc(sizeof(unsigned char *) * count);
  double *times = malloc(sizeof(double) * repeat), start;
  webp_result r;
  int i, k;

  for (k = 0; k < count; k++) {
    files[k] = read_file(paths[k], &sizes[k]);
    total += sizes[k];
  }
  for (i = 0; i < repeat; i++) {
    start = now_ns();
    for (k = 0; k < count; k++) {
      decode(files[k], sizes[k], 16384, MEMORY_LIMIT, &r);
      free(r.pixels);
    }
    times[i] = now_ns() - start;
  }
  qsort(times, repeat, sizeof(double), compare_doubles);
  printf("conformance-%d-files\t0\t0\t0\t%zu\t%.0f\t%.0f\t0\n", count, total, times[0], times[repeat / 2]);
  for (k = 0; k < count; k++)
    free(files[k]);
  free(files);
  free(sizes);
  free(times);
}

typedef struct {
  int runs, decoded, trapped, other;
} Counts;

static void decode_copy(const char *path, const unsigned char *webp, size_t size, size_t changed, unsigned char mask, int max_side,
                        Counts *counts)
{
  unsigned char *copy = malloc(size ? size : 1);
  webp_result r;
  int rc;

  memcpy(copy, webp, size);
  if (changed < size)
    copy[changed] ^= mask;
  rc = decode(copy, size, max_side, MEMORY_LIMIT, &r);
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
  int rc = decode(webp, size, 16384, (uint64_t)mib << 20, &r);

  printf("%s\tlimit %d MiB\tstatus %d\ttrap %u\tlinear memory %.1f MiB\n", base_name(path), mib, rc, r.trap, r.memory_bytes / 1048576.0);
  free(r.pixels);
  free(webp);
}

#ifdef SANDBOX
static void instantiate(int repeat)
{
  double *times = malloc(sizeof(double) * repeat), start;
  webp_result r;
  uint32_t value;
  int i;

  for (i = 0; i < repeat; i++) {
    start = now_ns();
    webp_sandbox_load(0, MEMORY_LIMIT, &value, &r);
    times[i] = now_ns() - start;
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
  int rc = webp_sandbox_load(0, MEMORY_LIMIT, &value, &r);
  uint64_t end;

  printf("load at 0: status %d trap %u value %u linear memory %llu\n", rc, r.trap, value, (unsigned long long)r.memory_bytes);
  end = r.memory_bytes;
  rc = webp_sandbox_load((uint32_t)end, MEMORY_LIMIT, &value, &r);
  printf("load at %llu: status %d trap %u\n", (unsigned long long)end, rc, r.trap);
  if (rc != WEBP_SANDBOX_TRAP || r.trap == 0)
    exit(1);
  rc = webp_sandbox_load(0xFFFFFFFFu, MEMORY_LIMIT, &value, &r);
  printf("load at 4294967295: status %d trap %u\n", rc, r.trap);
  if (rc != WEBP_SANDBOX_TRAP || r.trap == 0)
    exit(1);
}
#endif

int main(int argc, char **argv)
{
  Counts counts = {0, 0, 0, 0};
  int i;

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
#endif
  fprintf(stderr, "usage: %s check DIR MAX_SIDE WEBP... | time REPEAT WEBP... | time-set REPEAT WEBP... | fuzz MAX_SIDE WEBP... | limit WEBP MIB | instantiate REPEAT | trap\n",
          argv[0]);
  return 2;
}
