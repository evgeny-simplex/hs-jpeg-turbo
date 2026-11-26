#include "sandbox.h"
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif

uint64_t webp_sandbox_now_ns(void)
{
#ifdef _WIN32
  LARGE_INTEGER count, frequency;

  QueryPerformanceCounter(&count);
  QueryPerformanceFrequency(&frequency);
  return (uint64_t)(count.QuadPart / frequency.QuadPart) * 1000000000u +
         (uint64_t)(count.QuadPart % frequency.QuadPart) * 1000000000u / (uint64_t)frequency.QuadPart;
#else
  struct timespec t;

  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
#endif
}
