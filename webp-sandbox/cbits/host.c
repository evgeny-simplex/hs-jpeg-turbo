#include <stdlib.h>
#include <string.h>
#include "canvas.h"
#include "sandbox.h"
#include "wasm-rt-exceptions.h"
#include "wasm-rt-impl.h"
#include "webp-wasm.h"
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

#define OUTPUT_SIZE 20

struct w2c_env {
  wasm_rt_memory_t memory;
};

typedef struct {
  const uint8_t *webp;
  size_t size;
  int max_side;
  uint32_t address;
  uint32_t *value;
} Call;

typedef int (*Run)(w2c_webp *instance, const wasm_rt_memory_t *memory, const Call *call, webp_result *result);

wasm_rt_memory_t *w2c_env_memory(struct w2c_env *env)
{
  return &env->memory;
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

static int in_memory(const wasm_rt_memory_t *memory, uint64_t offset, uint64_t length)
{
  return offset <= memory->size && length <= memory->size - offset;
}

static uint32_t read_u32(const wasm_rt_memory_t *memory, uint32_t offset)
{
  const uint8_t *p = memory->data + offset;
  return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static int copy_output(const wasm_rt_memory_t *memory, uint32_t output, int max_side, webp_result *result)
{
  uint32_t status, width, height, channels, pixels;
  uint64_t length;

  if (!in_memory(memory, output, OUTPUT_SIZE))
    return WEBP_SANDBOX_INVALID_OUTPUT;
  status = read_u32(memory, output);
  if (status != 0)
    return status <= 7 ? (int)status : WEBP_SANDBOX_INVALID_OUTPUT;
  width = read_u32(memory, output + 4);
  height = read_u32(memory, output + 8);
  channels = read_u32(memory, output + 12);
  pixels = read_u32(memory, output + 16);
  if (width < 1 || width > (uint32_t)max_side || width > WEBP_MAX_SIDE || height < 1 || height > (uint32_t)max_side ||
      height > WEBP_MAX_SIDE || (channels != 3 && channels != 4))
    return WEBP_SANDBOX_INVALID_OUTPUT;
  length = (uint64_t)width * height * channels;
  if (!in_memory(memory, pixels, length))
    return WEBP_SANDBOX_INVALID_OUTPUT;
  if (!(result->pixels = malloc(length)))
    return WEBP_SANDBOX_OUT_OF_MEMORY;
  memcpy(result->pixels, memory->data + pixels, length);
  result->width = width;
  result->height = height;
  result->channels = channels;
  return 0;
}

static int run_decode(w2c_webp *instance, const wasm_rt_memory_t *memory, const Call *call, webp_result *result)
{
  uint32_t input = w2c_webp_input(instance, (uint32_t)call->size);

  if (input == 0)
    return WEBP_SANDBOX_OUT_OF_MEMORY;
  if (!in_memory(memory, input, call->size))
    return WEBP_SANDBOX_INVALID_OUTPUT;
  memcpy(memory->data + input, call->webp, call->size);
  return copy_output(memory, w2c_webp_decode(instance, input, (uint32_t)call->size, call->max_side), call->max_side, result);
}

static int run_load(w2c_webp *instance, const wasm_rt_memory_t *memory, const Call *call, webp_result *result)
{
  (void)memory;
  (void)result;
  *call->value = w2c_webp_load(instance, call->address);
  return 0;
}

static int run_in_sandbox(uint64_t memory_limit, Run run, const Call *call, webp_result *result)
{
  struct w2c_env env;
  w2c_webp instance;
  volatile int instantiated = 0;
  volatile int status = WEBP_SANDBOX_TRAP;
  const uint64_t max_pages = memory_limit / WASM_DEFAULT_PAGE_SIZE;
  wasm_rt_trap_t trap;

  memset(result, 0, sizeof(*result));
  if (max_pages < wasm2c_webp_min_env_memory || max_pages > wasm2c_webp_max_env_memory)
    return WEBP_SANDBOX_INVALID_ARGUMENT;
  init_runtime_once();
  if (!wasm_rt_is_initialized())
    wasm_rt_init_thread();
  wasm_rt_allocate_memory(&env.memory, wasm2c_webp_min_env_memory, max_pages, false, WASM_DEFAULT_PAGE_SIZE);
  trap = wasm_rt_impl_try();
  if (trap == WASM_RT_TRAP_NONE) {
    instantiated = 1;
    wasm2c_webp_instantiate(&instance, &env);
    w2c_webp_0x5Finitialize(&instance);
    status = run(&instance, &env.memory, call, result);
  } else {
    result->trap = (uint32_t)trap;
  }
  result->memory_bytes = env.memory.size;
  if (instantiated)
    wasm2c_webp_free(&instance);
  wasm_rt_free_memory(&env.memory);
  return status;
}

int webp_sandbox_decode(const uint8_t *webp, size_t size, int max_side, uint64_t memory_limit, webp_result *result)
{
  const Call call = {webp, size, max_side, 0, NULL};

  if (size > UINT32_MAX || max_side < 1) {
    memset(result, 0, sizeof(*result));
    return WEBP_SANDBOX_INVALID_ARGUMENT;
  }
  return run_in_sandbox(memory_limit, run_decode, &call, result);
}

int webp_sandbox_load(uint32_t address, uint64_t memory_limit, uint32_t *value, webp_result *result)
{
  const Call call = {NULL, 0, 0, address, value};

  return run_in_sandbox(memory_limit, run_load, &call, result);
}
