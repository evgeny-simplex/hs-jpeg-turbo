#include <stdlib.h>
#include <string.h>
#include "canvas.h"
#include "sandbox.h"
#include "sandbox-env.h"
#include "wasm-rt-exceptions.h"
#include "wasm-rt-impl.h"
#include "webp-wasm.h"
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

#ifndef WASM_RT_C11_AVAILABLE
#error "the trap state of wasm2c is thread-local only with C11"
#endif

#define OUTPUT_SIZE 20
#define PROBE_SIZE 24
#define MAX_RATE (1ull << 32)

typedef struct {
  const uint8_t *webp;
  size_t size;
  int max_side;
  uint32_t argument;
  uint32_t *value;
} Call;

typedef struct {
  uint32_t width, height, channels, frame_width, frame_height;
} Expected;

typedef struct {
  struct w2c_env env;
  w2c_webp instance;
} Session;

typedef int (*Run)(w2c_webp *instance, struct w2c_env *env, const Call *call, webp_result *result);

wasm_rt_memory_t *w2c_env_memory(struct w2c_env *env)
{
  return &env->memory;
}

uint32_t w2c_env_refuel(struct w2c_env *env)
{
  uint64_t grant = env->interval;

  if (env->deadline_ns && webp_sandbox_now_ns() >= env->deadline_ns) {
    env->stopped = WEBP_SANDBOX_DEADLINE;
    wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);
  }
  if (env->limited) {
    if (env->remaining == 0) {
      env->stopped = WEBP_SANDBOX_BUDGET;
      wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);
    }
    if (grant > env->remaining)
      grant = env->remaining;
    env->remaining -= grant;
  }
  env->granted += grant;
  env->refuels++;
  return (uint32_t)grant;
}

#ifdef _WIN32
static INIT_ONCE runtime_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK init_runtime(PINIT_ONCE once, PVOID parameter, PVOID *context)
{
  (void)once;
  (void)parameter;
  (void)context;
  wasm_rt_init();
  return TRUE;
}

static void init_runtime_once(void)
{
  InitOnceExecuteOnce(&runtime_once, init_runtime, NULL, NULL);
}
#else
static pthread_once_t runtime_once = PTHREAD_ONCE_INIT;

static void init_runtime(void)
{
  wasm_rt_init();
}

static void init_runtime_once(void)
{
  pthread_once(&runtime_once, init_runtime);
}
#endif

static uint64_t add_product(uint64_t sum, uint64_t rate, uint64_t count)
{
  const uint64_t product = rate && count > UINT64_MAX / rate ? UINT64_MAX : rate * count;

  return product > UINT64_MAX - sum ? UINT64_MAX : sum + product;
}

static int64_t fuel_counter(w2c_webp *instance, const struct w2c_env *env)
{
#if defined(WEBP_SANDBOX_FUEL_GLOBAL)
  (void)env;
  return (int32_t)*w2c_webp_fuel(instance);
#else
  (void)instance;
  return env->counter;
#endif
}

static int in_memory(const wasm_rt_memory_t *memory, uint64_t offset, uint64_t length)
{
  return offset <= memory->size && length <= memory->size - offset;
}

