// The lock screen check of test.sh (t_lock_unlock): locks the screen, then
// unlocks it as the user would, typing PASSWORD (lowercase letters and
// digits only) into GNOME Shell's unlock dialog through Mutter's
// RemoteDesktop API. Exits 0 once the screen is unlocked, 1 on failure.
// Usage: gjs unlock-probe.js PASSWORD

const {Gio, GLib} = imports.gi;
const System = imports.system;
const bus = Gio.DBus.session;
const SS = 'org.gnome.ScreenSaver';
const RD = 'org.gnome.Mutter.RemoteDesktop';
const KEY_Return = 0xff0d;
const password = ARGV[0];

function call(dest, path, iface, method, args = null, ret = null) {
    const reply = bus.call_sync(dest, path, iface, method, args,
        ret ? new GLib.VariantType(ret) : null, Gio.DBusCallFlags.NONE, 10000, null);
    return reply.deepUnpack();
}

function spin(ms, until = () => false) {
    const ctx = GLib.MainContext.default();
    const end = GLib.get_monotonic_time() + ms * 1000;
    while (!until() && GLib.get_monotonic_time() < end) {
        if (!ctx.iteration(false))
            GLib.usleep(10000);
    }
    return until();
}

// Fails once the shell is gone, as when GDM ends the session on unlocking
function locked() {
    const [active] = call(SS, '/org/gnome/ScreenSaver', SS, 'GetActive', null, '(b)');
    return active;
}

let rdSession;
function cleanup() {
    try {
        call(RD, rdSession, `${RD}.Session`, 'Stop');
    } catch {}
}

function fail(message) {
    print(message);
    cleanup();
    System.exit(1);
}

function press(keysym) {
    for (const state of [true, false])
        call(RD, rdSession, `${RD}.Session`, 'NotifyKeyboardKeysym', new GLib.Variant('(ub)', [keysym, state]));
    spin(100);
}

if (!/^[a-z0-9]+$/.test(password ?? ''))
    fail('usage: unlock-probe.js PASSWORD (lowercase letters and digits)');

try {
    [rdSession] = call(RD, '/org/gnome/Mutter/RemoteDesktop', RD, 'CreateSession', null, '(o)');
    call(RD, rdSession, `${RD}.Session`, 'Start');
} catch (e) {
    fail(`cannot start a RemoteDesktop session to type the password: ${e.message}`);
}

try {
    call(SS, '/org/gnome/ScreenSaver', SS, 'Lock');
    if (!spin(10000, locked))
        fail('the screen did not lock');
    // Let the lock screen's animation finish
    spin(3000);

    // Return raises the unlock dialog from the clock, which starts a GDM
    // reauthentication; then the password goes into its entry
    press(KEY_Return);
    spin(3000);
    for (const c of password)
        press(c.codePointAt(0));
    press(KEY_Return);
    if (!spin(30000, () => !locked()))
        fail('the screen is still locked 30 s after entering the password');
} catch (e) {
    fail(`lost GNOME Shell while unlocking: ${e.message}`);
}
cleanup();
