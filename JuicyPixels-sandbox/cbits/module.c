#include "wasm-rt.h"

#define wasm_rt_call_stack_depth (*w2c_image_depth(instance))
#define wasm_rt_grow_memory sandbox_grow_memory

uint64_t sandbox_grow_memory(wasm_rt_memory_t *memory, uint64_t delta);

#include "image-wasm.c"