static uint32_t read_u32(const wasm_rt_memory_t *memory, uint32_t offset)
{
  const uint8_t *p = memory->data + offset;
  return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static int valid_side(uint32_t side)
{
  return side >= 1 && side <= WEBP_MAX_SIDE;
}

static int read_probe(const wasm_rt_memory_t *memory, uint32_t probe, int max_side, Expected *expected)
{
  uint32_t status, width, height;

  if (!in_memory(memory, probe, PROBE_SIZE))
    return WEBP_SANDBOX_INVALID_OUTPUT;
  status = read_u32(memory, probe);
  if (status != 0)
    return status <= 7 ? (int)status : WEBP_SANDBOX_INVALID_OUTPUT;
  width = read_u32(memory, probe + 4);
  height = read_u32(memory, probe + 8);
  expected->frame_width = read_u32(memory, probe + 12);
  expected->frame_height = read_u32(memory, probe + 16);
  expected->channels = read_u32(memory, probe + 20);
  if (!valid_side(width) || !valid_side(height) || !valid_side(expected->frame_width) || !valid_side(expected->frame_height) ||
      (expected->channels != 3 && expected->channels != 4))
    return WEBP_SANDBOX_INVALID_OUTPUT;
  while ((width > (uint32_t)max_side || height > (uint32_t)max_side) && width > 1 && height > 1) {
    width = (width + 1) / 2;
    height = (height + 1) / 2;
  }
  expected->width = width;
  expected->height = height;
  return 0;
}

static int copy_output(const wasm_rt_memory_t *memory, uint32_t output, const Expected *expected, webp_result *result)
{
  uint32_t status, pixels;
  uint64_t length;

  if (!in_memory(memory, output, OUTPUT_SIZE))
    return WEBP_SANDBOX_INVALID_OUTPUT;
  status = read_u32(memory, output);
  if (status != 0)
    return status <= 7 ? (int)status : WEBP_SANDBOX_INVALID_OUTPUT;
  pixels = read_u32(memory, output + 16);
  if (read_u32(memory, output + 4) != expected->width || read_u32(memory, output + 8) != expected->height ||
      read_u32(memory, output + 12) != expected->channels)
    return WEBP_SANDBOX_INVALID_OUTPUT;
  length = (uint64_t)expected->width * expected->height * expected->channels;
  if (!in_memory(memory, pixels, length))
    return WEBP_SANDBOX_INVALID_OUTPUT;
  if (!(result->pixels = malloc(length)))
    return WEBP_SANDBOX_OUT_OF_MEMORY;
  memcpy(result->pixels, memory->data + pixels, length);
  result->width = expected->width;
  result->height = expected->height;
  result->channels = expected->channels;
  return 0;
}

static int run_decode(w2c_webp *instance, struct w2c_env *env, const Call *call, webp_result *result)
{
  const uint32_t input = w2c_webp_input(instance, (uint32_t)call->size);
  Expected expected;
  int status;

  if (input == 0)
    return WEBP_SANDBOX_OUT_OF_MEMORY;
  if (!in_memory(&env->memory, input, call->size))
    return WEBP_SANDBOX_INVALID_OUTPUT;
  memcpy(env->memory.data + input, call->webp, call->size);
  status = read_probe(&env->memory, w2c_webp_probe(instance, input, (uint32_t)call->size), call->max_side, &expected);
  if (status != 0)
    return status;
  result->frame_width = expected.frame_width;
  result->frame_height = expected.frame_height;
  env->remaining = add_product(env->remaining, env->per_pixel,
                               (uint64_t)expected.frame_width * expected.frame_height + (uint64_t)expected.width * expected.height);
  return copy_output(&env->memory, w2c_webp_decode(instance, input, (uint32_t)call->size, call->max_side), &expected, result);
}

static int run_load(w2c_webp *instance, struct w2c_env *env, const Call *call, webp_result *result)
{
  (void)env;
  (void)result;
  *call->value = w2c_webp_load(instance, call->argument);
  return 0;
}

static int run_spin(w2c_webp *instance, struct w2c_env *env, const Call *call, webp_result *result)
{
  (void)env;
  (void)call;
  (void)result;
  w2c_webp_spin(instance);
  return 0;
}

static int run_tree(w2c_webp *instance, struct w2c_env *env, const Call *call, webp_result *result)
{
  (void)env;
  (void)result;
  *call->value = w2c_webp_tree(instance, call->argument);
  return 0;
}

static int run_in_sandbox(const webp_limits *limits, Run run, const Call *call, webp_result *result)
{
  Session *session;
  volatile int instantiated = 0;
  volatile int status = WEBP_SANDBOX_TRAP;
  const uint64_t max_pages = limits->memory_limit / WASM_DEFAULT_PAGE_SIZE;
  wasm_rt_trap_t trap;

  memset(result, 0, sizeof(*result));
  if (max_pages < wasm2c_webp_min_env_memory || max_pages > wasm2c_webp_max_env_memory || limits->check_interval < 1 ||
      limits->check_interval > WEBP_SANDBOX_MAX_INTERVAL || limits->budget_per_byte > MAX_RATE || limits->budget_per_pixel > MAX_RATE)
    return WEBP_SANDBOX_INVALID_ARGUMENT;
  if (!(session = calloc(1, sizeof(*session))))
    return WEBP_SANDBOX_OUT_OF_MEMORY;
  session->env.limited = limits->budget_base || limits->budget_per_byte || limits->budget_per_pixel;
  session->env.remaining = add_product(limits->budget_base, limits->budget_per_byte, call->size);
  session->env.per_pixel = limits->budget_per_pixel;
  session->env.deadline_ns = limits->deadline_ns;
  session->env.interval = limits->check_interval;
  init_runtime_once();
  if (!wasm_rt_is_initialized())
    wasm_rt_init_thread();
  wasm_rt_allocate_memory(&session->env.memory, wasm2c_webp_min_env_memory, max_pages, false, WASM_DEFAULT_PAGE_SIZE);
  trap = wasm_rt_impl_try();
  if (trap == WASM_RT_TRAP_NONE) {
    instantiated = 1;
    wasm2c_webp_instantiate(&session->instance, &session->env);
    w2c_webp_0x5Finitialize(&session->instance);
    status = run(&session->instance, &session->env, call, result);
  } else {
    result->trap = (uint32_t)trap;
    if (session->env.stopped)
      status = session->env.stopped;
  }
  result->memory_bytes = session->env.memory.size;
  result->refuels = session->env.refuels;
  if (instantiated) {
    result->iterations = (uint64_t)((int64_t)(session->env.granted + session->env.refuels) - fuel_counter(&session->instance, &session->env));
    wasm2c_webp_free(&session->instance);
  }
  wasm_rt_free_memory(&session->env.memory);
  free(session);
  return status;
}

int webp_sandbox_decode(const uint8_t *webp, size_t size, int max_side, const webp_limits *limits, webp_result *result)
{
  const Call call = {webp, size, max_side, 0, NULL};

  if (size > UINT32_MAX || max_side < 1) {
    memset(result, 0, sizeof(*result));
    return WEBP_SANDBOX_INVALID_ARGUMENT;
  }
  return run_in_sandbox(limits, run_decode, &call, result);
}

int webp_sandbox_load(uint32_t address, const webp_limits *limits, uint32_t *value, webp_result *result)
{
  const Call call = {NULL, 0, 0, address, value};

  return run_in_sandbox(limits, run_load, &call, result);
}

int webp_sandbox_spin(const webp_limits *limits, webp_result *result)
{
  const Call call = {NULL, 0, 0, 0, NULL};

  return run_in_sandbox(limits, run_spin, &call, result);
}

int webp_sandbox_tree(uint32_t depth, const webp_limits *limits, uint32_t *value, webp_result *result)
{
  const Call call = {NULL, 0, 0, depth, value};

  return run_in_sandbox(limits, run_tree, &call, result);
}
