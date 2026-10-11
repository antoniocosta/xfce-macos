/* fullscreen: macOS full-screen windows for X11 (Xfce).
 *
 * 1. The green button goes full screen. Clicking a window's maximize button (Xfce's, or an
 *    app's own like Firefox's, both on the left as on macOS) makes the window full screen
 *    instead of maximized.
 * 2. A full-screen window gets its own Space, like macOS: a new desktop after the last one, and
 *    you slide to it. Ctrl+arrows, the swipes and Mission Control reach it like any desktop.
 *    Leaving full screen takes the window back to its own desktop and removes the Space. A new
 *    window that opens while you're in the full-screen app (another app, a new browser window)
 *    goes to that desktop too, and you slide there: a Space belongs to its app alone. The app's
 *    own dialogs (save, open, print) stay on top of it.
 * 3. In full screen, rest the pointer at the top edge and the menu bar slides in with the
 *    window's title bar below it: red closes the window, green leaves full screen (yellow is
 *    greyed out, as on macOS). The global menu shows the full-screen app's own menus.
 *
 * How, cheaply: button presses arrive as XInput2 raw events (no polling, no grab, nothing taken
 * from other apps). A press in the top-left button area of a window, followed within a second by
 * that window's maximized state changing, means the maximize button was clicked. Window
 * positions are kept from move events, because a trackpad tap maximizes the window before the
 * press is handled. The pointer is only polled while the active window is full screen.
 *
 * The Dock: at the bottom edge the same applies to the dock (Plank): a tiny helper window takes
 * the focus while the dock is up, and gives it back when the pointer leaves it.
 *
 * The menu bar: Xfce keeps a focused full-screen window above the panel. While the title bar is
 * shown it takes the focus (carrying the app's menu properties, so the global menu stays the
 * app's), which lets the panel show above the window, and gives the focus back when it hides.
 * The full-screen window is alone on its Space, so nothing else can come up in between.
 *
 * The Space is inserted right after the window's own desktop, as on macOS, so the desktops after
 * it move up one (and back down when it goes). That never happens while a mouse button is held:
 * renumbering desktops under a window that is being dragged is what breaks things.
 *
 * For tests: FULLSCREEN_LOG=<file> logs what it does there.
 *
 * Usage: fullscreen [-G] [-P] [-S]   -G: leave the green button alone; -P: no menu/title bar
 *                                    at the top edge; -S: full-screen windows stay on their desktop
 *        fullscreen --dump           print the desktops, Spaces and windows as they are now
 */
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XInput2.h>
#include <cairo/cairo-xlib.h>
#include <math.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "../common/spaces.h"

#define MAX_CLIENTS 512
#define MAX_SPACES 16       /* macOS allows 16 Spaces per display, full-screen ones included */
#define BUTTON_ZONE_W 110   /* the window buttons sit in this many pixels from the left... */
#define CSD_TITLE_H 48      /* ...and, for apps that draw their own title bar, this far down */
#define CLICK_WINDOW_MS 1000
#define BAR_H 30
#define PEEK_DELAY_MS 250
#define POLL_FULL_MS 150
#define POLL_NEAR_MS 20
#define SLIDE_CLEAR_MS 600  /* desktop-slide marks are removed after the slide */

struct client {
    Window w;
    int maxed, full;
    int origin;             /* the desktop it came from, while it has a Space of its own; else -1 */
    int space;              /* the Space's desktop number, while it has one; else -1 */
    int geo[5];             /* frame x, y, width, height, title bar height */
};

static Display *dpy;
static Window root;
static Atom A_CLIENTS, A_CLIENTS_PLAIN, A_ACTIVE, A_STATE, A_FULL, A_HIDDEN, A_MAXV, A_MAXH, A_ABOVE, A_SKIP_TB, A_SKIP_PG,
    A_EXTENTS, A_CLOSE, A_NAME, A_UTF8, A_DESK, A_NDESK, A_CURDESK, A_TYPE, A_TYPE_DOCK, A_TYPE_NORMAL, A_SLIDE,
    A_MOTIF, A_ORIGIN, A_PENDING, A_BUSY;
static const char *MENU_PROPS[] = {   /* what the global menu reads from the active window */
    "_GTK_UNIQUE_BUS_NAME", "_GTK_MENUBAR_OBJECT_PATH", "_GTK_APPLICATION_OBJECT_PATH",
    "_GTK_WINDOW_OBJECT_PATH", "_GTK_APP_MENU_OBJECT_PATH", "_GTK_APPLICATION_ID",
    "_KDE_NET_WM_APPMENU_SERVICE_NAME", "_KDE_NET_WM_APPMENU_OBJECT_PATH", NULL};

static struct client cl[MAX_CLIENTS];
static int ncl;
static int green = 1, peek = 1, spaces = 1;

static Window clicked = None;        /* window whose button area was pressed last */
static long clicked_at;

static Window bar = None;            /* the title bar shown at the top edge */
static Window dock_helper = None;    /* takes the focus while the dock is up over a full-screen app */
static Window dock_for = None;       /* that app */
static long shown_at;                /* when the bar or the dock went up (focus takes a moment to move) */
#define FOCUS_GRACE_MS 600           /* a slow machine needs a while to hand over the focus */
static Window bar_for = None;        /* the full-screen window it belongs to */
static int bar_x, bar_y, bar_w;
static Window marked[MAX_CLIENTS];   /* windows carrying a desktop-slide mark */
static int nmarked;
static long marked_at;
static long trim_at = -1;            /* when to remove empty Spaces (after the switch has settled) */
static long check_at = -1;           /* when to check that the Spaces are in order (after changes settle) */
#define CHECK_DELAY_MS 200

static FILE *test_log;                   /* FULLSCREEN_LOG, for tests */
#define LOG(...) do { if (test_log) { fprintf(test_log, __VA_ARGS__); fputc('\n', test_log); fflush(test_log); } } while (0)

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

static int ignore_errors(Display *d, XErrorEvent *e) { (void)d; (void)e; return 0; }

