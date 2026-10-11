#!/bin/sh
set -eu
cd "$(dirname "$0")"
# Set WASM_CC to clang from wasi-sdk, or use a clang with wasm-ld on PATH.
"${WASM_CC:-clang}" --target=wasm32 -O2 -ffreestanding -fno-builtin -DNDEBUG \
  -nostdlib -Iinclude -Isrc decoder.c src/lzfse_decode_base.c \
  src/lzfse_fse.c src/lzvn_decode_base.c \
  -Wl,--no-entry -Wl,--strip-all -Wl,--export=decode \
  -Wl,--export=input_address -Wl,--export=output_address \
  -Wl,--initial-memory=20971520 -Wl,--max-memory=25165824 \
  -o decoder.wasm
