#include "src/dsp/cpu.h"

static int GuestCPUInfo(CPUFeature feature)
{
  return feature == kSSE2;
}

WEBP_EXTERN VP8CPUInfo VP8GetCPUInfo;
VP8CPUInfo VP8GetCPUInfo = GuestCPUInfo;