static unsigned char *get_prop(Window w, Atom prop, Atom type, unsigned long *n) {
    Atom real; int fmt; unsigned long after; unsigned char *data = NULL;
    *n = 0;
    if (XGetWindowProperty(dpy, w, prop, 0, 4096, False, type, &real, &fmt, n, &after, &data) != Success)
        return NULL;
    if (!data || !*n) { if (data) XFree(data); *n = 0; return NULL; }
    return data;
}

static long get_card(Window w, Atom prop, long dflt) {
    unsigned long n; long *v = (long *)get_prop(w, prop, XA_CARDINAL, &n);
    long r = (v && n) ? v[0] : dflt;
    if (v) XFree(v);
    return r;
}

/* the managed windows, bottom to top. Xfce drops the stacking-order list once every window has
 * closed and only brings it back on a restack, but always keeps the plain list: use that then */
static Window *client_list(unsigned long *n) {
    Window *l = (Window *)get_prop(root, A_CLIENTS, XA_WINDOW, n);
    return l ? l : (Window *)get_prop(root, A_CLIENTS_PLAIN, XA_WINDOW, n);
}

static int has_state(Window w, Atom a) {
    unsigned long n; Atom *s = (Atom *)get_prop(w, A_STATE, XA_ATOM, &n);
    int found = 0;
    for (unsigned long i = 0; i < n; i++) if (s[i] == a) found = 1;
    if (s) XFree(s);
    return found;
}

static int is_maxed(Window w) { return has_state(w, A_MAXV) && has_state(w, A_MAXH); }

static Window active_window(void) {
    unsigned long n; Window *w = (Window *)get_prop(root, A_ACTIVE, XA_WINDOW, &n);
    Window r = (w && n) ? w[0] : None;
    if (w) XFree(w);
    return r;
}

static void client_msg(Window w, Atom type, long l0, long l1, long l2, long l3) {
    XEvent e = {0};
    e.xclient.type = ClientMessage;
    e.xclient.window = w;
    e.xclient.message_type = type;
    e.xclient.format = 32;
    e.xclient.data.l[0] = l0; e.xclient.data.l[1] = l1;
    e.xclient.data.l[2] = l2; e.xclient.data.l[3] = l3;
    XSendEvent(dpy, root, False, SubstructureRedirectMask | SubstructureNotifyMask, &e);
}

/* action: 0 remove, 1 add; source 2 = a pager/tool, which the window manager obeys */
static void send_state(Window w, long action, Atom a1, Atom a2) { client_msg(w, A_STATE, action, a1, a2, 2); }
static void close_window(Window w) { client_msg(w, A_CLOSE, CurrentTime, 2, 0, 0); }
static void activate(Window w) { client_msg(w, A_ACTIVE, 2, CurrentTime, 0, 0); }
static void move_to_desktop(Window w, long d) { client_msg(w, A_DESK, d, 2, 0, 0); }
static void set_desktops(long n) { client_msg(root, A_NDESK, n, 0, 0, 0); }
static void switch_desktop(long d) { client_msg(root, A_CURDESK, d, CurrentTime, 0, 0); }

/* The window manager does these a moment after being asked. Reading a desktop number back right
 * away gives the old one, and acting on that is how a Space's origin once became the Space itself.
 * So each change waits until it has really happened (a few milliseconds). */
static void move_wait(Window w, long d) { move_to_desktop(w, d); sp_wait_card(dpy, w, A_DESK, d, SP_WAIT_MS); }
static void set_desktops_wait(long n) { set_desktops(n); sp_wait_card(dpy, root, A_NDESK, n, SP_WAIT_MS); }
static void switch_wait(long d) { switch_desktop(d); sp_wait_card(dpy, root, A_CURDESK, d, SP_WAIT_MS); }

/* client geometry in root coordinates, extended by the window manager's frame */
static int frame_rect(Window w, int *x, int *y, int *wd, int *ht, int *top) {
    Window child, r; int cx, cy; unsigned int cw, ch, bw, depth;
    if (!XGetGeometry(dpy, w, &r, &cx, &cy, &cw, &ch, &bw, &depth)) return 0;
    if (!XTranslateCoordinates(dpy, w, root, 0, 0, &cx, &cy, &child)) return 0;
    unsigned long n; long *ext = (long *)get_prop(w, A_EXTENTS, XA_CARDINAL, &n);
    long l = 0, rr = 0, t = 0, b = 0;
    if (ext && n == 4) { l = ext[0]; rr = ext[1]; t = ext[2]; b = ext[3]; }
    if (ext) XFree(ext);
    *x = cx - l; *y = cy - t; *wd = cw + l + rr; *ht = ch + t + b; *top = t;
    return 1;
}

static struct client *find(Window w) {
    for (int i = 0; i < ncl; i++) if (cl[i].w == w) return &cl[i];
    return NULL;
}

static void update_geo(struct client *c) {
    if (!frame_rect(c->w, &c->geo[0], &c->geo[1], &c->geo[2], &c->geo[3], &c->geo[4]))
        c->geo[2] = c->geo[3] = 0;
}

/* ---- Spaces ------------------------------------------------------------------------------ */

/* The number of ordinary desktops (without full-screen Spaces), kept in a file so a restart or a
 * new login still knows how many desktops are Spaces. */
static char base_file[512];
static long pending[SP_MAX];         /* Spaces (desktop numbers) to remove once they are empty. The list
                                        lives on the root window too, so Mission Control renumbers it */
static int npending;

static void pend_load(void) { npending = sp_pending_read(dpy, root, A_PENDING, pending, SP_MAX); }
static void pend_save(void) { sp_pending_write(dpy, root, A_PENDING, pending, npending); }
static void pend_add(long d) {
    pend_load();
    for (int i = 0; i < npending; i++) if (pending[i] == d) return;
    if (npending < SP_MAX) pending[npending++] = d;
    pend_save();
}

static long read_base(void) {
    FILE *f = fopen(base_file, "r"); long b = -1;
    if (f) { if (fscanf(f, "%ld", &b) != 1) b = -1; fclose(f); }
    return b;
}

static void write_base(long b) {
    if (b < 0) { remove(base_file); return; }
    FILE *f = fopen(base_file, "w");
    if (f) { fprintf(f, "%ld\n", b); fclose(f); }
}

