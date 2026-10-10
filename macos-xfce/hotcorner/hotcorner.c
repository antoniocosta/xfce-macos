/* hotcorner: tiny macOS-style hot corners for X11, plus dragging windows across desktops.
 * Usage: hotcorner [-d delay_ms] [-e EDGE_CMD] CORNER CMD [CORNER CMD ...]
 *   CORNER is one of: tl tr bl br. CMD runs via /bin/sh once the pointer has rested in
 *   the corner for delay_ms; it re-arms as soon as the pointer leaves the corner.
 *   -e EDGE_CMD: when a window is dragged against the left/right screen edge for 300 ms,
 *   run EDGE_CMD with "left" or "right" and the window id appended.
 * One pointer poll serves both, and it adapts: 5x/second while the pointer is away from
 * the corners with no button held, 50x/second near a corner, 33x/second while dragging.
 * Polling works even when a dock or window covers the corner.
 */
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAX_CORNERS 4
#define POLL_IDLE_MS 200
#define POLL_NEAR_MS 20
#define POLL_DRAG_MS 30
#define NEAR 150      /* fast polling within this many pixels of a corner */
#define SIZE 2        /* corner hit area in pixels */
#define EDGE_DELAY 300
#define MOVED_PX 20   /* the active window must have moved this far to count as a drag */

struct corner { char pos[3]; const char *cmd; long entered; int fired; };

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

static int in_corner(const char *pos, int x, int y, int w, int h, int size) {
    int left = x < size, right = x >= w - size, top = y < size, bottom = y >= h - size;
    if (!strcmp(pos, "tl")) return top && left;
    if (!strcmp(pos, "tr")) return top && right;
    if (!strcmp(pos, "bl")) return bottom && left;
    if (!strcmp(pos, "br")) return bottom && right;
    return 0;
}

static void run(const char *cmd) {
    if (fork() == 0) {
        setsid();
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
}

static Window active_window(Display *dpy, Window root, Atom net_active) {
    Atom type;
    int format;
    unsigned long n, after;
    unsigned char *data = NULL;
    Window w = None;
    if (XGetWindowProperty(dpy, root, net_active, 0, 1, False, XA_WINDOW, &type, &format,
                           &n, &after, &data) == Success && data) {
        if (n == 1) w = *(Window *)data;
        XFree(data);
    }
    return w;
}

static int window_pos(Display *dpy, Window root, Window w, int *x, int *y) {
    Window child;
    return w != None && XTranslateCoordinates(dpy, w, root, 0, 0, x, y, &child);
}

static int ignore_errors(Display *d, XErrorEvent *e) { (void)d; (void)e; return 0; }

int main(int argc, char **argv) {
    struct corner c[MAX_CORNERS];
    int n = 0, i = 1;
    long delay = 250;
    const char *edge_cmd = NULL;

    for (;;) {
        if (i + 1 < argc && !strcmp(argv[i], "-d")) { delay = atol(argv[i + 1]); i += 2; }
        else if (i + 1 < argc && !strcmp(argv[i], "-e")) { edge_cmd = argv[i + 1]; i += 2; }
        else break;
    }
    for (; i + 1 < argc && n < MAX_CORNERS; i += 2, n++) {
        snprintf(c[n].pos, sizeof c[n].pos, "%s", argv[i]);
        c[n].cmd = argv[i + 1];
        c[n].entered = -1;
        c[n].fired = 0;
    }
    if (n == 0 && !edge_cmd) {
        fprintf(stderr, "usage: %s [-d delay_ms] [-e EDGE_CMD] CORNER CMD [CORNER CMD ...]\n", argv[0]);
        return 1;
    }

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "hotcorner: cannot open display\n"); return 1; }
    XSetErrorHandler(ignore_errors); /* windows can vanish mid-drag */
    signal(SIGCHLD, SIG_IGN);        /* don't leave zombie children */
    Window root = DefaultRootWindow(dpy);
    Screen *scr = DefaultScreenOfDisplay(dpy);
    Atom net_active = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);

    /* edge-drag state */
    int down = 0, start_x = 0, start_y = 0, edge_fired = 0;
    long at_edge_since = -1;
    Window start_win = None;

    for (;;) {
        int near = 0;
        Window r, child;
        int x, y, wx, wy;
        unsigned int mask = 0;
        if (XQueryPointer(dpy, root, &r, &child, &x, &y, &wx, &wy, &mask)) {
            long t = now_ms();
            int w = WidthOfScreen(scr), h = HeightOfScreen(scr);
            int held = (mask & (Button1Mask | Button2Mask | Button3Mask)) != 0;

            for (int k = 0; k < n; k++) {
                if (in_corner(c[k].pos, x, y, w, h, NEAR)) near = 1;
                if (!in_corner(c[k].pos, x, y, w, h, SIZE)) {
                    c[k].entered = -1;
                    c[k].fired = 0;
                    continue;
                }
                if (c[k].entered < 0) c[k].entered = t;
                /* don't fire while a mouse button is held (e.g. dragging a window) */
                if (!c[k].fired && !held && t - c[k].entered >= delay) {
                    c[k].fired = 1;
                    run(c[k].cmd);
                }
            }

            if (edge_cmd) {
                int b1 = (mask & Button1Mask) != 0;
                if (b1 && !down) {          /* button just went down: remember the window */
                    start_win = active_window(dpy, root, net_active);
                    if (!window_pos(dpy, root, start_win, &start_x, &start_y)) start_win = None;
                    at_edge_since = -1;
                    edge_fired = 0;
                }
                down = b1;
                const char *side = x <= 0 ? "left" : (x >= w - 1 ? "right" : NULL);
                if (!down || !side) {
                    at_edge_since = -1;
                    edge_fired = 0;
                } else if (!edge_fired && start_win != None) {
                    Window aw = active_window(dpy, root, net_active);
                    int nx, ny;
                    if (aw == start_win && window_pos(dpy, root, aw, &nx, &ny)
                        && abs(nx - start_x) + abs(ny - start_y) >= MOVED_PX) {
                        if (at_edge_since < 0) at_edge_since = t;
                        if (t - at_edge_since >= EDGE_DELAY) {
                            char full[512];
                            snprintf(full, sizeof full, "%s %s 0x%lx", edge_cmd, side, (unsigned long)aw);
                            edge_fired = 1;
                            run(full);
                        }
                    }
                }
            }
            usleep((near ? POLL_NEAR_MS : ((mask & Button1Mask) ? POLL_DRAG_MS : POLL_IDLE_MS)) * 1000);
        } else {
            usleep(POLL_IDLE_MS * 1000);
        }
    }
}
