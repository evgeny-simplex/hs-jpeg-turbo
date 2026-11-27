#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sandbox.h"
#include "image-wasm.h"
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <sys/mman.h>
#endif

#define HEADER_SIZE 16
#define OUTPUT_SIZE 36
#define MAX_RATE (1ull << 32)
#define MAX_METADATA (64u << 20)
#define MAX_SIDE 65535
#define MAX_OUTPUT_PIXELS ((1u << 30) - 1)
#define BULK_CHUNK (1u << 16)
#define BULK_BYTES_PER_ITERATION_BITS 8

enum { FORMAT_JPEG = 1, FORMAT_PNG = 2, FORMAT_WEBP = 3 };

enum { LAYOUT_Y8 = 1, LAYOUT_RGB8 = 2, LAYOUT_RGBA8 = 3, LAYOUT_CMYK8 = 4 };

struct w2c_env {
  wasm_rt_memory_t memory;
  uint64_t remaining;
  uint64_t granted;
  uint64_t charged;
  uint64_t deadline_ns;
  uint32_t interval;
  uint32_t refuels;
  int limited;
  int stopped;
};

struct w2c_wasi__snapshot__preview1 {
  int unused;
};

struct sandbox {
  struct w2c_env env;
  struct w2c_wasi__snapshot__preview1 wasi;
  w2c_image instance;
  wasm_rt_jmp_buf jump;
  int memory_allocated;
  int instantiated;
  int grow_failed;
  uint32_t trap;
  uint32_t message_address;
  uint32_t input;
  uint32_t size;
  uint32_t memory_mb;
  sandbox_header header;
  char message[SANDBOX_MESSAGE_SIZE];
};

typedef void (*Call)(sandbox *session, void *argument);

#ifdef _WIN32
static INIT_ONCE key_once = INIT_ONCE_STATIC_INIT;
static DWORD key = TLS_OUT_OF_INDEXES;

static BOOL CALLBACK create_key(PINIT_ONCE once, PVOID parameter, PVOID *context)
{
  (void)once;
  (void)parameter;
  (void)context;
  key = TlsAlloc();
  return key != TLS_OUT_OF_INDEXES;
}

static int init_key(void)
{
  return InitOnceExecuteOnce(&key_once, create_key, NULL, NULL) && key != TLS_OUT_OF_INDEXES;
}

static sandbox *current(void)
{
  return TlsGetValue(key);
}

static void set_current(sandbox *session)
{
  TlsSetValue(key, session);
}
#else
static pthread_once_t key_once = PTHREAD_ONCE_INIT;
static pthread_key_t key;
static int key_created;

static void create_key(void)
{
  key_created = pthread_key_create(&key, NULL) == 0;
}

static int init_key(void)
{
  return pthread_once(&key_once, create_key) == 0 && key_created;
}

static sandbox *current(void)
{
  return pthread_getspecific(key);
}

static void set_current(sandbox *session)
{
  pthread_setspecific(key, session);
}
#endif

void wasm_rt_trap(wasm_rt_trap_t code)
{
  sandbox *session = current();

  if (!session)
    abort();
  session->trap = (uint32_t)code;
  WASM_RT_LONGJMP(session->jump, 1);
}

bool wasm_rt_is_initialized(void)
{
  return true;
}

void sandbox_grow_failed(void)
{
  sandbox *session = current();

  if (session)
    session->grow_failed = 1;
}

#define WASM_RT_TABLE_OPS_FUNCREF
#include "wasm-rt-impl-tableops.inc"
#undef WASM_RT_TABLE_OPS_FUNCREF

#define WASM_RT_TABLE_OPS_EXTERNREF
#include "wasm-rt-impl-tableops.inc"
#undef WASM_RT_TABLE_OPS_EXTERNREF

wasm_rt_memory_t *w2c_env_memory(struct w2c_env *env)
{
  return &env->memory;
}

static void stop(struct w2c_env *env, int reason)
{
  env->stopped = reason;
  wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);
}

static void check_deadline(struct w2c_env *env)
{
  if (env->deadline_ns && sandbox_now_ns() >= env->deadline_ns)
    stop(env, SANDBOX_DEADLINE);
}

