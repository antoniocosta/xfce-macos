/* spaces.h: what `fullscreen` and `mission-control` share about desktops.
 *
 * Both programs change the desktop layout (a full-screen app gets a Space; Mission Control adds,
 * removes and reorders desktops), and both do it by asking the window manager with a client
 * message. The window manager answers a moment later. Reading a window's desktop right after
 * asking still gives the old answer, and acting on that is the source of most desktop bugs. So:
 *   - sp_wait_card waits until the window manager has really done it, and
 *   - the Spaces waiting to be removed live in one root property, not in each program's memory,
 *     so whoever renumbers desktops renumbers that list too.
 */
#ifndef SPACES_H
#define SPACES_H

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SP_MAX 16                  /* macOS allows 16 Spaces per display */
#define SP_WAIT_MS 600             /* how long the window manager gets to do what it was asked */

/* a sticky window has no single desktop (Xlib hands 0xFFFFFFFF back as -1 or as 4294967295) */
static inline int sp_sticky(long d) { return d < 0 || d == 0xFFFFFFFFL; }

static inline long sp_card(Display *dpy, Window w, Atom prop, long dflt) {
    Atom real; int fmt; unsigned long n = 0, after; unsigned char *data = NULL; long r = dflt;
    if (XGetWindowProperty(dpy, w, prop, 0, 1, False, XA_CARDINAL, &real, &fmt, &n, &after, &data) == Success
        && data && n && fmt == 32)
        r = *(long *)data;
    if (data) XFree(data);
    return r;
}

/* wait (at most `ms`) until a CARDINAL property has the value the window manager was asked to set */
static inline int sp_wait_card(Display *dpy, Window w, Atom prop, long want, int ms) {
    for (int t = 0; t <= ms; t += 3) {
        XSync(dpy, False);
        long v = sp_card(dpy, w, prop, -2);
        if (v == want || (want < 0 && sp_sticky(v))) return 1;
        usleep(3000);
    }
    return 0;
}

/* The Spaces that are empty and waiting to be removed (desktop numbers), kept on the root window. */
static inline int sp_pending_read(Display *dpy, Window root, Atom prop, long *out, int max) {
    Atom real; int fmt; unsigned long n = 0, after; unsigned char *data = NULL; int k = 0;
    if (XGetWindowProperty(dpy, root, prop, 0, SP_MAX, False, XA_CARDINAL, &real, &fmt, &n, &after, &data) == Success
        && data && fmt == 32)
        for (unsigned long i = 0; i < n && k < max; i++) out[k++] = ((long *)data)[i];
    if (data) XFree(data);
    return k;
}

static inline void sp_pending_write(Display *dpy, Window root, Atom prop, const long *v, int n) {
    if (n <= 0) XDeleteProperty(dpy, root, prop);
    else XChangeProperty(dpy, root, prop, XA_CARDINAL, 32, PropModeReplace, (const unsigned char *)v, n);
}

/* desktops were renumbered (`map[old]` = new number, -1 = gone): renumber the pending list to match */
static inline void sp_pending_remap(Display *dpy, Window root, Atom prop, const long *map, int nmap) {
    long p[SP_MAX], q[SP_MAX]; int n = sp_pending_read(dpy, root, prop, p, SP_MAX), k = 0;
    for (int i = 0; i < n; i++)
        if (p[i] >= 0 && p[i] < nmap && map[p[i]] >= 0) q[k++] = map[p[i]];
    sp_pending_write(dpy, root, prop, q, k);
}

/* "I am rearranging desktops": set while Mission Control moves windows between desktops, so the
 * repair pass in `fullscreen` never mistakes a half-done change for bad bookkeeping. The value is a
 * time, so one left behind by a crash stops counting after a few seconds. */
static inline long sp_now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

static inline void sp_busy_set(Display *dpy, Window root, Atom prop, int on) {
    long now = sp_now_ms();
    if (on) XChangeProperty(dpy, root, prop, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&now, 1);
    else XDeleteProperty(dpy, root, prop);
    XFlush(dpy);
}

static inline int sp_is_busy(Display *dpy, Window root, Atom prop) {
    long v = sp_card(dpy, root, prop, -1);
    return v >= 0 && sp_now_ms() - v < 3000;
}

/* end the string at byte `at`, but never in the middle of a UTF-8 character (cairo refuses a broken one
 * for good, and everything drawn after it vanishes) */
static inline void sp_utf8_cut(char *s, size_t at) {
    while (at > 0 && (((unsigned char)s[at]) & 0xC0) == 0x80) at--;
    s[at] = 0;
}

/* copy src into dst (n bytes), cutting a too-long string between characters, not inside one */
static inline void sp_copy_utf8(char *dst, size_t n, const char *src) {
    size_t len = strlen(src);
    if (!n) return;
    if (len < n) { memcpy(dst, src, len + 1); return; }
    size_t at = n - 1;
    while (at > 0 && (((unsigned char)src[at]) & 0xC0) == 0x80) at--;
    memcpy(dst, src, at);
    dst[at] = 0;
}

#endif
