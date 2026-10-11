export function lzfseDecoder(module) {
  // Instances are short-lived: no 20 MiB decoder buffer remains in the object
  // between alarms. One instance handles all chunks of the selected rendition.
  const { exports } = new WebAssembly.Instance(module);
  return (input, maximum) => {
    if (input.length > 2 * 1024 * 1024 || maximum < 1 || maximum > 16 * 1024 * 1024) throw new Error('LZFSE_LIMIT');
    new Uint8Array(exports.memory.buffer, exports.input_address(), input.length).set(input);
    const length = exports.decode(input.length, maximum);
    if (!length) throw new Error('LZFSE_INVALID');
    return new Uint8Array(exports.memory.buffer, exports.output_address(), length).slice();
  };
}