uint32_t w2c_env_refuel(struct w2c_env *env)
{
  uint64_t grant = env->interval;

  check_deadline(env);
  if (env->limited) {
    if (env->remaining == 0)
      stop(env, SANDBOX_BUDGET);
    if (grant > env->remaining)
      grant = env->remaining;
    env->remaining -= grant;
  }
  env->granted += grant;
  env->refuels++;
  return (uint32_t)grant;
}

static uint8_t *bulk_range(struct w2c_env *env, uint32_t offset, uint32_t length)
{
  if ((uint64_t)offset + length > env->memory.size)
    wasm_rt_trap(WASM_RT_TRAP_OOB);
  return env->memory.data + offset;
}

static void reclaim_grant(struct w2c_env *env)
{
  uint32_t *counter = w2c_image_fuel(&((sandbox *)env)->instance);
  const int64_t unspent = (int32_t)*counter;

  if (unspent > 0) {
    env->remaining += (uint64_t)unspent;
    env->granted -= (uint64_t)unspent;
    *counter = 0;
  }
}

static void charge_bulk(struct w2c_env *env, uint32_t length)
{
  const uint64_t iterations = length >> BULK_BYTES_PER_ITERATION_BITS;

  if (env->limited) {
    if (env->remaining < iterations)
      reclaim_grant(env);
    if (env->remaining < iterations)
      stop(env, SANDBOX_BUDGET);
    env->remaining -= iterations;
  }
  env->charged += iterations;
}

void w2c_env_fill(struct w2c_env *env, uint32_t destination, uint32_t value, uint32_t length)
{
  uint8_t *d = bulk_range(env, destination, length);

  charge_bulk(env, length);
  while (length > BULK_CHUNK) {
    memset(d, (int)value, BULK_CHUNK);
    d += BULK_CHUNK;
    length -= BULK_CHUNK;
    check_deadline(env);
  }
  memset(d, (int)value, length);
}

void w2c_env_copy(struct w2c_env *env, uint32_t destination, uint32_t source, uint32_t length)
{
  uint8_t *d = bulk_range(env, destination, length), *s = bulk_range(env, source, length);

  charge_bulk(env, length);
  if (d <= s) {
    while (length > BULK_CHUNK) {
      memmove(d, s, BULK_CHUNK);
      d += BULK_CHUNK;
      s += BULK_CHUNK;
      length -= BULK_CHUNK;
      check_deadline(env);
    }
    memmove(d, s, length);
  } else {
    while (length > BULK_CHUNK) {
      length -= BULK_CHUNK;
      memmove(d + length, s + length, BULK_CHUNK);
      check_deadline(env);
    }
    memmove(d, s, length);
  }
}

#define WASI_EBADF 8
#define WASI_ENOSYS 52

u32 w2c_wasi__snapshot__preview1_clock_time_get(struct w2c_wasi__snapshot__preview1 *wasi, u32 id, u64 precision, u32 time)
{
  (void)wasi;
  (void)id;
  (void)precision;
  (void)time;
  return WASI_ENOSYS;
}

u32 w2c_wasi__snapshot__preview1_fd_close(struct w2c_wasi__snapshot__preview1 *wasi, u32 fd)
{
  (void)wasi;
  (void)fd;
  return WASI_EBADF;
}

u32 w2c_wasi__snapshot__preview1_fd_prestat_dir_name(struct w2c_wasi__snapshot__preview1 *wasi, u32 fd, u32 path, u32 length)
{
  (void)wasi;
  (void)fd;
  (void)path;
  (void)length;
  return WASI_EBADF;
}

u32 w2c_wasi__snapshot__preview1_fd_prestat_get(struct w2c_wasi__snapshot__preview1 *wasi, u32 fd, u32 prestat)
{
  (void)wasi;
  (void)fd;
  (void)prestat;
  return WASI_EBADF;
}

