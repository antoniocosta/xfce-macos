/* desktop-switch next|prev: move one desktop over, without wrapping around (like macOS).
 *
 * When picom runs (desktop-slide on), the windows leaving and arriving are first marked with
 * _MAC_SLIDE = fwd/back so picom slides them the right way; the marks go again after the slide, so
 * switches from elsewhere (Cmd+Tab, Mission Control, the Dock) stay instant.
 *
 * Fast repeats (two quick swipes, a held key) each count: the target of a switch that has been asked
 * for but not yet arrived is kept on the root window for a moment, and the next switch goes on from
 * there instead of from the desktop you are still on. The newest switch clears the marks, whoever
 * set them.
 *
 * One X connection does it all: no process per window, so it is done in a few milliseconds.
 */
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SLIDE_MS 600          /* the marks stay this long */
#define PENDING_MS 700        /* a switch asked for this recently has not necessarily arrived */

static Display *dpy;
static Window root;
static Atom A_CLIENTS, A_CLIENTS_PLAIN, A_DESK, A_NDESK, A_CURDESK, A_SLIDE, A_TARGET, A_GEN;

static int ignore_errors(Display *d, XErrorEvent *e) { (void)d; (void)e; return 0; }

static unsigned long now32(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (unsigned long)((t.tv_sec * 1000UL + t.tv_nsec / 1000000UL) & 0xFFFFFFFFUL);
}

static unsigned char *get_prop(Window w, Atom prop, Atom type, unsigned long *n) {
    Atom real; int fmt; unsigned long after; unsigned char *data = NULL;
    *n = 0;
    if (XGetWindowProperty(dpy, w, prop, 0, 1 << 16, False, type, &real, &fmt, n, &after, &data) != Success) return NULL;
    if (!data || !*n) { if (data) XFree(data); *n = 0; return NULL; }
    return data;
}

static long get_card(Window w, Atom prop, long dflt) {
    unsigned long n; long *v = (long *)get_prop(w, prop, XA_CARDINAL, &n);
    long r = (v && n) ? v[0] : dflt;
    if (v) XFree(v);
    return r;
}

static Window *client_list(unsigned long *n) {
    Window *l = (Window *)get_prop(root, A_CLIENTS, XA_WINDOW, n);
    return l ? l : (Window *)get_prop(root, A_CLIENTS_PLAIN, XA_WINDOW, n);
}

static void set_card(Atom prop, long v) {
    XChangeProperty(dpy, root, prop, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&v, 1);
}

int main(int argc, char **argv) {
    int dir = argc > 1 ? (!strcmp(argv[1], "next") ? 1 : !strcmp(argv[1], "prev") ? -1 : 0) : 0;
    if (!dir) { fprintf(stderr, "usage: desktop-switch next|prev\n"); return 1; }
    dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "desktop-switch: cannot open display\n"); return 1; }
    XSetErrorHandler(ignore_errors);
    root = DefaultRootWindow(dpy);
    A_CLIENTS = XInternAtom(dpy, "_NET_CLIENT_LIST_STACKING", False);
    A_CLIENTS_PLAIN = XInternAtom(dpy, "_NET_CLIENT_LIST", False);
    A_DESK = XInternAtom(dpy, "_NET_WM_DESKTOP", False);
    A_NDESK = XInternAtom(dpy, "_NET_NUMBER_OF_DESKTOPS", False);
    A_CURDESK = XInternAtom(dpy, "_NET_CURRENT_DESKTOP", False);
    A_SLIDE = XInternAtom(dpy, "_MAC_SLIDE", False);
    A_TARGET = XInternAtom(dpy, "_MAC_SLIDE_TARGET", False);   /* {to, time, from}: a switch on its way */
    A_GEN = XInternAtom(dpy, "_MAC_SLIDE_GEN", False);         /* counts the switches: the newest clears the marks */

    long cur = get_card(root, A_CURDESK, 0), n = get_card(root, A_NDESK, 1), base = cur;
    long from = cur;
    unsigned long cnt; long *tg = (long *)get_prop(root, A_TARGET, XA_CARDINAL, &cnt);
    if (tg && cnt >= 3 && ((now32() - (unsigned long)tg[1]) & 0xFFFFFFFFUL) < PENDING_MS &&
        tg[0] >= 0 && tg[0] < n && tg[2] >= 0 && tg[2] < n &&
        cur >= (tg[0] < tg[2] ? tg[0] : tg[2]) && cur <= (tg[0] < tg[2] ? tg[2] : tg[0])) {
        base = tg[0];          /* an earlier switch is still on its way (we are between where it started and where it goes) */
        from = tg[2];
    }
    if (tg) XFree(tg);
    long t = base + dir;
    if (t < 0 || t >= n) return 0;                      /* never wraps around */

    long target[3] = {t, (long)now32(), from};          /* {where to, when, where it started} */
    XChangeProperty(dpy, root, A_TARGET, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)target, 3);
    long gen = get_card(root, A_GEN, 0) + 1;
    set_card(A_GEN, gen);

    const char *way = dir > 0 ? "fwd" : "back";
    unsigned long nw; Window *list = client_list(&nw);
    for (unsigned long i = 0; list && i < nw; i++) {    /* the windows leaving and arriving slide; any old mark goes */
        long d = get_card(list[i], A_DESK, -1);
        if (d == cur || d == t)
            XChangeProperty(dpy, list[i], A_SLIDE, XA_STRING, 8, PropModeReplace, (const unsigned char *)way, (int)strlen(way));
        else
            XDeleteProperty(dpy, list[i], A_SLIDE);
    }
    if (list) XFree(list);
    XSync(dpy, False);
    usleep(30000);                                      /* let picom see the marks before the switch */

    XEvent e = {0};
    e.xclient.type = ClientMessage; e.xclient.window = root; e.xclient.message_type = A_CURDESK; e.xclient.format = 32;
    e.xclient.data.l[0] = t; e.xclient.data.l[1] = CurrentTime;
    XSendEvent(dpy, root, False, SubstructureRedirectMask | SubstructureNotifyMask, &e);
    XSync(dpy, False);

    if (fork() != 0) return 0;                          /* the caller is free; a helper clears the marks after the slide */
    close(ConnectionNumber(dpy));
    setsid();
    usleep(SLIDE_MS * 1000);
    dpy = XOpenDisplay(NULL);
    if (!dpy) return 0;
    XSetErrorHandler(ignore_errors);
    if (get_card(root, A_GEN, 0) != gen) return 0;      /* a newer switch took over: it clears them */
    list = client_list(&nw);
    for (unsigned long i = 0; list && i < nw; i++) XDeleteProperty(dpy, list[i], A_SLIDE);
    if (list) XFree(list);
    XSync(dpy, False);
    return 0;
}
