#include "lzfse_internal.h"

// Fixed buffers bound both compressed input and decoder output. No allocator,
// filesystem, network, or WASI imports are required by the Worker.
static uint8_t input[2 * 1024 * 1024];
static uint8_t output[16 * 1024 * 1024];
static lzfse_decoder_state state;

void *memcpy(void *dst, const void *src, size_t n) {
  uint8_t *d = dst; const uint8_t *s = src;
  for (size_t i = 0; i < n; i++) d[i] = s[i];
  return dst;
}
void *memmove(void *dst, const void *src, size_t n) {
  uint8_t *d = dst; const uint8_t *s = src;
  if (d < s) for (size_t i = 0; i < n; i++) d[i] = s[i];
  else for (size_t i = n; i > 0; i--) d[i - 1] = s[i - 1];
  return dst;
}
void *memset(void *dst, int value, size_t n) {
  uint8_t *d = dst;
  for (size_t i = 0; i < n; i++) d[i] = value;
  return dst;
}
uint8_t *input_address(void) { return input; }
uint8_t *output_address(void) { return output; }
size_t decode(size_t input_size, size_t output_size) {
  if (input_size > sizeof(input) || output_size > sizeof(output)) return 0;
  memset(&state, 0, sizeof(state));
  state.src = state.src_begin = input;
  state.src_end = input + input_size;
  state.dst = state.dst_begin = output;
  state.dst_end = output + output_size;
  if (lzfse_decode(&state) != LZFSE_STATUS_OK || state.src != state.src_end) return 0;
  return state.dst - output;
}