u32 w2c_wasi__snapshot__preview1_fd_seek(struct w2c_wasi__snapshot__preview1 *wasi, u32 fd, u64 offset, u32 whence, u32 position)
{
  (void)wasi;
  (void)fd;
  (void)offset;
  (void)whence;
  (void)position;
  return WASI_EBADF;
}

u32 w2c_wasi__snapshot__preview1_fd_write(struct w2c_wasi__snapshot__preview1 *wasi, u32 fd, u32 iovs, u32 count, u32 written)
{
  (void)wasi;
  (void)fd;
  (void)iovs;
  (void)count;
  (void)written;
  return WASI_EBADF;
}

void w2c_wasi__snapshot__preview1_proc_exit(struct w2c_wasi__snapshot__preview1 *wasi, u32 code)
{
  (void)wasi;
  (void)code;
  wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);
}

static int allocate_memory(wasm_rt_memory_t *memory, uint64_t initial_pages, uint64_t max_pages)
{
  const size_t reserved = (size_t)max_pages * WASM_DEFAULT_PAGE_SIZE, initial = (size_t)initial_pages * WASM_DEFAULT_PAGE_SIZE;
  uint8_t *data;

#ifdef _WIN32
  if (!(data = VirtualAlloc(NULL, reserved, MEM_RESERVE, PAGE_NOACCESS)))
    return 0;
  if (initial && VirtualAlloc(data, initial, MEM_COMMIT, PAGE_READWRITE) != data) {
    VirtualFree(data, 0, MEM_RELEASE);
    return 0;
  }
#else
  if ((data = mmap(NULL, reserved, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)) == MAP_FAILED)
    return 0;
  if (initial && mprotect(data, initial, PROT_READ | PROT_WRITE) != 0) {
    munmap(data, reserved);
    return 0;
  }
#endif
  memory->data = data;
  memory->data_end = data + reserved;
  memory->page_size = WASM_DEFAULT_PAGE_SIZE;
  memory->pages = initial_pages;
  memory->max_pages = max_pages;
  memory->size = initial;
  memory->is64 = false;
  return 1;
}

static int in_memory(const sandbox *session, uint64_t address, uint64_t length)
{
  return address <= session->env.memory.size && length <= session->env.memory.size - address;
}

