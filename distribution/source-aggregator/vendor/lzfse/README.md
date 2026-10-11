# LZFSE decoder for Worker icon extraction

`src/` contains the decoder subset (only trailing whitespace normalized) of Apple's BSD-licensed
[lzfse/lzfse](https://github.com/lzfse/lzfse/tree/e634ca58b4821d9f3d560cdc6df5dec02ffc93fd),
commit `e634ca58b4821d9f3d560cdc6df5dec02ffc93fd`. The license is in `LICENSE`.
`decoder.c` and `include/` provide a freestanding adapter with fixed buffers;
`decoder.wasm` has no imports and requires no local service or WASI runtime.

Rebuild from the vendored sources with a clang supporting `wasm32` and
`wasm-ld`, such as [wasi-sdk](https://github.com/WebAssembly/wasi-sdk):

```sh
WASM_CC=/path/to/wasi-sdk/bin/clang sh vendor/lzfse/build.sh
```

The checked-in binary was built with wasi-sdk 34.0, `-O2`, and the flags in
`build.sh`. Input is limited to 2 MiB and output to 16 MiB. The adapter requires
successful termination of the entire input stream; truncated streams fail.
Each extraction instantiates a decoder only when an LZFSE rendition is needed.

The JavaScript CAR reader was implemented against the BOM/CSI and KCBC format
descriptions in [carfile-go](https://github.com/devcxm/carfile-go/blob/main/docs/assets-car-format.md).
It selects the logical primary icon from `FACETKEYS`/`RENDITIONS`, tries normal
iPhone variants first, and supports ARGB/GA8 pixels with stored, gzip, and LZFSE
payloads, including KCBC chunks. Unsupported renditions are skipped in favor
of another variant of the same primary icon. If no supported primary icon can
be decoded, the sync reports `ICON_EXTRACTION_FAILED` and retains the old version.
