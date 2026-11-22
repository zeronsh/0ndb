import { readFileSync } from "node:fs";
import { webcrypto } from "node:crypto";

const bytes = readFileSync(process.argv[2]);
let memory = null;
let text = "";
const decoder = new TextDecoder();
const env = {
  write: (fd, ptr, len) => {
    const s = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
    text += s;
    (fd === 2 ? process.stderr : process.stdout).write(s);
  },
  time_now: () => BigInt(Date.now()),
  tick_now: () => performance.now(),
  rand_bytes: (ptr, len) => webcrypto.getRandomValues(new Uint8Array(memory.buffer, ptr, len)),
};
const { instance } = await WebAssembly.instantiate(bytes, { odin_env: env });
memory = instance.exports.memory;
instance.exports._start();
if (instance.exports._end) {
  instance.exports._end();
}
const m = /(\d+) vectors, (\d+) failed/.exec(text);
process.exit(m && m[2] === "0" && m[1] !== "0" ? 0 : 1);