static uint32_t read_u32(const sandbox *session, uint32_t address)
{
  const uint8_t *p = session->env.memory.data + address;

  return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static void set_message(sandbox *session, const char *message)
{
  strncpy(session->message, message, SANDBOX_MESSAGE_SIZE - 1);
  session->message[SANDBOX_MESSAGE_SIZE - 1] = 0;
}

static int copy_guest_message(sandbox *session, uint32_t address)
{
  uint64_t n = 0;

  if (address == 0 || !in_memory(session, address, 1))
    return 0;
  while (n < SANDBOX_MESSAGE_SIZE - 1 && address + n < session->env.memory.size && session->env.memory.data[address + n])
    n++;
  memcpy(session->message, session->env.memory.data + address, n);
  session->message[n] = 0;
  return n > 0;
}

static int failure(sandbox *session, int status)
{
  switch (status) {
  case SANDBOX_BUDGET:
    set_message(session, "budget exceeded");
    break;
  case SANDBOX_DEADLINE:
    set_message(session, "deadline exceeded");
    break;
  case SANDBOX_MEMORY_LIMIT:
    set_message(session, "image is too large");
    break;
  case SANDBOX_OUT_OF_MEMORY:
    set_message(session, "out of memory");
    break;
  case SANDBOX_INVALID_ARGUMENT:
    set_message(session, "invalid argument");
    break;
  case SANDBOX_INVALID_OUTPUT:
    set_message(session, "invalid sandbox output");
    break;
  case SANDBOX_TRAP:
    snprintf(session->message, SANDBOX_MESSAGE_SIZE, "sandbox trap %u", session->trap);
    break;
  }
  return status;
}

static int decoder_failure(sandbox *session, uint32_t address)
{
  if (session->grow_failed)
    return failure(session, SANDBOX_MEMORY_LIMIT);
  if (copy_guest_message(session, address))
    return SANDBOX_DECODER;
  return failure(session, SANDBOX_INVALID_OUTPUT);
}

static int trapped(sandbox *session)
{
  if (session->env.stopped)
    return failure(session, session->env.stopped);
  if (session->grow_failed)
    return failure(session, SANDBOX_MEMORY_LIMIT);
  if (session->instantiated && copy_guest_message(session, session->message_address))
    return SANDBOX_DECODER;
  return failure(session, SANDBOX_TRAP);
}

static int guarded(sandbox *session, Call call, void *argument)
{
  sandbox *previous = current();
  int status = 0;

  set_current(session);
  session->jump.initialized = true;
  if (WASM_RT_SETJMP_TRAP_SETBUF(session->jump.buffer) == 0)
    call(session, argument);
  else
    status = trapped(session);
  session->jump.initialized = false;
  set_current(previous);
  return status;
}

static uint64_t add_product(uint64_t sum, uint64_t rate, uint64_t count)
{
  const uint64_t product = rate && count > UINT64_MAX / rate ? UINT64_MAX : rate * count;

  return product > UINT64_MAX - sum ? UINT64_MAX : sum + product;
}

static void instantiate(sandbox *session, void *argument)
{
  (void)argument;
  session->instantiated = 1;
  wasm2c_image_instantiate(&session->instance, &session->env, &session->wasi);
  w2c_image_0x5Finitialize(&session->instance);
  session->message_address = w2c_image_error(&session->instance);
}

static int start(const sandbox_limits *limits, size_t size, sandbox **result)
{
  const uint64_t max_pages = limits->memory_limit / WASM_DEFAULT_PAGE_SIZE;
  sandbox *session;

  *result = NULL;
  if (size > UINT32_MAX || max_pages < wasm2c_image_min_env_memory || max_pages > wasm2c_image_max_env_memory || limits->check_interval < 1 ||
      limits->check_interval > SANDBOX_MAX_INTERVAL || limits->budget_per_byte > MAX_RATE)
    return SANDBOX_INVALID_ARGUMENT;
  if (!init_key() || !(session = calloc(1, sizeof(*session))))
    return SANDBOX_OUT_OF_MEMORY;
  *result = session;
  session->env.limited = limits->budget_base || limits->budget_per_byte;
  session->env.remaining = add_product(limits->budget_base, limits->budget_per_byte, size);
  session->env.deadline_ns = limits->deadline_ns;
  session->env.interval = limits->check_interval;
  session->memory_mb = (uint32_t)(limits->memory_limit >> 20);
  session->size = (uint32_t)size;
  if (!allocate_memory(&session->env.memory, wasm2c_image_min_env_memory, max_pages))
    return failure(session, SANDBOX_OUT_OF_MEMORY);
  session->memory_allocated = 1;
  return guarded(session, instantiate, NULL);
}

typedef struct {
  const uint8_t *data;
  uint32_t header;
} Probe;

static void probe(sandbox *session, void *argument)
{
  Probe *call = argument;

  session->input = w2c_image_input(&session->instance, session->size);
  if (session->input == 0 || !in_memory(session, session->input, session->size)) {
    session->input = 0;
    return;
  }
  memcpy(session->env.memory.data + session->input, call->data, session->size);
  call->header = w2c_image_probe(&session->instance, session->input, session->size);
}

static int read_header(sandbox *session, uint32_t address, sandbox_header *header)
{
  uint32_t message;

  if (!in_memory(session, address, HEADER_SIZE))
    return failure(session, SANDBOX_INVALID_OUTPUT);
  message = read_u32(session, address);
  if (message != 0)
    return decoder_failure(session, message);
  header->format = read_u32(session, address + 4);
  header->width = read_u32(session, address + 8);
  header->height = read_u32(session, address + 12);
  if (header->format < FORMAT_JPEG || header->format > FORMAT_WEBP || header->width < 1 || header->width > MAX_SIDE || header->height < 1 ||
      header->height > MAX_SIDE)
    return failure(session, SANDBOX_INVALID_OUTPUT);
  session->header = *header;
  return 0;
}

int sandbox_open(const uint8_t *data, size_t size, const sandbox_limits *limits, sandbox **session, sandbox_header *header)
{
  Probe call = {data, 0};
  int status;

  memset(header, 0, sizeof(*header));
  if ((status = start(limits, size, session)) != 0)
    return status;
  if ((status = guarded(*session, probe, &call)) != 0)
    return status;
  if ((*session)->input == 0)
    return (*session)->grow_failed ? failure(*session, SANDBOX_MEMORY_LIMIT) : failure(*session, SANDBOX_OUT_OF_MEMORY);
  return read_header(*session, call.header, header);
}

typedef struct {
  uint32_t width, height, output;
} Decode;

static void decode(sandbox *session, void *argument)
{
  Decode *call = argument;

  call->output = w2c_image_decode(&session->instance, session->input, session->size, call->width, call->height, session->memory_mb);
}

static uint32_t layout_channels(uint32_t format, uint32_t layout)
{
  switch (layout) {
  case LAYOUT_Y8:
    return format == FORMAT_JPEG ? 1 : 0;
  case LAYOUT_RGB8:
    return 3;
  case LAYOUT_RGBA8:
    return format == FORMAT_JPEG ? 0 : 4;
  case LAYOUT_CMYK8:
    return format == FORMAT_JPEG ? 4 : 0;
  default:
    return 0;
  }
}

static int copy_bytes(sandbox *session, uint32_t address, uint32_t size, uint64_t limit, uint8_t **copy)
{
  *copy = NULL;
  if (address == 0 && size == 0)
    return 1;
  if (size > limit || !in_memory(session, address, size))
    return 0;
  if (!(*copy = malloc(size ? size : 1)))
    return 0;
  memcpy(*copy, session->env.memory.data + address, size);
  return 1;
}

static int read_output(sandbox *session, uint32_t address, uint32_t width, uint32_t height, sandbox_image *image)
{
  uint32_t message, channels, pixels;
  uint64_t length;

  if (!in_memory(session, address, OUTPUT_SIZE))
    return failure(session, SANDBOX_INVALID_OUTPUT);
  message = read_u32(session, address);
  if (message != 0)
    return decoder_failure(session, message);
  channels = layout_channels(session->header.format, read_u32(session, address + 12));
  if (read_u32(session, address + 4) != width || read_u32(session, address + 8) != height || channels == 0)
    return failure(session, SANDBOX_INVALID_OUTPUT);
  pixels = read_u32(session, address + 16);
  length = (uint64_t)width * height * channels;
  if (length > SIZE_MAX || !in_memory(session, pixels, length))
    return failure(session, SANDBOX_INVALID_OUTPUT);
  image->width = width;
  image->height = height;
  image->layout = read_u32(session, address + 12);
  image->icc_size = read_u32(session, address + 24);
  image->exif_size = read_u32(session, address + 32);
  if (!copy_bytes(session, read_u32(session, address + 20), image->icc_size, MAX_METADATA, &image->icc) ||
      !copy_bytes(session, read_u32(session, address + 28), image->exif_size, session->size, &image->exif) ||
      !(image->pixels = malloc((size_t)length))) {
    free(image->icc);
    free(image->exif);
    memset(image, 0, sizeof(*image));
    return failure(session, SANDBOX_INVALID_OUTPUT);
  }
  memcpy(image->pixels, session->env.memory.data + pixels, (size_t)length);
  return 0;
}

int sandbox_decode(sandbox *session, uint32_t width, uint32_t height, uint64_t budget_per_pixel, sandbox_image *image)
{
  Decode call = {width, height, 0};
  const uint64_t pixels = (uint64_t)session->header.width * session->header.height + (uint64_t)width * height;
  int status;

  memset(image, 0, sizeof(*image));
  if (session->input == 0 || width < 1 || width > session->header.width || height < 1 || height > session->header.height ||
      budget_per_pixel > MAX_RATE)
    return failure(session, SANDBOX_INVALID_ARGUMENT);
  if ((uint64_t)width * height > MAX_OUTPUT_PIXELS)
    return failure(session, SANDBOX_MEMORY_LIMIT);
  if (session->env.limited)
    session->env.remaining = add_product(session->env.remaining, budget_per_pixel, pixels);
  if ((status = guarded(session, decode, &call)) != 0)
    return status;
  return read_output(session, call.output, width, height, image);
}

void sandbox_close(sandbox *session)
{
  if (!session)
    return;
  if (session->instantiated)
    wasm2c_image_free(&session->instance);
  if (session->memory_allocated)
    wasm_rt_free_memory(&session->env.memory);
  free(session);
}

const char *sandbox_message(const sandbox *session)
{
  return session->message;
}

uint64_t sandbox_iterations(const sandbox *session)
{
  const int64_t counter = session->instantiated ? (int32_t)*w2c_image_fuel((w2c_image *)&session->instance) : 0;

  return (uint64_t)((int64_t)(session->env.granted + session->env.refuels + session->env.charged) - counter);
}

uint64_t sandbox_memory_bytes(const sandbox *session)
{
  return session->env.memory.size;
}

typedef struct {
  uint32_t argument, value;
} Test;

static void load(sandbox *session, void *argument)
{
  Test *call = argument;

  call->value = w2c_image_load(&session->instance, call->argument);
}

static void spin(sandbox *session, void *argument)
{
  (void)argument;
  w2c_image_spin(&session->instance);
}

static void tree(sandbox *session, void *argument)
{
  Test *call = argument;

  call->value = w2c_image_tree(&session->instance, call->argument);
}

typedef struct {
  uint32_t address, length, format, width, height;
  const uint8_t *data;
  sandbox_header header;
  int status;
} Placed;

static void place(sandbox *session, const Placed *placed)
{
  if (in_memory(session, placed->address, placed->length))
    memcpy(session->env.memory.data + placed->address, placed->data, placed->length);
}

static void read_placed_header(sandbox *session, void *argument)
{
  Placed *placed = argument;

  place(session, placed);
  placed->status = read_header(session, placed->address, &placed->header);
}

static void read_placed_output(sandbox *session, void *argument)
{
  Placed *placed = argument;
  sandbox_image image;

  place(session, placed);
  session->header.format = placed->format;
  placed->status = read_output(session, placed->address, placed->width, placed->height, &image);
  if (placed->status == 0) {
    free(image.pixels);
    free(image.icc);
    free(image.exif);
  }
}

static int run_test(const sandbox_limits *limits, size_t size, Call call, void *argument, char *message)
{
  sandbox *session;
  int status = start(limits, size, &session);

  message[0] = 0;
  if (status == 0)
    status = guarded(session, call, argument);
  if (session)
    memcpy(message, session->message, SANDBOX_MESSAGE_SIZE);
  sandbox_close(session);
  return status;
}

int sandbox_load(const sandbox_limits *limits, uint32_t address, uint32_t *value, char *message)
{
  Test test = {address, 0};
  int status = run_test(limits, 0, load, &test, message);

  *value = test.value;
  return status;
}

int sandbox_spin(const sandbox_limits *limits, char *message)
{
  Test test = {0, 0};

  return run_test(limits, 0, spin, &test, message);
}

int sandbox_tree(const sandbox_limits *limits, uint32_t depth, uint32_t *value, char *message)
{
  Test test = {depth, 0};
  int status = run_test(limits, 0, tree, &test, message);

  *value = test.value;
  return status;
}

int sandbox_read_header(const sandbox_limits *limits, uint32_t address, const uint8_t *data, uint32_t length, sandbox_header *header, char *message)
{
  Placed placed = {.address = address, .length = length, .data = data};
  int status = run_test(limits, 0, read_placed_header, &placed, message);

  *header = placed.header;
  return status ? status : placed.status;
}

int sandbox_read_output(const sandbox_limits *limits, uint32_t size, uint32_t format, uint32_t width, uint32_t height, uint32_t address,
                        const uint8_t *data, uint32_t length, char *message)
{
  Placed placed = {.address = address, .length = length, .format = format, .width = width, .height = height, .data = data};
  int status = run_test(limits, size, read_placed_output, &placed, message);

  return status ? status : placed.status;
}
