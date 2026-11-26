#ifndef WEBP_SANDBOX_ENV_H
#define WEBP_SANDBOX_ENV_H

#include <stdint.h>
#include "wasm-rt.h"

struct w2c_env {
  wasm_rt_memory_t memory;
  uint64_t remaining;
  uint64_t granted;
  uint64_t charged;
  uint64_t per_pixel;
  uint64_t deadline_ns;
  uint64_t stopped_ns;
  int64_t counter;
  uint32_t interval;
  uint32_t refuels;
  int limited;
  int stopped;
};

uint32_t w2c_env_refuel(struct w2c_env *env);

void w2c_env_fill(struct w2c_env *env, uint32_t destination, uint32_t value, uint32_t length);

void w2c_env_copy(struct w2c_env *env, uint32_t destination, uint32_t source, uint32_t length);

#endif
