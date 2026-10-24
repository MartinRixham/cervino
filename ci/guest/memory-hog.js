// The memory pressure check of ci/guest/test.sh: a runaway app that takes
// 64 MiB more memory at a time until it is killed. Every page holds the
// same byte, which zram stores without compressing it, so swap fills as
// fast as RAM does and the VM does not thrash on the way.

const chunks = [];
for (;;) {
    const chunk = new Uint8Array(64 * 1024 * 1024);
    chunk.fill(1);
    chunks.push(chunk);
}
