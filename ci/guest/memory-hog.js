// The memory pressure check of ci/guest/test.sh: a runaway app that takes
// 64 MiB more memory at a time until it is killed. Every page holds the
// same byte, which zram stores without compressing it, so swap fills as
// fast as RAM does and the VM does not thrash on the way.
//
// It takes 64 MiB every 200 ms (320 MiB/s). earlyoom sleeps up to a second
// between checks, expecting swap to fill at most at 800 MiB/s, and only
// acts once both memory and swap are below 10 %; unpaced, this app filled
// the swap's last 10 % (800 MiB) in about half a second, so earlyoom
// missed it about as often as not and the kernel's OOM killer acted first.
// Paced, that takes 2.5 s. A real app cannot fill swap much faster: its
// pages have to be compressed, or written to disk.

const GLib = imports.gi.GLib;

const chunks = [];
for (;;) {
    const chunk = new Uint8Array(64 * 1024 * 1024);
    chunk.fill(1);
    chunks.push(chunk);
    GLib.usleep(200 * 1000);
}
