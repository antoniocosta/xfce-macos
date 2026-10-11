/* show-desktop: like macOS, per desktop. Hides the windows on THIS desktop only, and a second call
 * brings back exactly those. Xfce's own "show desktop" is global: it hides every desktop's windows and
 * stays on as you switch, so an empty desktop would empty the others.
 *
 *   show-desktop             toggle (corner, shortcut)
 *   show-desktop --hide      only hide (spread the thumb and fingers)
 *   show-desktop --restore   only bring back (pinch them in again)
 *
 *   - nothing to hide (an empty desktop): does nothing
 *   - a full-screen app is its own Space with no desktop behind it: does nothing
 *   - the windows it hid carry a mark (_MACOS_SHOW_DESKTOP) on themselves, not a list kept by desktop
 *     number: desktops get renumbered (full-screen Spaces, Mission Control) and the windows go with
 *     their desktop, so the marks stay right. Only marked windows that are still minimized come back,
 *     the one that had the focus last so it keeps it.
 */
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static Display *dpy;
static Window root;
static Atom A_CLIENTS, A_CLIENTS_PLAIN, A_ACTIVE, A_STATE, A_HIDDEN, A_FULL, A_DESK, A_CURDESK, A_TYPE,
    A_TYPE_DOCK, A_TYPE_DESKTOP, A_MARK;

static int ignore_errors(Display *d, XErrorEvent *e) { (void)d; (void)e; return 0; }

static unsigned char *get_prop(Window w, Atom prop, Atom type, unsigned long *n) {
    Atom real; int fmt; unsigned long after; unsigned char *data = NULL;
    *n = 0;
    if (XGetWindowProperty(dpy, w, prop, 0, 4096, False, type, &real, &fmt, n, &after, &data) != Success) return NULL;
    if (!data || !*n) { if (data) XFree(data); *n = 0; return NULL; }
    return data;
}

static long get_card(Window w, Atom prop, long dflt) {
    unsigned long n; long *v = (long *)get_prop(w, prop, XA_CARDINAL, &n);
    long r = (v && n) ? v[0] : dflt;
    if (v) XFree(v);
    return r;
}

static int has_state(Window w, Atom a) {
    unsigned long n; Atom *s = (Atom *)get_prop(w, A_STATE, XA_ATOM, &n);
    int found = 0;
    for (unsigned long i = 0; i < n; i++) if (s[i] == a) found = 1;
    if (s) XFree(s);
    return found;
}

static int is_type(Window w, Atom type) {
    unsigned long n; Atom *t = (Atom *)get_prop(w, A_TYPE, XA_ATOM, &n);
    int is = t && n && t[0] == type;
    if (t) XFree(t);
    return is;
}

static void activate(Window w) {      /* source 2: a pager/tool, which the window manager obeys */
    XEvent e = {0};
    e.xclient.type = ClientMessage; e.xclient.window = w; e.xclient.message_type = A_ACTIVE; e.xclient.format = 32;
    e.xclient.data.l[0] = 2; e.xclient.data.l[1] = CurrentTime;
    XSendEvent(dpy, root, False, SubstructureRedirectMask | SubstructureNotifyMask, &e);
}

int main(int argc, char **argv) {
    int do_hide = 1, do_restore = 1;
    if (argc > 1) {
        if (!strcmp(argv[1], "--hide")) do_restore = 0;
        else if (!strcmp(argv[1], "--restore")) do_hide = 0;
        else { fprintf(stderr, "usage: %s [--hide|--restore]\n", argv[0]); return 1; }
    }
    dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "show-desktop: cannot open display\n"); return 1; }
    XSetErrorHandler(ignore_errors);
    root = DefaultRootWindow(dpy);
    A_CLIENTS = XInternAtom(dpy, "_NET_CLIENT_LIST_STACKING", False);
    A_CLIENTS_PLAIN = XInternAtom(dpy, "_NET_CLIENT_LIST", False);
    A_ACTIVE = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
    A_STATE = XInternAtom(dpy, "_NET_WM_STATE", False);
    A_HIDDEN = XInternAtom(dpy, "_NET_WM_STATE_HIDDEN", False);
    A_FULL = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
    A_DESK = XInternAtom(dpy, "_NET_WM_DESKTOP", False);
    A_CURDESK = XInternAtom(dpy, "_NET_CURRENT_DESKTOP", False);
    A_TYPE = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
    A_TYPE_DOCK = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DOCK", False);
    A_TYPE_DESKTOP = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DESKTOP", False);
    A_MARK = XInternAtom(dpy, "_MACOS_SHOW_DESKTOP", False);

    {   /* Mission Control open (it is a top-level window of ours named so): the corner must not act behind it */
        Window r, p, *kids = NULL; unsigned int nk = 0;
        if (XQueryTree(dpy, root, &r, &p, &kids, &nk)) {
            for (unsigned int i = 0; i < nk; i++) {
                char *name = NULL; XWindowAttributes wa;
                if (XFetchName(dpy, kids[i], &name) && name) {
                    int mc = !strcmp(name, "Mission Control") && XGetWindowAttributes(dpy, kids[i], &wa) && wa.map_state == IsViewable;
                    XFree(name);
                    if (mc) { XFree(kids); return 0; }
                }
            }
            if (kids) XFree(kids);
        }
    }
    unsigned long n;                                       /* stacking order if there is one (it vanishes with no windows) */
    Window *list = (Window *)get_prop(root, A_CLIENTS, XA_WINDOW, &n);
    if (!list) list = (Window *)get_prop(root, A_CLIENTS_PLAIN, XA_WINDOW, &n);
    long cur = get_card(root, A_CURDESK, 0);
    unsigned long na; Window *act = (Window *)get_prop(root, A_ACTIVE, XA_WINDOW, &na);
    Window active = (act && na) ? act[0] : None;
    if (act) XFree(act);

    /* windows we hid on this desktop earlier: the ones still minimized come back */
    int back = 0;
    for (int pass = 1; pass <= 2 && do_restore; pass++) {    /* pass 1: the others, pass 2: the one that had the focus */
        for (unsigned long i = 0; list && i < n; i++) {
            long mark = get_card(list[i], A_MARK, 0);
            if (!mark || get_card(list[i], A_DESK, -1) != cur) continue;
            if (!has_state(list[i], A_HIDDEN)) { if (pass == 1) XDeleteProperty(dpy, list[i], A_MARK); continue; }  /* you brought it back yourself */
            if (mark == pass) { activate(list[i]); back = 1; XDeleteProperty(dpy, list[i], A_MARK); }
        }
    }
    if (back || !do_hide) { XSync(dpy, False); return 0; }

    /* otherwise hide this desktop's windows */
    Window todo[512]; int k = 0;
    for (unsigned long i = 0; list && i < n && k < 512; i++) {
        Window w = list[i];
        if (get_card(w, A_DESK, -1) != cur || is_type(w, A_TYPE_DOCK) || is_type(w, A_TYPE_DESKTOP)) continue;
        if (has_state(w, A_FULL)) return 0;                  /* a Space: nothing to show */
        if (has_state(w, A_HIDDEN)) continue;                /* already minimized by you */
        todo[k++] = w;
    }
    for (int i = 0; i < k; i++) {
        long one = todo[i] == active ? 2 : 1;
        XChangeProperty(dpy, todo[i], A_MARK, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&one, 1);
        XIconifyWindow(dpy, todo[i], DefaultScreen(dpy));
    }
    XSync(dpy, False);
    return 0;
}
