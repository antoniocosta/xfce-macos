/* hotcorner: tiny macOS-style hot corners for X11.
 * Usage: hotcorner [-d delay_ms] CORNER CMD [CORNER CMD ...]
 *   CORNER is one of: tl tr bl br. CMD runs via /bin/sh once the pointer has rested in the
 *   corner for delay_ms. It fires once: the corner is armed again only after the pointer has gone
 *   well away from it (a trackpad finger resting there jitters a pixel or two, and that must not
 *   fire it again and undo what it just did).
 *   A held mouse button never counts: dragging a window or a file into a corner does nothing, and
 *   the resting time starts again when the button goes up.
 * One pointer poll serves all corners, and it adapts: 5x/second while the pointer is away from the
 * corners, 50x/second near one. Polling works even when a dock or window covers the corner.
 * The screen's size is read at every poll, so a changed resolution moves the corners with it.
 */
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
#define NEAR 150      /* fast polling within this many pixels of a corner */
#define SIZE 2        /* corner hit area in pixels */
#define REARM 30      /* a fired corner is armed again beyond this many pixels */

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

static int ignore_errors(Display *d, XErrorEvent *e) { (void)d; (void)e; return 0; }

int main(int argc, char **argv) {
    struct corner c[MAX_CORNERS];
    int n = 0, i = 1;
    long delay = 250;

    if (i + 1 < argc && !strcmp(argv[i], "-d")) { delay = atol(argv[i + 1]); i += 2; }
    for (; i + 1 < argc && n < MAX_CORNERS; i += 2, n++) {
        snprintf(c[n].pos, sizeof c[n].pos, "%s", argv[i]);
        c[n].cmd = argv[i + 1];
        c[n].entered = -1;
        c[n].fired = 0;
    }
    if (n == 0) {
        fprintf(stderr, "usage: %s [-d delay_ms] CORNER CMD [CORNER CMD ...]\n", argv[0]);
        return 1;
    }

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "hotcorner: cannot open display\n"); return 1; }
    XSetErrorHandler(ignore_errors);
    signal(SIGCHLD, SIG_IGN);        /* don't leave zombie children */
    Window root = DefaultRootWindow(dpy);

    for (;;) {
        int near = 0;
        Window r, child;
        int x, y, wx, wy;
        unsigned int mask = 0;
        if (XQueryPointer(dpy, root, &r, &child, &x, &y, &wx, &wy, &mask)) {
            long t = now_ms();
            int rx, ry;
            unsigned int uw, uh, bw, depth;
            Window rr;
            if (!XGetGeometry(dpy, root, &rr, &rx, &ry, &uw, &uh, &bw, &depth)) { usleep(POLL_IDLE_MS * 1000); continue; }
            int w = (int)uw, h = (int)uh;
            int held = (mask & (Button1Mask | Button2Mask | Button3Mask)) != 0;

            for (int k = 0; k < n; k++) {
                if (in_corner(c[k].pos, x, y, w, h, NEAR)) near = 1;
                if (!in_corner(c[k].pos, x, y, w, h, REARM)) c[k].fired = 0;      /* far enough away: armed again */
                if (held || !in_corner(c[k].pos, x, y, w, h, SIZE)) {
                    c[k].entered = -1;                                            /* (a held button restarts the wait) */
                    continue;
                }
                if (c[k].entered < 0) c[k].entered = t;
                if (!c[k].fired && t - c[k].entered >= delay) {
                    c[k].fired = 1;
                    run(c[k].cmd);
                }
            }
            usleep((near ? POLL_NEAR_MS : POLL_IDLE_MS) * 1000);
        } else {
            usleep(POLL_IDLE_MS * 1000);
        }
    }
}
