#include "webp-wasm.c"
#include "sandbox-env.h"

void w2c_env_log_execution(struct w2c_env *env, u32 id)
{
  (void)id;
  if (--env->counter < 0)
    env->counter = w2c_env_refuel(env);
}
