// The logout check of features.sh (t_logout_not_blocked_by_shell): starts a
// logout, lists the GNOME Shell inhibitors while the dialog is up, then
// cancels it. Exits 0 on success, 1 on failure and 2 when it cannot run.

const {Gio, GLib} = imports.gi;
const System = imports.system;
const bus = Gio.DBus.session;
const SM = 'org.gnome.SessionManager';
const RD = 'org.gnome.Mutter.RemoteDesktop';
const KEY_Escape = 0xff1b;

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

let rdSession;
try {
    [rdSession] = call(RD, '/org/gnome/Mutter/RemoteDesktop', RD, 'CreateSession', null, '(o)');
    call(RD, rdSession, `${RD}.Session`, 'Start');
} catch (e) {
    print(`cannot start a RemoteDesktop session to cancel the logout: ${e.message}`);
    System.exit(2);
}

const [client] = call(SM, '/org/gnome/SessionManager', SM, 'RegisterClient',
    new GLib.Variant('(ss)', ['os-feature-tests', '']), '(o)');
let queried = false, canceled = false, ended = false;
bus.signal_subscribe(null, `${SM}.ClientPrivate`, null, client, null, Gio.DBusSignalFlags.NONE,
    (_c, _sender, _path, _iface, signal) => {
        if (signal === 'QueryEndSession') {
            queried = true;
            call(SM, client, `${SM}.ClientPrivate`, 'EndSessionResponse',
                new GLib.Variant('(bs)', [false, 'os-feature-tests: logout probe']));
        } else if (signal === 'CancelEndSession') {
            canceled = true;
        } else if (signal === 'EndSession') {
            ended = true;
        }
    });

function cleanup() {
    try {
        call(SM, '/org/gnome/SessionManager', SM, 'UnregisterClient', new GLib.Variant('(o)', [client]));
    } catch {}
    try {
        call(RD, rdSession, `${RD}.Session`, 'Stop');
    } catch {}
}

try {
    call(SM, '/org/gnome/SessionManager', SM, 'Logout', new GLib.Variant('(u)', [0]));
} catch (e) {
    print(`cannot start a logout: ${e.message}`);
    cleanup();
    System.exit(1);
}
if (!spin(5000, () => queried)) {
    print('gnome-session did not query clients on logout');
    cleanup();
    System.exit(1);
}
// Unanswered queries turn into inhibitors after 1 s; then the dialog opens
spin(3000);

const blockers = [];
const [inhibitors] = call(SM, '/org/gnome/SessionManager', SM, 'GetInhibitors', null, '(ao)');
for (const path of inhibitors) {
    const iface = `${SM}.Inhibitor`;
    try {
        const [appId] = call(SM, path, iface, 'GetAppId', null, '(s)');
        const [reason] = call(SM, path, iface, 'GetReason', null, '(s)');
        const [flags] = call(SM, path, iface, 'GetFlags', null, '(u)');
        if (flags & 1 && /gnome-shell|org\.gnome\.Shell/i.test(appId))
            blockers.push(`${appId} (${reason})`);
    } catch {}
}

for (let i = 0; i < 5 && !canceled && !ended; i++) {
    for (const state of [true, false])
        call(RD, rdSession, `${RD}.Session`, 'NotifyKeyboardKeysym', new GLib.Variant('(ub)', [KEY_Escape, state]));
    spin(2000, () => canceled || ended);
}
cleanup();

if (!canceled) {
    print('could not cancel the logout dialog: the session may log out');
    System.exit(1);
}
if (blockers.length > 0) {
    print(`logout blocked by GNOME Shell: ${blockers.join(', ')}`);
    System.exit(1);
}