static long desk_of(Window w) { return get_card(w, A_DESK, -1); }

/* The desktop a full-screen window's Space came from. A Space always comes right after it, so an origin
 * that is not before the Space (it once ended up as the Space's own number) is bad bookkeeping: trusting
 * it would send new windows onto the full-screen app itself, hidden behind it. Use the desktop before the
 * Space instead. */
static long sane_origin(const struct client *c) {
    long space = c->space >= 0 ? c->space : desk_of(c->w);
    if (c->origin >= 0 && c->origin < space) return c->origin;
    return space > 0 ? space - 1 : 0;
}

static int desktop_empty(long d) {
    for (int i = 0; i < ncl; i++) if (desk_of(cl[i].w) == d) return 0;
    return 1;
}

static int button_held(void) {      /* never renumber desktops while something may be dragged */
    Window r, c; int x, y, wx, wy; unsigned int mask = 0;
    XQueryPointer(dpy, root, &r, &c, &x, &y, &wx, &wy, &mask);
    return (mask & (Button1Mask | Button2Mask | Button3Mask)) != 0;
}

static void set_origin(struct client *c, long o) {
    c->origin = (int)o;
    if (o < 0) XDeleteProperty(dpy, c->w, A_ORIGIN);
    else XChangeProperty(dpy, c->w, A_ORIGIN, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&o, 1);
}

/* desktop numbers from `from` on move by `by` (+1: a Space was inserted, -1: one was removed) */
static void renumber(long from, int by, Window except) {
    pend_load();
    for (int i = 0; i < ncl; i++) {
        struct client *c = &cl[i];
        long d = desk_of(c->w);
        if (c->w != except && d >= from && !sp_sticky(d)) move_wait(c->w, d + by);
        if (c->origin >= from) set_origin(c, c->origin + by);
        if (c->space >= from) c->space += by;
    }
    for (int i = 0; i < npending; i++) if (pending[i] >= from) pending[i] += by;
    pend_save();
}

/* remove the Spaces that were left (once empty), never an ordinary desktop */
static void trim_spaces(void) {
    if (button_held()) { trim_at = now_ms() + SLIDE_CLEAR_MS; return; }
    if (sp_is_busy(dpy, root, A_BUSY)) { trim_at = now_ms() + SLIDE_CLEAR_MS; return; }   /* Mission Control is at work */
    pend_load();
    long base = read_base();
    for (int k = 0; k < npending;) {
        long s = pending[k], n = get_card(root, A_NDESK, 0), cur = get_card(root, A_CURDESK, 0);
        if (base >= 0 && n <= base) { npending = 0; break; }
        int drop = s < 0 || s >= n;                        /* stale: that desktop is gone */
        if (!drop && (s == cur || !desktop_empty(s))) { k++; continue; }
        for (int m = k; m < npending - 1; m++) pending[m] = pending[m + 1];
        npending--;
        pend_save();                                       /* off the list first: renumbering adjusts the rest */
        if (drop) continue;
        LOG("remove empty Space %ld", s);
        if (cur > s) switch_wait(cur - 1);                 /* stay on the same windows */
        renumber(s + 1, -1, None);
        pend_load();
        set_desktops_wait(n - 1);
    }
    pend_save();
    long n = get_card(root, A_NDESK, 0);
    if (base >= 0 && n <= base) write_base(-1);
}

static void mark_slide(long desk, const char *dir) {   /* the desktop-slide marks (picom) */
    for (int i = 0; i < ncl && nmarked < MAX_CLIENTS; i++) {
        if (desk_of(cl[i].w) != desk) continue;
        XChangeProperty(dpy, cl[i].w, A_SLIDE, XA_STRING, 8, PropModeReplace,
                        (const unsigned char *)dir, strlen(dir));
        marked[nmarked++] = cl[i].w;
    }
    marked_at = now_ms();
}

static void clear_marks(void) {
    for (int i = 0; i < nmarked; i++) XDeleteProperty(dpy, marked[i], A_SLIDE);
    nmarked = 0;
}

/* full screen: a new Space right after the window's desktop, like macOS */
static void enter_space(struct client *c, int quiet) {   /* quiet: adopt a window already full screen
                                                            (at startup): no sliding, you stay put */
    long origin = desk_of(c->w);
    LOG("enter space 0x%lx from desktop %ld", c->w, origin);
    if (sp_sticky(origin)) return;                               /* sticky: stays where it is */
    if (quiet && origin > 0 && read_base() >= 0 && get_card(root, A_NDESK, 1) > read_base()) {
        int alone = 1;                                           /* a full-screen window alone on a desktop past the ordinary ones: */
        for (int i = 0; i < ncl; i++) if (cl[i].w != c->w && desk_of(cl[i].w) == origin) alone = 0;
        if (alone) {                                             /* it already has its Space (we were stopped half way through making it) */
            LOG("adopt 0x%lx: alone on desktop %ld past the ordinary desktops, so that is its Space", c->w, origin);
            set_origin(c, origin - 1);
            c->space = (int)origin;
            return;
        }
    }
    for (int i = 0; i < ncl; i++)                                /* it is on another app's Space already: that app's
                                                                    desktop is where this one comes from */
        if (cl[i].w != c->w && cl[i].origin >= 0 && cl[i].space == origin) { origin = sane_origin(&cl[i]); break; }
    long n = get_card(root, A_NDESK, 1), s = origin + 1;
    if (n >= MAX_SPACES) return;     /* at macOS's limit of 16 Spaces: full screen where it is */
    if (read_base() < 0) write_base(n);
    set_desktops_wait(n + 1);
    long here = get_card(root, A_CURDESK, 0);
    renumber(s, +1, c->w);                                       /* later desktops move up one */
    if (quiet) {
        move_wait(c->w, s);
        if (here >= s) switch_wait(here + 1);                    /* keep looking at the same windows */
    } else {
        mark_slide(origin, "fwd");
        XDeleteProperty(dpy, c->w, A_SLIDE);                     /* it appears, not slides */
        XSync(dpy, False);
        switch_wait(s);
        move_wait(c->w, s);
        activate(c->w);
    }
    set_origin(c, origin);
    c->space = (int)s;
}

