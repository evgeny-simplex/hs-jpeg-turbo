#!/usr/bin/env bash

set -euo pipefail

dir=$(mktemp -d)

cat > "$dir/HAVE_VLD1_S16_X3.c" <<'EOF'
#include <arm_neon.h>
int main(int argc, char **argv) {
  int16_t input[12];
  int16x4x3_t output;
  int i;
  for (i = 0; i < 12; i++) input[i] = (int16_t)argc;
  output = vld1_s16_x3(input);
  vst3_s16(input, output);
  return (int)input[0];
}
EOF

cat > "$dir/HAVE_VLD1_U16_X2.c" <<'EOF'
#include <arm_neon.h>
int main(int argc, char **argv) {
  uint16_t input[8];
  uint16x4x2_t output;
  int i;
  for (i = 0; i < 8; i++) input[i] = (uint16_t)argc;
  output = vld1_u16_x2(input);
  vst2_u16(input, output);
  return (int)input[0];
}
EOF

cat > "$dir/HAVE_VLD1Q_U8_X4.c" <<'EOF'
#include <arm_neon.h>
int main(int argc, char **argv) {
  uint8_t input[64];
  uint8x16x4_t output;
  int i;
  for (i = 0; i < 64; i++) input[i] = (uint8_t)argc;
  output = vld1q_u8_x4(input);
  vst4q_u8(input, output);
  return (int)input[0];
}
EOF

cc --version
header=$(cc -dM -E -include jpeg-turbo/cbits/neon-compat.h -x c /dev/null)
status=0
for macro in HAVE_VLD1_S16_X3 HAVE_VLD1_U16_X2 HAVE_VLD1Q_U8_X4; do
  if cc "$dir/$macro.c" -o "$dir/$macro" 2> /dev/null; then probe=defined; else probe=undefined; fi
  if grep -qE "^#define $macro( |$)" <<< "$header"; then defined=defined; else defined=undefined; fi
  echo "$macro: probe $probe, neon-compat.h $defined"
  if [ "$probe" != "$defined" ]; then status=1; fi
done
exit $status