/* leaving full screen (or closed): back to its own desktop; the Space goes once it is empty */
static void leave_space(struct client *c, int gone) {
    long origin = sane_origin(c), s = c->space, cur = get_card(root, A_CURDESK, 0);
    LOG("leave space 0x%lx (gone %d) back to %ld from space %ld", c->w, gone, origin, s);
    if (gone) c->origin = -1; else set_origin(c, -1);
    c->space = -1;
    if (!gone) move_wait(c->w, origin);
    if (cur != origin) {
        mark_slide(origin, "back");
        XSync(dpy, False);
        switch_wait(origin);
        if (!gone) activate(c->w);
    }
    if (s >= 0) pend_add(s);
    trim_at = now_ms() + SLIDE_CLEAR_MS;
    XSync(dpy, False);
}

/* ---- windows ----------------------------------------------------------------------------- */

/* a new window opened on a full-screen app's Space: send it to the desktop the app came from and
 * slide there (unless it's one of the app's own dialogs, which stay on top of it) */
static int is_dialog(Window w) {          /* an app's own dialog: it stays on top of the app */
    unsigned long n; Atom *t = (Atom *)get_prop(w, A_TYPE, XA_ATOM, &n);
    int normal = !t || t[0] == A_TYPE_NORMAL;
    if (t) XFree(t);
    Window for_w;
    return !normal || XGetTransientForHint(dpy, w, &for_w);
}

static struct client *space_owner(Window except, long d) {   /* the full-screen app whose Space is desktop d */
    struct client *owner = NULL;
    for (int i = 0; i < ncl; i++)
        if (cl[i].w != except && cl[i].origin >= 0 && cl[i].full && desk_of(cl[i].w) == d) owner = &cl[i];
    return owner;
}

static void keep_space_to_its_app(Window w) {
    long d = desk_of(w);
    if (w == bar || sp_sticky(d)) return;
    struct client *owner = space_owner(w, d);
    if (!owner) return;
    if (is_dialog(w)) { LOG("new window 0x%lx: a dialog, stays", w); return; }
    long origin = sane_origin(owner);
    if (origin != owner->origin) set_origin(owner, origin);        /* and put it right */
    LOG("new window 0x%lx on 0x%lx's Space: to desktop %ld", w, owner->w, origin);
    move_wait(w, origin);
    mark_slide(origin, "back");
    XSync(dpy, False);
    switch_wait(origin);
    activate(w);
}

/* Only one rule holds a Space together: nothing but its app (and that app's dialogs) is on it, and it
 * comes after the desktop it came from. Whatever got it wrong (a window the window manager sent
 * there, a number left over from a renumbering) is put right here and logged. */
static void check_invariants(void) {
    if (button_held() || sp_is_busy(dpy, root, A_BUSY)) { check_at = now_ms() + CHECK_DELAY_MS; return; }
    long n = get_card(root, A_NDESK, 1);
    for (int i = 0; i < ncl; i++) {
        struct client *c = &cl[i];
        if (c->origin < 0 || !c->full) continue;
        long s = desk_of(c->w);
        if (sp_sticky(s)) continue;
        c->space = (int)s;
        long o = sane_origin(c);
        if (o != c->origin) { LOG("repair: 0x%lx origin %d -> %ld (Space %ld)", c->w, c->origin, o, s); set_origin(c, o); }
        if (s >= n) LOG("repair: Space %ld is past the last desktop (%ld)", s, n);
    }
    for (int i = 0; i < ncl; i++) {
        Window w = cl[i].w;
        long d = desk_of(w);
        if (w == bar || sp_sticky(d) || cl[i].origin >= 0) continue;
        struct client *owner = space_owner(w, d);
        if (!owner || is_dialog(w)) continue;
        LOG("repair: 0x%lx is on 0x%lx's Space %ld", w, owner->w, d);
        if (get_card(root, A_CURDESK, 0) == d) keep_space_to_its_app(w);   /* you are looking at it: slide away */
        else move_wait(w, sane_origin(owner));
    }
    /* The ordinary-desktop count must add up: desktops = ordinary + Spaces in use + Spaces waiting to go.
     * If it does not, somebody else changed the count (Xfce's Workspace settings): the ordinary
     * desktops are what is left, so a later trim never removes one of them. */
    long base = read_base();
    if (base >= 0) {
        pend_load();
        int live = 0;
        for (int i = 0; i < ncl; i++) if (cl[i].origin >= 0) live++;
        long want = n - live - npending;
        if (want < 1) want = 1;
        if (want != base) { LOG("repair: ordinary desktops %ld -> %ld", base, want); write_base(want); }
    }
}

static void refresh_clients(void) {
    unsigned long n; Window *list = client_list(&n);
    static struct client keep[MAX_CLIENTS];
    Window fresh[MAX_CLIENTS], adopt[MAX_CLIENTS];
    int k = 0, left = 0, nfresh = 0, nadopt = 0, startup = ncl == 0;
    for (unsigned long i = 0; list && i < n && k < MAX_CLIENTS; i++) {
        if (list[i] == bar || list[i] == dock_helper) continue;
        struct client *old = find(list[i]);
        if (old) keep[k] = *old;
        else {                                                   /* new window: watch it */
            XSelectInput(dpy, list[i], PropertyChangeMask | StructureNotifyMask);
            if (ncl) fresh[nfresh++] = list[i];                 /* (not the ones there at startup) */
            keep[k].w = list[i];
            keep[k].maxed = is_maxed(list[i]);
            keep[k].full = has_state(list[i], A_FULL);
            keep[k].origin = (int)get_card(list[i], A_ORIGIN, -1);   /* kept on the window across restarts */
            keep[k].space = keep[k].origin >= 0 ? (int)desk_of(list[i]) : -1;
            if (keep[k].origin >= 0 && !keep[k].full) {          /* left full screen while we were away */
                pend_add(keep[k].space);
                move_wait(list[i], keep[k].origin);
                XDeleteProperty(dpy, list[i], A_ORIGIN);
                keep[k].origin = keep[k].space = -1;
            }
            if (keep[k].full && keep[k].origin < 0 && spaces) adopt[nadopt++] = list[i];   /* see below */
        }
        update_geo(&keep[k]);
        k++;
    }
    if (list) XFree(list);
    for (int i = 0; i < ncl; i++) {                              /* closed while full screen */
        int still = 0;
        for (int j = 0; j < k; j++) if (keep[j].w == cl[i].w) still = 1;
        if (!still && cl[i].origin >= 0) { leave_space(&cl[i], 1); left = 1; }   /* closed while full screen */
        if (!still && cl[i].w == bar_for) bar_for = None;
    }
    memcpy(cl, keep, sizeof(struct client) * k);
    ncl = k;
    for (int i = 0; i < nadopt; i++) {         /* full screen from the start (a restored browser, a
                                                  video player): give it its own Space too */
        struct client *c = find(adopt[i]);
        if (c && c->full && c->origin < 0) enter_space(c, startup);
    }
    for (int i = 0; i < nfresh; i++) keep_space_to_its_app(fresh[i]);
    if (nfresh || left) check_at = now_ms() + CHECK_DELAY_MS;
    (void)left;
}

/* a left-button press: remember the window if it landed in its button area */
static void on_press(void) {
    Window r, c; int px, py, wx, wy; unsigned int mask;
    if (!XQueryPointer(dpy, root, &r, &c, &px, &py, &wx, &wy, &mask)) return;
    Window hit = None;
    long here = get_card(root, A_CURDESK, 0);
    for (int i = ncl - 1; i >= 0; i--) {                         /* stacking order: top-most last */
        long d = desk_of(cl[i].w);                               /* only what is on this desktop can be clicked: */
        if (d >= 0 && d != here) continue;                       /* a full-screen app on another one must not take the click */
        if (has_state(cl[i].w, A_HIDDEN)) continue;
        int x = cl[i].geo[0], y = cl[i].geo[1], w = cl[i].geo[2], h = cl[i].geo[3], top = cl[i].geo[4];
        if (px < x || px >= x + w || py < y || py >= y + h) continue;
        int zone_h = top > 0 ? top : CSD_TITLE_H;
        if (px - x < BUTTON_ZONE_W && py - y < zone_h) hit = cl[i].w;
        break;                                                   /* the top-most window under the pointer */
    }
    clicked = hit;
    clicked_at = now_ms();
    LOG("press %d,%d hit 0x%lx", px, py, hit);
}

/* a window's state changed */
static void on_state(Window w) {
    struct client *c = find(w);
    if (!c) return;
    int m = is_maxed(w), f = has_state(w, A_FULL);
    LOG("state 0x%lx maxed %d->%d full %d->%d clicked 0x%lx %ldms ago", w, c->maxed, m, c->full, f, clicked, now_ms() - clicked_at);
    if (green && m != c->maxed && !f && w == clicked && now_ms() - clicked_at < CLICK_WINDOW_MS) {
        clicked = None;                                          /* the green button: full screen */
        if (m) send_state(w, 0, A_MAXV, A_MAXH);
        send_state(w, 1, A_FULL, None);
        m = 0;
    }
    c->maxed = m;
    if (f != c->full) {
        c->full = f;
        if (spaces && f && c->origin < 0) enter_space(c, 0);
        else if (!f && c->origin >= 0) leave_space(c, 0);
    }
}

/* ---- the menu bar and title bar at the top edge ------------------------------------------ */

static int panel_height(void) {   /* the top panel (menu bar), if there is one */
    for (int i = 0; i < ncl; i++) {
        unsigned long n; Atom *t = (Atom *)get_prop(cl[i].w, A_TYPE, XA_ATOM, &n);
        int dock = t && n && t[0] == A_TYPE_DOCK;
        if (t) XFree(t);
        if (dock && cl[i].geo[1] == 0 && cl[i].geo[3] < 80) return cl[i].geo[3];
    }
    return 0;
}

static void draw_bar(void) {
    XWindowAttributes a;
    if (bar_for == None || !XGetWindowAttributes(dpy, bar, &a)) return;
    cairo_surface_t *s = cairo_xlib_surface_create(dpy, bar, a.visual, bar_w, BAR_H);
    cairo_t *cr = cairo_create(s);
    cairo_set_source_rgb(cr, 0.17, 0.17, 0.18);
    cairo_paint(cr);
    cairo_set_source_rgba(cr, 1, 1, 1, 0.08);                    /* hairline at the bottom */
    cairo_rectangle(cr, 0, BAR_H - 1, bar_w, 1);
    cairo_fill(cr);
    const double col[3][3] = {{1.0, 0.37, 0.34}, {0.42, 0.42, 0.44}, {0.16, 0.78, 0.25}};
    for (int i = 0; i < 3; i++) {                                /* red, greyed yellow, green */
        cairo_arc(cr, 20 + i * 20, BAR_H / 2.0, 6, 0, 2 * M_PI);
        cairo_set_source_rgb(cr, col[i][0], col[i][1], col[i][2]);
        cairo_fill(cr);
    }
    unsigned long n; char *title = (char *)get_prop(bar_for, A_NAME, A_UTF8, &n);
    if (!title) {
        XTextProperty tp;
        if (XGetWMName(dpy, bar_for, &tp) && tp.value) title = (char *)tp.value;
    }
    if (title) {
        cairo_select_font_face(cr, "Inter", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
        cairo_set_font_size(cr, 13);
        cairo_text_extents_t ext;
        cairo_text_extents(cr, title, &ext);
        cairo_set_source_rgb(cr, 0.9, 0.9, 0.9);
        cairo_move_to(cr, (bar_w - ext.width) / 2 - ext.x_bearing, BAR_H / 2.0 - ext.height / 2 - ext.y_bearing);
        cairo_show_text(cr, title);
        XFree(title);
    }
    cairo_destroy(cr);
    cairo_surface_destroy(s);
}

static void copy_prop(Window from, Window to, Atom p) {
    Atom type; int fmt; unsigned long n, after; unsigned char *data = NULL;
    if (XGetWindowProperty(dpy, from, p, 0, 4096, False, AnyPropertyType, &type, &fmt, &n, &after, &data) == Success
        && data && type != None) {
        XChangeProperty(dpy, to, p, type, fmt, PropModeReplace, data, (int)n);
    } else {
        XDeleteProperty(dpy, to, p);
    }
    if (data) XFree(data);
}

static void create_bar(void) {
    XSetWindowAttributes at = {0};
    at.event_mask = ExposureMask | ButtonPressMask;
    bar = XCreateWindow(dpy, root, 0, 0, 100, BAR_H, 0, CopyFromParent, InputOutput,
                        CopyFromParent, CWEventMask, &at);
    XStoreName(dpy, bar, "fullscreen title bar");
    struct { unsigned long flags, functions, decorations; long input; unsigned long status; } motif = {2, 0, 0, 0, 0};
    XChangeProperty(dpy, bar, A_MOTIF, A_MOTIF, 32, PropModeReplace, (unsigned char *)&motif, 5);   /* no frame */
    Atom st[] = {A_ABOVE, A_SKIP_TB, A_SKIP_PG};
    XChangeProperty(dpy, bar, A_STATE, XA_ATOM, 32, PropModeReplace, (unsigned char *)st, 3);
    long sticky = 0xFFFFFFFF;
    XChangeProperty(dpy, bar, A_DESK, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&sticky, 1);
    XWMHints wmh = {.flags = InputHint, .input = True};          /* it takes the focus */
    XSetWMHints(dpy, bar, &wmh);
    XSizeHints *sh = XAllocSizeHints();                          /* exactly where we put it */
    sh->flags = PPosition | USPosition;
    XSetWMNormalHints(dpy, bar, sh);
    XFree(sh);
}

static void show_bar(Window w) {
    LOG("title bar over 0x%lx", w);
    int x, y, wd, ht, top;
    if (!frame_rect(w, &x, &y, &wd, &ht, &top)) return;
    if (bar == None) create_bar();
    bar_for = w; bar_x = x; bar_w = wd; bar_y = y + panel_height();
    for (int i = 0; MENU_PROPS[i]; i++) copy_prop(w, bar, XInternAtom(dpy, MENU_PROPS[i], False));
    copy_prop(w, bar, XA_WM_CLASS);                              /* the app's name in the menu bar */
    XMoveResizeWindow(dpy, bar, bar_x, bar_y, bar_w, BAR_H);
    long here = get_card(root, A_CURDESK, 0);        /* on the desktop it is shown on, whatever xfwm4 thinks */
    XChangeProperty(dpy, bar, A_DESK, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&here, 1);
    XMapRaised(dpy, bar);
    XSync(dpy, False);
    move_to_desktop(bar, here);
    XSync(dpy, False);
    shown_at = now_ms();
    activate(bar);              /* the app loses the focus, so the panel shows above it */
    draw_bar();
}

/* ---- the Dock at the bottom edge ---------------------------------------------------------- */

#define DOCK_ZONE 140       /* the dock (with its magnified icons) fits in this many pixels */

static void show_dock(Window w) {
    LOG("dock up over 0x%lx", w);
    if (dock_helper == None) {
        XSetWindowAttributes at = {0};
        dock_helper = XCreateWindow(dpy, root, 0, DisplayHeight(dpy, DefaultScreen(dpy)) - 1, 1, 1, 0,
                                    CopyFromParent, InputOutput, CopyFromParent, 0, &at);
        XStoreName(dpy, dock_helper, "fullscreen dock helper");
        struct { unsigned long flags, functions, decorations; long input; unsigned long status; } motif = {2, 0, 0, 0, 0};
        XChangeProperty(dpy, dock_helper, A_MOTIF, A_MOTIF, 32, PropModeReplace, (unsigned char *)&motif, 5);
        Atom st[] = {A_SKIP_TB, A_SKIP_PG};
        XChangeProperty(dpy, dock_helper, A_STATE, XA_ATOM, 32, PropModeReplace, (unsigned char *)st, 2);
        long sticky = 0xFFFFFFFF;
        XChangeProperty(dpy, dock_helper, A_DESK, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&sticky, 1);
        XWMHints wmh = {.flags = InputHint, .input = True};
        XSetWMHints(dpy, dock_helper, &wmh);
        XSizeHints *sh = XAllocSizeHints();
        sh->flags = PPosition | USPosition;
        XSetWMNormalHints(dpy, dock_helper, sh);
        XFree(sh);
    }
    for (int i = 0; MENU_PROPS[i]; i++) copy_prop(w, dock_helper, XInternAtom(dpy, MENU_PROPS[i], False));
    copy_prop(w, dock_helper, XA_WM_CLASS);                     /* the menu bar stays the app's */
    dock_for = w;
    long here = get_card(root, A_CURDESK, 0);
    XChangeProperty(dpy, dock_helper, A_DESK, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&here, 1);
    XMapRaised(dpy, dock_helper);
    XSync(dpy, False);
    move_to_desktop(dock_helper, here);
    XSync(dpy, False);
    shown_at = now_ms();
    activate(dock_helper);      /* the app loses the focus, so the dock shows above it */
}

static void hide_dock(int refocus) {
    Window w = dock_for;
    if (w == None) return;
    LOG("dock down (refocus %d)", refocus);
    dock_for = None;
    XUnmapWindow(dpy, dock_helper);
    if (refocus) activate(w);
}

static void hide_bar(int refocus) {
    Window w = bar_for;
    if (bar == None || w == None) return;
    LOG("title bar hidden (refocus %d)", refocus);
    bar_for = None;
    XUnmapWindow(dpy, bar);
    if (refocus) activate(w);   /* back on top of the panel */
}

static int menu_open(void) {    /* an open menu holds a pointer grab */
    if (XGrabPointer(dpy, root, False, 0, GrabModeAsync, GrabModeAsync, None, None, CurrentTime) == AlreadyGrabbed)
        return 1;
    XUngrabPointer(dpy, CurrentTime);
    return 0;
}

static void on_bar_click(int x) {
    Window w = bar_for;
    int i = (x - 10) / 20;                                       /* which circle, if any */
    if (x < 10 || i > 2 || i == 1) return;
    hide_bar(0);
    if (i == 0) close_window(w);
    else send_state(w, 0, A_FULL, None);
}

/* `fullscreen --dump`: what the desktops and Spaces look like right now (when something goes wrong) */
static void dump_state(void) {
    long n = get_card(root, A_NDESK, 0), cur = get_card(root, A_CURDESK, 0), base = read_base();
    long p[SP_MAX]; int np = sp_pending_read(dpy, root, A_PENDING, p, SP_MAX);
    printf("desktops %ld, current %ld, ordinary desktops in the state file %ld\n", n, cur, base);
    printf("empty Spaces waiting to be removed:");
    for (int i = 0; i < np; i++) printf(" %ld", p[i]);
    printf("%s\nlayout busy: %s\n", np ? "" : " none", sp_is_busy(dpy, root, A_BUSY) ? "yes" : "no");
    unsigned long cnt; Window *l = client_list(&cnt);
    for (unsigned long i = 0; l && i < cnt; i++) {
        long d = desk_of(l[i]), o = get_card(l[i], A_ORIGIN, -1);
        unsigned long len; char *title = (char *)get_prop(l[i], A_NAME, A_UTF8, &len);
        char desk[24]; if (sp_sticky(d)) snprintf(desk, sizeof desk, "all"); else snprintf(desk, sizeof desk, "%ld", d);
        printf("0x%08lx desktop %-3s %s%s", l[i], desk, has_state(l[i], A_FULL) ? "full-screen " : "", "");
        if (o >= 0) printf("(Space of desktop %ld) ", o);
        printf("%s\n", title ? title : "");
        if (title) XFree(title);
    }
    if (l) XFree(l);
}

int main(int argc, char **argv) {
    int dump = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dump")) dump = 1;
        else if (!strcmp(argv[i], "-G")) green = 0;
        else if (!strcmp(argv[i], "-P")) peek = 0;
        else if (!strcmp(argv[i], "-S")) spaces = 0;
        else { fprintf(stderr, "usage: %s [-G] [-P] [-S] [--dump]\n", argv[0]); return 1; }
    }
    if (getenv("FULLSCREEN_LOG")) test_log = fopen(getenv("FULLSCREEN_LOG"), "a");
    LOG("start, pid %d", (int)getpid());
    dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "fullscreen: cannot open display\n"); return 1; }
    XSetErrorHandler(ignore_errors);                             /* windows vanish all the time */
    root = DefaultRootWindow(dpy);
    const char *st = getenv("XDG_STATE_HOME"), *home = getenv("HOME");
    if (st && *st) snprintf(base_file, sizeof base_file, "%s/fullscreen-spaces", st);
    else snprintf(base_file, sizeof base_file, "%s/.local/state/fullscreen-spaces", home ? home : ".");
    A_CLIENTS = XInternAtom(dpy, "_NET_CLIENT_LIST_STACKING", False);
    A_CLIENTS_PLAIN = XInternAtom(dpy, "_NET_CLIENT_LIST", False);
    A_ACTIVE = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
    A_STATE = XInternAtom(dpy, "_NET_WM_STATE", False);
    A_FULL = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
    A_HIDDEN = XInternAtom(dpy, "_NET_WM_STATE_HIDDEN", False);
    A_MAXV = XInternAtom(dpy, "_NET_WM_STATE_MAXIMIZED_VERT", False);
    A_MAXH = XInternAtom(dpy, "_NET_WM_STATE_MAXIMIZED_HORZ", False);
    A_ABOVE = XInternAtom(dpy, "_NET_WM_STATE_ABOVE", False);
    A_SKIP_TB = XInternAtom(dpy, "_NET_WM_STATE_SKIP_TASKBAR", False);
    A_SKIP_PG = XInternAtom(dpy, "_NET_WM_STATE_SKIP_PAGER", False);
    A_EXTENTS = XInternAtom(dpy, "_NET_FRAME_EXTENTS", False);
    A_CLOSE = XInternAtom(dpy, "_NET_CLOSE_WINDOW", False);
    A_NAME = XInternAtom(dpy, "_NET_WM_NAME", False);
    A_UTF8 = XInternAtom(dpy, "UTF8_STRING", False);
    A_DESK = XInternAtom(dpy, "_NET_WM_DESKTOP", False);
    A_NDESK = XInternAtom(dpy, "_NET_NUMBER_OF_DESKTOPS", False);
    A_CURDESK = XInternAtom(dpy, "_NET_CURRENT_DESKTOP", False);
    A_TYPE = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
    A_TYPE_NORMAL = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_NORMAL", False);
    A_TYPE_DOCK = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DOCK", False);
    A_SLIDE = XInternAtom(dpy, "_MAC_SLIDE", False);
    A_MOTIF = XInternAtom(dpy, "_MOTIF_WM_HINTS", False);
    A_ORIGIN = XInternAtom(dpy, "_MACOS_FULLSCREEN_ORIGIN", False);
    A_PENDING = XInternAtom(dpy, "_MACOS_PENDING_SPACES", False);
    A_BUSY = XInternAtom(dpy, "_MACOS_LAYOUT_BUSY", False);

    if (dump) { dump_state(); return 0; }

    int xi_opcode = -1, ev, er, major = 2, minor = 2;   /* 2.1+: raw events even during grabs (title bar clicks) */
    if (green && XQueryExtension(dpy, "XInputExtension", &xi_opcode, &ev, &er)
        && XIQueryVersion(dpy, &major, &minor) == Success) {
        unsigned char m[XIMaskLen(XI_LASTEVENT)] = {0};
        XISetMask(m, XI_RawButtonPress);
        XIEventMask em = {XIAllMasterDevices, sizeof m, m};
        XISelectEvents(dpy, root, &em, 1);
    } else {
        green = 0;
    }
    XSelectInput(dpy, root, PropertyChangeMask);
    pend_load();
    refresh_clients();
    {   /* Spaces left over from a previous session: there are more desktops than the ordinary
         * ones plus the Spaces of windows still full screen. Only empty desktops at the end are
         * taken for leftovers: an empty ordinary desktop in between must stay. */
        long base = read_base(), n = get_card(root, A_NDESK, 0), live = 0;
        for (int i = 0; i < ncl; i++) if (cl[i].origin >= 0) live++;
        long extra = base >= 0 ? n - base - live : 0;
        for (long d = n - 1; extra > 0 && d >= 0 && desktop_empty(d); d--, extra--)
            pend_add(d);
        if (base >= 0 && n - live <= base && !live) write_base(-1);
        trim_spaces();
    }

    long at_top_since = -1, at_bottom_since = -1, away_since = -1;
    int SH = DisplayHeight(dpy, DefaultScreen(dpy));
    for (;;) {
        /* poll the pointer only while the active window is full screen (or a bar or the dock is up) */
        Window act = peek ? active_window() : None;
        int full = act != None && act != bar && act != dock_helper && has_state(act, A_FULL);
        int timeout = -1;
        if (full || bar_for != None || dock_for != None) {
            Window r, c; int px, py, wx, wy; unsigned int mask;
            if (XQueryPointer(dpy, root, &r, &c, &px, &py, &wx, &wy, &mask)) {
                long t = now_ms();
                int held = (mask & (Button1Mask | Button2Mask | Button3Mask)) != 0;
                if (dock_for != None) {                          /* the dock is up */
                    if (act != dock_helper && t - shown_at > FOCUS_GRACE_MS) { hide_dock(0); away_since = -1; }   /* something took over */
                    else if (!has_state(dock_for, A_FULL)) { hide_dock(0); away_since = -1; }
                    else if (py < SH - DOCK_ZONE && !held) {
                        if (away_since < 0) away_since = t;
                        if (t - away_since >= PEEK_DELAY_MS) { hide_dock(1); away_since = -1; }
                    } else away_since = -1;
                } else if (full && py >= SH - 1 && !held) {      /* the bottom edge: the dock */
                    if (at_bottom_since < 0) at_bottom_since = t;
                    if (t - at_bottom_since >= 100) { show_dock(act); at_bottom_since = -1; }
                } else {
                    at_bottom_since = -1;
                }
                if (dock_for != None) {
                    timeout = POLL_NEAR_MS;
                } else if (bar_for != None) {
                    int away = py > bar_y + BAR_H + 8 || px < bar_x || px >= bar_x + bar_w;
                    if (!has_state(bar_for, A_FULL)) hide_bar(0);
                    else if (act != bar && act != bar_for && t - shown_at > FOCUS_GRACE_MS) hide_bar(0);   /* something else took over */
                    else if (away && !menu_open()) hide_bar(1);
                } else if (py <= 0 && !(mask & (Button1Mask | Button2Mask | Button3Mask))) {
                    if (at_top_since < 0) at_top_since = t;
                    if (t - at_top_since >= PEEK_DELAY_MS) { show_bar(act); at_top_since = -1; }
                } else {
                    at_top_since = -1;
                }
                if (dock_for == None)
                    timeout = (py < bar_y + BAR_H + 10 || py > SH - 10) ? POLL_NEAR_MS : POLL_FULL_MS;
            }
        } else {
            at_top_since = -1;
        }
        if (nmarked) {                                           /* slide marks to clear */
            long left = SLIDE_CLEAR_MS - (now_ms() - marked_at);
            if (left <= 0) clear_marks();
            else if (timeout < 0 || timeout > left) timeout = (int)left;
        }
        if (check_at >= 0) {                                     /* Spaces to check */
            long left = check_at - now_ms();
            if (left <= 0) { check_at = -1; check_invariants(); }
            else if (timeout < 0 || timeout > left) timeout = (int)left;
        }
        if (trim_at >= 0) {                                      /* empty Spaces to remove */
            long left = trim_at - now_ms();
            if (left <= 0) { trim_at = -1; trim_spaces(); }
            else if (timeout < 0 || timeout > left) timeout = (int)left;
        }
        XFlush(dpy);
        if (!XPending(dpy)) {
            struct pollfd pfd = {ConnectionNumber(dpy), POLLIN, 0};
            poll(&pfd, 1, timeout);
        }
        while (XPending(dpy)) {
            XEvent e;
            XNextEvent(dpy, &e);
            if (e.type == GenericEvent && e.xcookie.extension == xi_opcode && XGetEventData(dpy, &e.xcookie)) {
                if (e.xcookie.evtype == XI_RawButtonPress && ((XIRawEvent *)e.xcookie.data)->detail == 1)
                    on_press();
                XFreeEventData(dpy, &e.xcookie);
            } else if (e.type == ConfigureNotify) {
                struct client *c = find(e.xconfigure.window);
                if (c) update_geo(c);
            } else if (e.type == PropertyNotify) {
                if (e.xproperty.window == root && e.xproperty.atom == A_PENDING) pend_load();   /* Mission Control renumbered */
                if (spaces && ((e.xproperty.window == root && e.xproperty.atom == A_NDESK) || e.xproperty.atom == A_DESK))
                    check_at = now_ms() + CHECK_DELAY_MS;                /* the layout changed: check once it settles */
                if (npending && ((e.xproperty.window == root && e.xproperty.atom == A_CURDESK) || e.xproperty.atom == A_DESK))
                    trim_at = now_ms() + SLIDE_CLEAR_MS;                 /* a Space may have emptied */
                if (e.xproperty.window == root && (e.xproperty.atom == A_CLIENTS || e.xproperty.atom == A_CLIENTS_PLAIN)) refresh_clients();
                else if (e.xproperty.atom == A_STATE) on_state(e.xproperty.window);
                else if (e.xproperty.atom == A_ORIGIN || e.xproperty.atom == A_DESK) {
                    /* Mission Control may reorder or remove desktops: follow it */
                    struct client *c = find(e.xproperty.window);
                    if (c && c->origin >= 0) {
                        long o = get_card(c->w, A_ORIGIN, -1);
                        if (o >= 0) { c->origin = (int)o; c->space = (int)desk_of(c->w); }
                    }
                }
                else if (e.xproperty.atom == A_EXTENTS) { struct client *c = find(e.xproperty.window); if (c) update_geo(c); }
            } else if (e.type == Expose && e.xexpose.window == bar && e.xexpose.count == 0) {
                draw_bar();
            } else if (e.type == ButtonPress && e.xbutton.window == bar && e.xbutton.button == 1) {
                on_bar_click(e.xbutton.x);
            }
        }
    }
}
