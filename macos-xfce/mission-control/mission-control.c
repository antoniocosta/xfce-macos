/* mission-control: macOS Mission Control for X11 (Xfce).
 *
 * The Spaces bar across the top shows every desktop (a full-screen app's Space is named after the
 * app); below it, the windows of the current desktop, side by side. Full-screen windows are only
 * in the bar, as on macOS; opened from a full-screen app, it shows the desktop the app came from. Click a window to go to it,
 * click a desktop to switch to it, drag a window onto a desktop to move it there (or onto + to give
 * it a new desktop), + adds a desktop, the x on a hovered desktop removes it (its windows go to the
 * neighbouring desktop), and dragging a desktop along the bar reorders the desktops (their windows
 * go with them). Esc, F3, Ctrl+Up or a click on empty space closes it.
 *
 * For tests: with MISSION_CONTROL_LAYOUT=<file> set, every redraw writes where the desktops, the +
 * and the windows are drawn to that file (one per line: "desk N x y w h picture name",
 * "plus x y w h", "item 0xWINDOW x y w h [min [img]]", "view N", "cur N").
 *
 * Usage: mission-control            toggle (asks the running copy; opens once if none runs)
 *        mission-control --open     open (3-finger swipe up); --close: close (swipe down)
 *        mission-control --daemon   run in the background (started at login)
 *
 * Light by design: in the background it sleeps until the window manager reports something: a
 * desktop switch, or a window opened, closed, moved or resized on the current desktop. A second
 * after things settle it takes one small snapshot of the current desktop, because X keeps no image
 * of hidden desktops; that's the desktop's picture in the Spaces bar. A picture belongs to the set
 * of windows it shows, not to a desktop number, so it survives desktops being added, removed or
 * reordered. No periodic timers, no polling. While open it shows the windows' own composited images (XComposite).
 */
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/XF86keysym.h>
#include <X11/keysym.h>
#include <X11/extensions/Xcomposite.h>
#include <cairo/cairo-xlib.h>
#include <malloc.h>
#include <math.h>
#include <stdint.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <strings.h>
#include <jpeglib.h>   /* after stdio.h */
#include <setjmp.h>

#include "../common/spaces.h"

#define MAX_WIN 256
#define MAX_DESK 32
#define MAX_SPACES 16       /* macOS allows 16 Spaces per display */
#define THUMB_H 84          /* desktop thumbnails in the Spaces bar */
#define BAR_TOP 22
#define LABEL_H 28
#define GAP 24
#define SNAP_DELAY_MS 1000  /* after a switch or a window change: let things settle, then snapshot */
#define MAX_SNAP 48
#define SNAP_WINS 64
#define DRAG_PX 6

struct win {                /* a window on any desktop (for the bar) */
    Window w, frame;
    long desk;
    int x, y, wd, ht;       /* frame geometry */
    int fullscreen_space;   /* it has a full-screen Space of its own */
    long origin;            /* ...and the desktop that Space came from; else -1 */
    int minimized;          /* minimized: drawn dimmed with a badge (a click brings it back) */
    char title[256], app[64];
    cairo_surface_t *icon;
    /* current desktop only, while open */
    int pm_cached;          /* pm belongs to wpix[] (a minimized window's last look): not ours to free */
    Pixmap pm;
    cairo_surface_t *surf;
    double tx, ty, tw, th;  /* where it is drawn */
};

struct desk { double x, y, w, h; };

static Display *dpy;
static Window root, ctl = None, ov = None;
static int SW, SH, TW;
static Atom A_CLIENTS, A_CLIENTS_PLAIN, A_ACTIVE, A_DESK, A_NDESK, A_CURDESK, A_TYPE, A_TYPE_NORMAL, A_TYPE_DIALOG,
    A_STATE, A_HIDDEN, A_SKIP_TB, A_FULL, A_NAME, A_UTF8, A_ICON, A_ORIGIN, A_SEL, A_MSG, A_PENDING, A_BUSY;

struct snap {                               /* a desktop's picture and the windows it shows */
    cairo_surface_t *img;                   /* TW x THUMB_H */
    Window set[SNAP_WINS];
    int n;
    long used;
};
static struct snap snaps[MAX_SNAP];
static long snap_due = -1;

/* The last look of windows. The compositor keeps every window's image; a name for it (a Composite
 * "window pixmap") stays valid after the window is minimized, with what it showed. So for each window
 * showing on the current desktop we keep a name, renewed whenever things settle, at no cost beyond a handle
 * on the X server. A minimized window is then drawn from it. (Needs a compositor: Xfce's or picom.) */
#define MAX_PIX 64
struct wpix { Window frame; Pixmap pm; Visual *vis; int wd, ht; };
static struct wpix wpix[MAX_PIX];
static int nwpix;

static int is_open;
static cairo_surface_t *bg;                 /* the desktop's wallpaper (server side), while open */
static Pixmap bg_pm = None;
static struct win wins[MAX_WIN];
static int nwins;
static int cur_items[MAX_WIN], nitems;      /* indexes into wins[] of the current desktop's windows */
static struct desk desks[MAX_DESK];
static int ndesk;
static long cur;                            /* the desktop (or Space) it was opened on */
static long view;                           /* the desktop whose windows are shown: cur, or the
                                               desktop a full-screen app came from */
static double plus_x, plus_y, plus_w, plus_h;
static int hover_item = -1, hover_desk = -1, hover_close = 0, hover_plus = 0;
static int press_item = -1, dragging = 0;
static int press_desk = -1, desk_dragging = 0;    /* reordering desktops in the bar */
static int press_close = -1;                      /* the desktop whose x was pressed */
static long refresh_due = -1;                     /* the layout changed while open: redraw at this time */
static int press_x, press_y, ptr_x, ptr_y;

static int is_normal_window(Window w);

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

static int ignore_errors(Display *d, XErrorEvent *e) { (void)d; (void)e; return 0; }

static unsigned char *get_prop(Window w, Atom prop, Atom type, unsigned long *n) {
    Atom real; int fmt; unsigned long after; unsigned char *data = NULL;
    *n = 0;
    if (XGetWindowProperty(dpy, w, prop, 0, 1 << 20, False, type, &real, &fmt, n, &after, &data) != Success)
        return NULL;
    if (!data || !*n) { if (data) XFree(data); *n = 0; return NULL; }
    return data;
}

/* the managed windows, bottom to top. Xfce drops the stacking-order list once every window has
 * closed and only brings it back on a restack, but always keeps the plain list: use that then */
static Window *client_list(unsigned long *n) {
    Window *l = (Window *)get_prop(root, A_CLIENTS, XA_WINDOW, n);
    return l ? l : (Window *)get_prop(root, A_CLIENTS_PLAIN, XA_WINDOW, n);
}

static long get_card(Window w, Atom prop, long dflt) {
    unsigned long n; long *v = (long *)get_prop(w, prop, XA_CARDINAL, &n);
    long r = (v && n) ? v[0] : dflt;
    if (v) XFree(v);
    return r;
}

static int has_atom(Window w, Atom prop, Atom a) {
    unsigned long n; Atom *s = (Atom *)get_prop(w, prop, XA_ATOM, &n);
    int found = 0;
    for (unsigned long i = 0; i < n; i++) if (s[i] == a) found = 1;
    if (s) XFree(s);
    return found;
}

static void client_msg(Window w, Atom type, long l0, long l1, long l2) {
    XEvent e = {0};
    e.xclient.type = ClientMessage;
    e.xclient.window = w;
    e.xclient.message_type = type;
    e.xclient.format = 32;
    e.xclient.data.l[0] = l0; e.xclient.data.l[1] = l1; e.xclient.data.l[2] = l2;
    XSendEvent(dpy, root, False, SubstructureRedirectMask | SubstructureNotifyMask, &e);
}

static void activate(Window w) { client_msg(w, A_ACTIVE, 2, CurrentTime, 0); }
static void move_to_desktop(Window w, long d) { client_msg(w, A_DESK, d, 2, 0); }
static void set_desktops(long n) { client_msg(root, A_NDESK, n, 0, 0); }
static void switch_desktop(long d) { client_msg(root, A_CURDESK, d, CurrentTime, 0); }
static void set_desktops_wait(long n) { set_desktops(n); sp_wait_card(dpy, root, A_NDESK, n, SP_WAIT_MS); }
static void switch_wait(long d) { switch_desktop(d); sp_wait_card(dpy, root, A_CURDESK, d, SP_WAIT_MS); }

static Window frame_of(Window w) {
    Window r, parent, *kids; unsigned int nk;
    for (;;) {
        if (!XQueryTree(dpy, w, &r, &parent, &kids, &nk)) return w;
        if (kids) XFree(kids);
        if (parent == root || parent == None) return w;
        w = parent;
    }
}

/* ---- the fullscreen utility's bookkeeping, kept in step when desktops are renumbered ---- */

static void base_file(char *buf, size_t n) {
    const char *st = getenv("XDG_STATE_HOME"), *home = getenv("HOME");
    if (st && *st) snprintf(buf, n, "%s/fullscreen-spaces", st);
    else snprintf(buf, n, "%s/.local/state/fullscreen-spaces", home ? home : ".");
}

static void adjust_base(int by) {       /* ordinary desktops added/removed while Spaces exist */
    char path[512]; long b;
    base_file(path, sizeof path);
    FILE *f = fopen(path, "r");
    if (!f) return;
    if (fscanf(f, "%ld", &b) != 1) { fclose(f); return; }
    fclose(f);
    if ((f = fopen(path, "w"))) { fprintf(f, "%ld\n", b + by); fclose(f); }
}

/* ---- window list ------------------------------------------------------------------------ */

static cairo_surface_t *load_icon(Window w) {
    unsigned long n; long *d = (long *)get_prop(w, A_ICON, XA_CARDINAL, &n);
    if (!d) return NULL;
    long best = -1, bw = 0;
    for (unsigned long i = 0; i + 2 < n;) {               /* width, height, pixels... */
        long iw = d[i], ih = d[i + 1];
        if (iw <= 0 || ih <= 0 || i + 2 + iw * ih > n) break;
        if (best < 0 || (bw < 48 && iw > bw) || (iw >= 48 && iw < bw)) { best = (long)i; bw = iw; }
        i += 2 + iw * ih;
    }
    cairo_surface_t *s = NULL;
    if (best >= 0) {
        long iw = d[best], ih = d[best + 1];
        if (iw > 4096 || ih > 4096) { XFree(d); return NULL; }
        s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)iw, (int)ih);
        if (cairo_surface_status(s) != CAIRO_STATUS_SUCCESS) { cairo_surface_destroy(s); XFree(d); return NULL; }
        unsigned char *px = cairo_image_surface_get_data(s);
        int stride = cairo_image_surface_get_stride(s);
        for (long y = 0; y < ih; y++)
            for (long x = 0; x < iw; x++) {
                unsigned long p = (unsigned long)d[best + 2 + y * iw + x];
                unsigned a = p >> 24 & 255, r = p >> 16 & 255, g = p >> 8 & 255, b = p & 255;
                uint32_t *o = (uint32_t *)(px + y * stride) + x;   /* cairo wants premultiplied */
                *o = a << 24 | (r * a / 255) << 16 | (g * a / 255) << 8 | (b * a / 255);
            }
        cairo_surface_mark_dirty(s);
    }
    XFree(d);
    return s;
}

static void read_title(Window w, char *out, size_t n) {
    unsigned long len; char *t = (char *)get_prop(w, A_NAME, A_UTF8, &len);
    if (t) { sp_copy_utf8(out, n, t); XFree(t); return; }
    XTextProperty tp;
    if (XGetWMName(dpy, w, &tp) && tp.value) { sp_copy_utf8(out, n, (char *)tp.value); XFree(tp.value); return; }
    out[0] = 0;
}

static void read_app(Window w, char *out, size_t n) {
    XClassHint ch = {0};
    out[0] = 0;
    if (XGetClassHint(dpy, w, &ch)) {
        const char *c = ch.res_class ? ch.res_class : ch.res_name;
        if (c) snprintf(out, n, "%s", c);
        if (c && out[0] >= 'a' && out[0] <= 'z') out[0] -= 32;
        if (ch.res_name) XFree(ch.res_name);
        if (ch.res_class) XFree(ch.res_class);
    }
}

static int is_app_window(Window w) {           /* a window of an app (minimized or not) */
    unsigned long n; Atom *t = (Atom *)get_prop(w, A_TYPE, XA_ATOM, &n);
    int ok = !t || t[0] == A_TYPE_NORMAL || t[0] == A_TYPE_DIALOG;
    if (t) XFree(t);
    return ok && !has_atom(w, A_STATE, A_SKIP_TB);
}

static int is_normal_window(Window w) {        /* ...and showing (the desktop pictures go by these) */
    return is_app_window(w) && !has_atom(w, A_STATE, A_HIDDEN);
}

static void free_wins(void) {
    for (int i = 0; i < nwins; i++) {
        if (wins[i].surf) cairo_surface_destroy(wins[i].surf);
        if (wins[i].pm && !wins[i].pm_cached) XFreePixmap(dpy, wins[i].pm);
        if (wins[i].icon) cairo_surface_destroy(wins[i].icon);
    }
    nwins = nitems = 0;
}

static void read_windows(void) {
    unsigned long n; Window *list = client_list(&n);
    free_wins();
    for (unsigned long i = 0; list && i < n && nwins < MAX_WIN; i++) {
        Window w = list[i];
        long d = get_card(w, A_DESK, -1);
        if (d < 0 || d == 0xFFFFFFFF || !is_app_window(w)) continue;
        struct win *v = &wins[nwins];
        memset(v, 0, sizeof *v);
        v->w = w; v->desk = d; v->frame = frame_of(w);
        v->minimized = has_atom(w, A_STATE, A_HIDDEN);
        XWindowAttributes a;
        if (!XGetWindowAttributes(dpy, v->frame, &a) || a.width < 2 || a.height < 2) continue;
        v->x = a.x; v->y = a.y; v->wd = a.width; v->ht = a.height;
        v->origin = get_card(w, A_ORIGIN, -1);
        v->fullscreen_space = v->origin >= 0 && has_atom(w, A_STATE, A_FULL);
        read_title(w, v->title, sizeof v->title);
        read_app(w, v->app, sizeof v->app);
        v->icon = load_icon(w);
        if (d == view && (a.map_state == IsViewable || v->minimized) && !v->fullscreen_space) {   /* a full-screen
                                                         app is its own Space: only in the bar */
            if (!v->minimized) {
                v->pm = XCompositeNameWindowPixmap(dpy, v->frame);
                if (v->pm) v->surf = cairo_xlib_surface_create(dpy, v->pm, a.visual, a.width, a.height);
            } else {                                      /* its last look, if we kept one */
                for (int j = 0; j < nwpix; j++)
                    if (wpix[j].frame == v->frame) {
                        v->pm = wpix[j].pm; v->pm_cached = 1;
                        v->wd = wpix[j].wd; v->ht = wpix[j].ht;
                        v->surf = cairo_xlib_surface_create(dpy, v->pm, wpix[j].vis, v->wd, v->ht);
                    }
            }
            cur_items[nitems++] = nwins;
        }
        nwins++;
    }
    if (list) XFree(list);
}

/* ---- screen captures -------------------------------------------------------------------- */

static cairo_surface_t *capture(int w, int h) {   /* the screen as it looks now, scaled to w x h */
    XImage *img = XGetImage(dpy, root, 0, 0, SW, SH, AllPlanes, ZPixmap);
    if (!img) return NULL;
    cairo_surface_t *full = cairo_image_surface_create_for_data((unsigned char *)img->data, CAIRO_FORMAT_RGB24,
                                                                SW, SH, img->bytes_per_line);
    cairo_surface_t *out = cairo_image_surface_create(CAIRO_FORMAT_RGB24, w, h);
    cairo_t *cr = cairo_create(out);
    cairo_scale(cr, (double)w / SW, (double)h / SH);
    cairo_set_source_surface(cr, full, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    cairo_paint(cr);
    cairo_destroy(cr);
    cairo_surface_destroy(full);
    XDestroyImage(img);
    return out;
}

static int cmp_win(const void *a, const void *b) {
    Window x = *(const Window *)a, y = *(const Window *)b;
    return x < y ? -1 : x > y;
}

static int desk_set(long d, Window *out) {   /* the normal windows on desktop d, sorted */
    unsigned long n; Window *list = client_list(&n);
    int k = 0;
    for (unsigned long i = 0; list && i < n && k < SNAP_WINS; i++)
        if (get_card(list[i], A_DESK, -1) == d && is_normal_window(list[i])) out[k++] = list[i];
    if (list) XFree(list);
    qsort(out, k, sizeof(Window), cmp_win);
    return k;
}

static int overlap(const struct snap *s, const Window *set, int n) {
    int common = 0;
    for (int i = 0, j = 0; i < s->n && j < n;) {
        if (s->set[i] == set[j]) { common++; i++; j++; }
        else if (s->set[i] < set[j]) i++; else j++;
    }
    return common;
}

static void track_pixmaps(void) {
    unsigned long n; Window *list = client_list(&n);
    long curd = get_card(root, A_CURDESK, 0);
    Window frames[MAX_WIN]; int nf = 0;
    for (unsigned long i = 0; list && i < n && nf < MAX_WIN; i++) frames[nf++] = frame_of(list[i]);
    for (int i = nwpix - 1; i >= 0; i--) {              /* windows that are gone */
        int there = 0;
        for (int j = 0; j < nf; j++) if (frames[j] == wpix[i].frame) there = 1;
        if (!there) { XFreePixmap(dpy, wpix[i].pm); wpix[i] = wpix[--nwpix]; }
    }
    for (unsigned long i = 0; list && i < n && i < (unsigned long)nf; i++) {
        long d = get_card(list[i], A_DESK, -1);
        XWindowAttributes a;
        if (d != curd || !is_normal_window(list[i]) || !XGetWindowAttributes(dpy, frames[i], &a)
            || a.map_state != IsViewable || a.width < 2 || a.height < 2) continue;
        Pixmap pm = XCompositeNameWindowPixmap(dpy, frames[i]);
        Window r; int x, y; unsigned int w, h, bw, depth;
        if (!pm || !XGetGeometry(dpy, pm, &r, &x, &y, &w, &h, &bw, &depth)) {   /* no compositor: no image */
            if (pm) XFreePixmap(dpy, pm);
            continue;
        }
        int k = -1;
        for (int j = 0; j < nwpix; j++) if (wpix[j].frame == frames[i]) k = j;
        if (k >= 0) XFreePixmap(dpy, wpix[k].pm);
        else if (nwpix < MAX_PIX) k = nwpix++;
        else { XFreePixmap(dpy, pm); continue; }
        wpix[k] = (struct wpix){frames[i], pm, a.visual, (int)w, (int)h};
    }
    if (list) XFree(list);
}

static void take_snapshot(void) {             /* the current desktop, as it looks now */
    Window set[SNAP_WINS];
    int n = desk_set(get_card(root, A_CURDESK, 0), set);
    if (!n) return;                           /* empty: the wallpaper says it all */
    struct snap *slot = NULL;
    for (int i = 0; i < MAX_SNAP; i++) {      /* the same windows' old picture, else a free or the oldest slot */
        struct snap *s = &snaps[i];
        if (s->img && s->n == n && overlap(s, set, n) == n) { slot = s; break; }
        if (!slot || (slot->img && (!s->img || s->used < slot->used))) slot = s;
    }
    cairo_surface_t *img = capture(TW, THUMB_H);
    if (!img) return;
    if (slot->img) cairo_surface_destroy(slot->img);
    slot->img = img;
    memcpy(slot->set, set, sizeof(Window) * n);
    slot->n = n;
    slot->used = now_ms();
}

/* the picture showing (most of) the windows now on desktop d */
static cairo_surface_t *find_snapshot(long d) {
    Window set[SNAP_WINS];
    int n = 0;
    for (int i = 0; i < nwins && n < SNAP_WINS; i++) if (wins[i].desk == d && !wins[i].minimized) set[n++] = wins[i].w;
    if (!n) return NULL;
    qsort(set, n, sizeof(Window), cmp_win);
    struct snap *best = NULL; int best_common = 0;
    for (int i = 0; i < MAX_SNAP; i++) {
        struct snap *s = &snaps[i];
        if (!s->img) continue;
        int c = overlap(s, set, n);
        if (c * 2 >= n && c * 2 >= s->n && (c > best_common || (c == best_common && best && s->used > best->used)))
            { best = s; best_common = c; }
    }
    return best ? best->img : NULL;
}

/* ---- the wallpaper (the background, as on macOS) ------------------------------------------ */

/* Xfce's wallpaper for desktop d: /backdrop/screen0/monitor<output>/workspace<d>/last-image,
 * preferring a named output (eDP-1) over Xfce's old numbered ones */
static int wallpaper_path(long d, char *out, size_t n) {
    FILE *f = popen("xfconf-query -c xfce4-desktop -l -v 2>/dev/null", "r");
    if (!f) return 0;
    char line[1024], want[64], fallback[1024] = "", *lines[512];
    int nl = 0, single = 1;
    long single_num = 0;
    while (nl < 512 && fgets(line, sizeof line, f)) {
        /* Xfce shows one wallpaper on every desktop unless "different per desktop" is on (its
         * default): then it's the one set for single-workspace-number (desktop 1) */
        if (!strncmp(line, "/backdrop/single-workspace-mode ", 32)) single = !strstr(line + 32, "false");
        else if (!strncmp(line, "/backdrop/single-workspace-number ", 34)) single_num = atol(line + 34);
        lines[nl++] = strdup(line);
    }
    pclose(f);
    if (single) d = single_num;
    snprintf(want, sizeof want, "/workspace%ld/last-image ", d);
    out[0] = 0;
    for (int i = 0; i < nl; i++) {
        char *line = lines[i];
        char *hit = strstr(line, want), *mon = strstr(line, "/monitor");
        if (!hit || !mon || strncmp(line, "/backdrop/screen0/", 18)) continue;
        char *val = hit + strlen(want);
        while (*val == ' ') val++;
        val[strcspn(val, "\n")] = 0;
        int numbered = mon[8] >= '0' && mon[8] <= '9';
        if (!numbered && !out[0]) snprintf(out, n, "%s", val);
        else if (numbered && !fallback[0]) snprintf(fallback, sizeof fallback, "%s", val);
    }
    for (int i = 0; i < nl; i++) free(lines[i]);
    if (!out[0]) snprintf(out, n, "%s", fallback);
    return out[0] != 0;
}

struct jpeg_failure { struct jpeg_error_mgr pub; jmp_buf jump; };
static void jpeg_fail(j_common_ptr ci) { longjmp(((struct jpeg_failure *)ci->err)->jump, 1); }   /* the default exit()s */
static void jpeg_quiet(j_common_ptr ci) { (void)ci; }

static cairo_surface_t *load_jpeg(const char *path) {   /* decoded at the smallest size >= screen */
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    unsigned char magic[3] = {0};
    if (fread(magic, 1, 3, f) != 3 || magic[0] != 0xFF || magic[1] != 0xD8 || magic[2] != 0xFF) {   /* not a JPEG */
        fclose(f);
        return NULL;
    }
    rewind(f);
    struct jpeg_decompress_struct ci;
    struct jpeg_failure jerr;
    unsigned char *volatile row = NULL;
    cairo_surface_t *volatile s = NULL;
    ci.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = jpeg_fail;                     /* a damaged file must not end the program */
    jerr.pub.output_message = jpeg_quiet;
    if (setjmp(jerr.jump)) {
        jpeg_destroy_decompress(&ci);
        fclose(f);
        free(row);
        if (s) cairo_surface_destroy(s);
        return NULL;
    }
    jpeg_create_decompress(&ci);
    jpeg_stdio_src(&ci, f);
    jpeg_read_header(&ci, TRUE);
    ci.out_color_space = JCS_RGB;
    ci.scale_num = 1;
    ci.scale_denom = 1;
    for (int den = 8; den > 1; den /= 2)
        if (ci.image_width / den >= (unsigned)SW && ci.image_height / den >= (unsigned)SH) { ci.scale_denom = den; break; }
    jpeg_start_decompress(&ci);
    s = cairo_image_surface_create(CAIRO_FORMAT_RGB24, ci.output_width, ci.output_height);
    row = malloc(ci.output_width * 3);
    if (cairo_surface_status(s) != CAIRO_STATUS_SUCCESS || !row || ci.output_components != 3) longjmp(jerr.jump, 1);
    unsigned char *px = cairo_image_surface_get_data(s);
    int stride = cairo_image_surface_get_stride(s);
    while (ci.output_scanline < ci.output_height) {
        unsigned y = ci.output_scanline;
        unsigned char *rp = row;
        jpeg_read_scanlines(&ci, &rp, 1);
        uint32_t *o = (uint32_t *)(px + y * stride);
        for (unsigned x = 0; x < ci.output_width; x++)
            o[x] = (uint32_t)row[x * 3] << 16 | (uint32_t)row[x * 3 + 1] << 8 | row[x * 3 + 2];
    }
    free(row);
    cairo_surface_mark_dirty(s);
    jpeg_finish_decompress(&ci);
    jpeg_destroy_decompress(&ci);
    fclose(f);
    return s;
}

/* the wallpaper at screen size, handed to the X server once as a plain pixmap: cairo then draws
 * from it on the server and keeps no big shared-memory upload buffers around afterwards */
static cairo_surface_t *wallpaper_on_server(cairo_surface_t *img) {
    double iw = cairo_image_surface_get_width(img), ih = cairo_image_surface_get_height(img);
    double s = fmax(SW / iw, SH / ih);
    cairo_surface_t *fit = cairo_image_surface_create(CAIRO_FORMAT_RGB24, SW, SH);
    cairo_t *cr = cairo_create(fit);
    cairo_translate(cr, (SW - iw * s) / 2, (SH - ih * s) / 2);
    cairo_scale(cr, s, s);
    cairo_set_source_surface(cr, img, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    cairo_paint(cr);
    cairo_destroy(cr);
    cairo_surface_flush(fit);
    int scr = DefaultScreen(dpy), depth = DefaultDepth(dpy, scr);
    Visual *vis = DefaultVisual(dpy, scr);
    cairo_surface_t *out = NULL;
    if (depth == 24 || depth == 32) {
        bg_pm = XCreatePixmap(dpy, root, SW, SH, depth);
        XImage *xi = XCreateImage(dpy, vis, depth, ZPixmap, 0, (char *)cairo_image_surface_get_data(fit),
                                  SW, SH, 32, cairo_image_surface_get_stride(fit));
        GC gc = XCreateGC(dpy, bg_pm, 0, NULL);
        XPutImage(dpy, bg_pm, gc, xi, 0, 0, 0, 0, SW, SH);
        XFreeGC(dpy, gc);
        xi->data = NULL;                                 /* the data belongs to cairo */
        XDestroyImage(xi);
        out = cairo_xlib_surface_create(dpy, bg_pm, vis, SW, SH);
    }
    cairo_surface_destroy(fit);
    return out;
}

static cairo_surface_t *load_wallpaper(long d) {
    char path[1024];
    if (!wallpaper_path(d, path, sizeof path)) return NULL;
    size_t n = strlen(path);
    if (n > 4 && !strcasecmp(path + n - 4, ".png")) {
        cairo_surface_t *s = cairo_image_surface_create_from_png(path);
        if (cairo_surface_status(s) == CAIRO_STATUS_SUCCESS) return s;
        cairo_surface_destroy(s);
        return NULL;
    }
    return load_jpeg(path);
}

/* ---- layout ------------------------------------------------------------------------------ */

static double bar_h(void) { return BAR_TOP + THUMB_H + LABEL_H; }

static void layout_desks(void) {
    long n = get_card(root, A_NDESK, 1);
    ndesk = n > MAX_DESK ? MAX_DESK : (int)n;
    double tw = TW, th = THUMB_H, pw = THUMB_H * 0.55;
    double total = ndesk * tw + ndesk * GAP + pw;
    double s = total > SW - 40 ? (SW - 40) / total : 1.0;
    double x = (SW - total * s) / 2;
    for (int i = 0; i < ndesk; i++) {
        desks[i] = (struct desk){x, BAR_TOP, tw * s, th * s};
        x += (tw + GAP) * s;
    }
    plus_x = x; plus_y = BAR_TOP + (th - pw) * s / 2; plus_w = pw * s; plus_h = pw * s;
    if (n >= MAX_SPACES) plus_w = plus_h = 0;            /* at the limit: no + */
}

static int by_position(const void *a, const void *b) {   /* top to bottom, then left to right */
    const struct win *p = &wins[*(const int *)a], *q = &wins[*(const int *)b];
    int pr = (p->y + p->ht / 2) / (SH / 3), qr = (q->y + q->ht / 2) / (SH / 3);
    if (pr != qr) return pr - qr;
    return (p->x + p->wd / 2) - (q->x + q->wd / 2);
}

static void layout_items(void) {
    if (!nitems) return;
    qsort(cur_items, nitems, sizeof(int), by_position);
    double ax = 48, ay = bar_h() + 24, aw = SW - 96, ah = SH - ay - 48, gap = 32, label = 24;
    int best_cols = 1; double best = 0;
    for (int cols = 1; cols <= nitems; cols++) {
        int rows = (nitems + cols - 1) / cols;
        double cw = (aw - (cols - 1) * gap) / cols, ch = (ah - (rows - 1) * gap) / rows - label, worst = 1.0;
        for (int k = 0; k < nitems; k++) {
            struct win *v = &wins[cur_items[k]];
            double s = fmin(cw / v->wd, ch / v->ht);
            if (s < worst) worst = s;
        }
        if (worst > best) { best = worst; best_cols = cols; }
    }
    int cols = best_cols, rows = (nitems + cols - 1) / cols;
    double cw = (aw - (cols - 1) * gap) / cols, ch = (ah - (rows - 1) * gap) / rows;
    double oy = ay + (ah - rows * ch - (rows - 1) * gap) / 2;
    for (int k = 0; k < nitems; k++) {
        struct win *v = &wins[cur_items[k]];
        int r = k / cols, c = k % cols, in_row = (r == rows - 1) ? nitems - r * cols : cols;
        double ox = ax + (aw - in_row * cw - (in_row - 1) * gap) / 2;
        double s = fmin(fmin(cw / v->wd, (ch - label) / v->ht), 0.9);
        v->tw = v->wd * s; v->th = v->ht * s;
        v->tx = ox + c * (cw + gap) + (cw - v->tw) / 2;
        v->ty = oy + r * (ch + gap) + (ch - label - v->th) / 2;
    }
}

/* ---- drawing ----------------------------------------------------------------------------- */

static void rounded(cairo_t *cr, double x, double y, double w, double h, double r) {
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
    cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
    cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
    cairo_close_path(cr);
}

static void text_centered(cairo_t *cr, const char *s, double cx, double y, double size, double maxw) {
    char full[256], buf[256];
    sp_copy_utf8(full, sizeof full - 4, s);              /* (room for the ellipsis) */
    snprintf(buf, sizeof buf, "%s", full);
    cairo_select_font_face(cr, "Inter", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, size);
    cairo_text_extents_t e;
    cairo_text_extents(cr, buf, &e);
    for (size_t keep = strlen(full); e.width > maxw && keep > 1; ) {   /* shorten with an ellipsis, between characters */
        keep--;
        sp_copy_utf8(buf, keep + 1, full);               /* the first `keep` bytes, whole characters only */
        strcat(buf, "…");
        cairo_text_extents(cr, buf, &e);
    }
    cairo_move_to(cr, cx - e.width / 2 - e.x_bearing, y);
    cairo_show_text(cr, buf);
}

static void desk_name(int d, char *out, size_t n) {
    for (int i = 0; i < nwins; i++)
        if (wins[i].desk == d && wins[i].fullscreen_space) { snprintf(out, n, "%s", wins[i].app); return; }
    snprintf(out, n, "Desktop %d", d + 1);
}

static int desk_is_space(int d) {
    for (int i = 0; i < nwins; i++) if (wins[i].desk == d && wins[i].fullscreen_space) return 1;
    return 0;
}

static int ordinary_desktops(void) {         /* desktops that are not a full-screen app's Space */
    int k = 0;
    for (int d = 0; d < ndesk; d++) if (!desk_is_space(d)) k++;
    return k;
}

/* Any desktop can be removed, as on a Mac. A full-screen Space goes by leaving full screen. An ordinary one goes
 * while another ordinary desktop is left; the Spaces that came from it are handed on to a neighbour. */
static int can_close(int d) { return ndesk > 1 && (desk_is_space(d) || ordinary_desktops() > 1); }

static void draw_desk(cairo_t *cr, int d, double at_x) {
    struct desk kk = desks[d], *k = &kk;
    k->x = at_x;
    cairo_save(cr);
    rounded(cr, k->x, k->y, k->w, k->h, 6);
    cairo_clip(cr);
    cairo_surface_t *pic = find_snapshot(d);
    if (pic) {                                           /* its picture */
        cairo_translate(cr, k->x, k->y);
        cairo_scale(cr, k->w / TW, k->h / THUMB_H);
        cairo_set_source_surface(cr, pic, 0, 0);
        cairo_paint(cr);
    } else {                                             /* no picture yet: the wallpaper, with the
                                                            desktop's windows as outlines and icons */
        if (bg) {
            cairo_save(cr);
            cairo_translate(cr, k->x, k->y);
            cairo_scale(cr, k->w / SW, k->h / SH);
            cairo_set_source_surface(cr, bg, 0, 0);
            cairo_paint(cr);
            cairo_restore(cr);
        } else {
            cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
            cairo_paint(cr);
        }
        double s = k->w / SW;
        for (int i = 0; i < nwins; i++) {
            struct win *v = &wins[i];
            if (v->desk != d || v->minimized) continue;
            double x = k->x + v->x * s, y = k->y + v->y * s, w = v->wd * s, h = v->ht * s;
            rounded(cr, x, y, w, h, 3);
            cairo_set_source_rgba(cr, 0.25, 0.25, 0.27, 0.9);
            cairo_fill_preserve(cr);
            cairo_set_source_rgba(cr, 1, 1, 1, 0.25);
            cairo_set_line_width(cr, 1);
            cairo_stroke(cr);
            if (v->icon) {
                double is = fmin(fmin(w, h) * 0.6, 20), iw = cairo_image_surface_get_width(v->icon);
                cairo_save(cr);
                cairo_translate(cr, x + (w - is) / 2, y + (h - is) / 2);
                cairo_scale(cr, is / iw, is / iw);
                cairo_set_source_surface(cr, v->icon, 0, 0);
                cairo_paint(cr);
                cairo_restore(cr);
            }
        }
    }
    cairo_restore(cr);
    int target = dragging && hover_desk == d;
    if (desk_dragging && d != press_desk) target = 0;
    if (d == cur || (d == hover_desk && !desk_dragging) || (desk_dragging && d == press_desk)) {
        rounded(cr, k->x - 2, k->y - 2, k->w + 4, k->h + 4, 7);
        if (target) cairo_set_source_rgba(cr, 0.25, 0.55, 1, 1);
        else cairo_set_source_rgba(cr, 1, 1, 1, d == cur ? 0.9 : 0.5);
        cairo_set_line_width(cr, target ? 3 : 2);
        cairo_stroke(cr);
    }
    char name[64];
    desk_name(d, name, sizeof name);
    cairo_set_source_rgba(cr, 1, 1, 1, 0.9);
    text_centered(cr, name, k->x + k->w / 2, k->y + k->h + 18, 12, k->w + GAP - 4);
    if (d == hover_desk && !dragging && !desk_dragging && can_close(d)) {   /* the x to remove it, top left */
        cairo_arc(cr, k->x, k->y, 9, 0, 2 * M_PI);
        cairo_set_source_rgba(cr, hover_close ? 0.9 : 0.75, hover_close ? 0.9 : 0.75, hover_close ? 0.9 : 0.75, 1);
        cairo_fill(cr);
        cairo_set_source_rgb(cr, 0.15, 0.15, 0.15);
        cairo_set_line_width(cr, 1.8);
        cairo_move_to(cr, k->x - 3.5, k->y - 3.5); cairo_line_to(cr, k->x + 3.5, k->y + 3.5);
        cairo_move_to(cr, k->x + 3.5, k->y - 3.5); cairo_line_to(cr, k->x - 3.5, k->y + 3.5);
        cairo_stroke(cr);
    }
}

/* while a desktop is dragged: the slot it would land in */
static int drop_slot(void) {
    int slot = 0;
    for (int d = 0; d < ndesk; d++)
        if (d != press_desk && desks[d].x + desks[d].w / 2 < ptr_x) slot++;
    return slot;
}

static void draw_desks(cairo_t *cr) {
    if (!desk_dragging) {
        for (int d = 0; d < ndesk; d++) draw_desk(cr, d, desks[d].x);
        return;
    }
    int slot = drop_slot(), s = 0;
    for (int d = 0; d < ndesk; d++) {                    /* the others make room */
        if (d == press_desk) continue;
        if (s == slot) s++;
        draw_desk(cr, d, desks[s].x);
        s++;
    }
    double w = desks[press_desk].w;                      /* the dragged one follows the pointer */
    cairo_push_group(cr);
    draw_desk(cr, press_desk, ptr_x - w / 2);
    cairo_pop_group_to_source(cr);
    cairo_paint_with_alpha(cr, 0.9);
}

static void dump_layout(void) {   /* for tests (MISSION_CONTROL_LAYOUT) */
    const char *path = getenv("MISSION_CONTROL_LAYOUT");
    if (!path) return;
    char tmp[600];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "cur %ld\nview %ld\n", cur, view);
    for (int d = 0; d < ndesk; d++) {
        char name[64];
        desk_name(d, name, sizeof name);
        fprintf(f, "desk %d %.0f %.0f %.0f %.0f %d %s\n", d, desks[d].x, desks[d].y, desks[d].w, desks[d].h,
                find_snapshot(d) != NULL, name);
    }
    if (plus_w > 0) fprintf(f, "plus %.0f %.0f %.0f %.0f\n", plus_x, plus_y, plus_w, plus_h);
    for (int k = 0; k < nitems; k++) {
        struct win *v = &wins[cur_items[k]];
        fprintf(f, "item 0x%lx %.0f %.0f %.0f %.0f%s\n", v->w, v->tx, v->ty, v->tw, v->th, v->minimized ? (v->surf ? " min img" : " min") : "");
    }
    fclose(f);
    rename(tmp, path);
}

static void draw(void) {
    if (!is_open) return;
    dump_layout();
    cairo_surface_t *xs = cairo_xlib_surface_create(dpy, ov, DefaultVisual(dpy, DefaultScreen(dpy)), SW, SH);
    cairo_t *cr = cairo_create(xs);
    cairo_push_group(cr);                                /* draw off screen, show at once */
    cairo_set_source_rgb(cr, 0.12, 0.12, 0.13);
    cairo_paint(cr);
    if (bg) {                                            /* the wallpaper, already screen-sized */
        cairo_set_source_surface(cr, bg, 0, 0);
        cairo_paint(cr);
    }
    cairo_set_source_rgba(cr, 0, 0, 0, 0.15);
    cairo_paint(cr);
    cairo_rectangle(cr, 0, 0, SW, bar_h());              /* the Spaces bar */
    cairo_set_source_rgba(cr, 0, 0, 0, 0.25);
    cairo_fill(cr);
    draw_desks(cr);
    if (plus_w > 0) {
    rounded(cr, plus_x, plus_y, plus_w, plus_h, 8);      /* + */
    cairo_set_source_rgba(cr, 1, 1, 1, hover_plus ? (dragging ? 0.45 : 0.30) : 0.15);
    cairo_fill(cr);
    cairo_set_source_rgba(cr, 1, 1, 1, 0.9);
    cairo_set_line_width(cr, 2);
    double pcx = plus_x + plus_w / 2, pcy = plus_y + plus_h / 2, ps = plus_w * 0.22;
    cairo_move_to(cr, pcx - ps, pcy); cairo_line_to(cr, pcx + ps, pcy);
    cairo_move_to(cr, pcx, pcy - ps); cairo_line_to(cr, pcx, pcy + ps);
    cairo_stroke(cr);
    }

    for (int k = 0; k < nitems; k++) {                   /* the current desktop's windows */
        struct win *v = &wins[cur_items[k]];
        int drag_this = dragging && cur_items[k] == press_item;
        double x = v->tx, y = v->ty, w = v->tw, h = v->th;
        if (drag_this) {                                 /* follows the pointer, smaller over the bar */
            double s = ptr_y < bar_h() ? fmin(1.0, 160 / w) : 1.0;
            w *= s; h *= s;
            x = ptr_x - (press_x - v->tx) * s; y = ptr_y - (press_y - v->ty) * s;
        }
        cairo_save(cr);
        if (drag_this) cairo_push_group(cr);
        rounded(cr, x, y, w, h, 6);
        cairo_clip(cr);
        if (v->surf) {
            cairo_translate(cr, x, y);
            cairo_scale(cr, w / v->wd, h / v->ht);
            cairo_set_source_surface(cr, v->surf, 0, 0);
            cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
            cairo_paint_with_alpha(cr, v->minimized ? 0.6 : 1.0);   /* (a minimized one is dimmed) */
        } else if (v->minimized) {                       /* no last look kept: dimmed, with its icon */
            cairo_set_source_rgba(cr, 0.2, 0.2, 0.22, 0.55);
            cairo_paint(cr);
            if (v->icon) {
                double is = fmin(fmin(w, h) * 0.45, 72), iw = cairo_image_surface_get_width(v->icon);
                cairo_translate(cr, x + (w - is) / 2, y + (h - is) / 2);
                cairo_scale(cr, is / iw, is / iw);
                cairo_set_source_surface(cr, v->icon, 0, 0);
                cairo_paint_with_alpha(cr, 0.7);
            }
        } else {
            cairo_set_source_rgba(cr, 0.3, 0.3, 0.32, 1);
            cairo_paint(cr);
        }
        if (drag_this) { cairo_pop_group_to_source(cr); cairo_reset_clip(cr); cairo_paint_with_alpha(cr, 0.85); }
        cairo_restore(cr);
        if (v->minimized && !drag_this) {                /* the badge: the yellow minimize button */
            double bx = x + w - 14, by = y + h - 14;
            cairo_arc(cr, bx, by, 9, 0, 2 * M_PI);
            cairo_set_source_rgba(cr, 1.0, 0.74, 0.18, 1);
            cairo_fill(cr);
            cairo_set_source_rgba(cr, 0.35, 0.22, 0.0, 1);
            cairo_set_line_width(cr, 2);
            cairo_move_to(cr, bx - 4, by); cairo_line_to(cr, bx + 4, by);
            cairo_stroke(cr);
        }
        if (k == hover_item && !dragging) {
            rounded(cr, x - 3, y - 3, w + 6, h + 6, 8);
            cairo_set_source_rgba(cr, 0.25, 0.55, 1, 0.9);
            cairo_set_line_width(cr, 3);
            cairo_stroke(cr);
        }
        if (!drag_this) {                                /* icon and title underneath */
            double iy = y + h + 6;
            if (v->icon) {
                double iw = cairo_image_surface_get_width(v->icon);
                cairo_save(cr);
                cairo_translate(cr, x + w / 2 - 10, iy);
                cairo_scale(cr, 20 / iw, 20 / iw);
                cairo_set_source_surface(cr, v->icon, 0, 0);
                cairo_paint(cr);
                cairo_restore(cr);
            }
            if (k == hover_item) {
                cairo_set_source_rgba(cr, 1, 1, 1, 0.95);
                text_centered(cr, v->title, x + w / 2, iy + 36, 12, fmax(w, 220));
            }
        }
    }
    cairo_pop_group_to_source(cr);
    cairo_paint(cr);
    cairo_destroy(cr);
    cairo_surface_destroy(xs);
    XFlush(dpy);
}

/* ---- hit testing ------------------------------------------------------------------------- */

static void update_hover(int x, int y) {
    hover_item = -1; hover_desk = -1; hover_close = 0;
    hover_plus = plus_w > 0 && x >= plus_x && x < plus_x + plus_w && y >= plus_y - 20 && y < plus_y + plus_h + 20;
    for (int d = 0; d < ndesk; d++) {
        struct desk *k = &desks[d];
        if (x >= k->x - 10 && x < k->x + k->w && y >= k->y - 10 && y < k->y + k->h + LABEL_H) {
            hover_desk = d;
            hover_close = hypot(x - k->x, y - k->y) <= 10 && can_close(d);
        }
    }
    for (int k = nitems - 1; k >= 0; k--) {
        struct win *v = &wins[cur_items[k]];
        if (x >= v->tx && x < v->tx + v->tw && y >= v->ty && y < v->ty + v->th) { hover_item = k; break; }
    }
}

/* ---- opening and closing ----------------------------------------------------------------- */

/* if desktop d is a full-screen app's Space: the desktop the app came from, else d */
static long origin_of_space(long d) {
    unsigned long n; Window *list = client_list(&n);
    long o = d;
    for (unsigned long i = 0; list && i < n; i++)
        if (get_card(list[i], A_DESK, -1) == d && has_atom(list[i], A_STATE, A_FULL)) {
            long w = get_card(list[i], A_ORIGIN, -1);
            if (w >= d) w = d > 0 ? d - 1 : 0;           /* a Space comes after its origin: ignore bad data */
            if (w >= 0) { o = w; break; }
        }
    if (list) XFree(list);
    return o;
}

static void create_overlay(void) {
    if (ov != None) return;
    XSetWindowAttributes at = {0};
    at.override_redirect = True;
    at.background_pixel = BlackPixel(dpy, DefaultScreen(dpy));
    at.event_mask = ExposureMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | KeyPressMask;
    ov = XCreateWindow(dpy, root, 0, 0, SW, SH, 0, CopyFromParent, InputOutput, CopyFromParent,
                       CWOverrideRedirect | CWEventMask | CWBackPixel, &at);
    XStoreName(dpy, ov, "Mission Control");
}

static void open_mc(void) {
    if (is_open) return;
    cur = get_card(root, A_CURDESK, 0);
    view = origin_of_space(cur);
    if (bg) cairo_surface_destroy(bg);
    bg = NULL;
    cairo_surface_t *img = load_wallpaper(cur);
    if (img) { bg = wallpaper_on_server(img); cairo_surface_destroy(img); }
    take_snapshot();                                     /* the current desktop, as it is now */
    create_overlay();
    if (view != cur) {             /* from a full-screen app: its desktop's windows, live. Switch
                                      there behind the overlay (back again if nothing is chosen) */
        XMapRaised(dpy, ov);
        XSync(dpy, False);
        switch_desktop(view);
        sp_wait_card(dpy, root, A_CURDESK, view, 500);
        usleep(80000);                                   /* its windows are mapped */
    }
    XCompositeRedirectSubwindows(dpy, root, CompositeRedirectAutomatic);   /* window images, even
                                                        with no compositor or one that steps aside */
    read_windows();
    layout_desks();
    layout_items();
    is_open = 1;
    hover_item = hover_desk = press_item = press_desk = -1; dragging = desk_dragging = 0;
    XMapRaised(dpy, ov);
    for (int i = 0; i < 20; i++) {                      /* keys: Esc and the toggle keys close it */
        if (XGrabKeyboard(dpy, ov, True, GrabModeAsync, GrabModeAsync, CurrentTime) == GrabSuccess) break;
        usleep(10000);
    }
    Window r, c; int wx, wy; unsigned int m;
    XQueryPointer(dpy, root, &r, &c, &ptr_x, &ptr_y, &wx, &wy, &m);
    update_hover(ptr_x, ptr_y);
    draw();
}

static void close_mc(Window go_to, long switch_to) {
    if (!is_open) return;
    is_open = 0;
    if (getenv("MISSION_CONTROL_LAYOUT")) remove(getenv("MISSION_CONTROL_LAYOUT"));   /* tests: closed */
    XUngrabKeyboard(dpy, CurrentTime);
    XUnmapWindow(dpy, ov);
    free_wins();
    if (bg) { cairo_surface_destroy(bg); bg = NULL; }
    if (bg_pm) { XFreePixmap(dpy, bg_pm); bg_pm = None; }
    XCompositeUnredirectSubwindows(dpy, root, CompositeRedirectAutomatic);
    if (switch_to >= 0 && switch_to != view) switch_desktop(switch_to);
    else if (switch_to < 0 && go_to == None && view != cur) switch_desktop(cur);   /* back to the app */
    if (go_to != None) activate(go_to);
    XFlush(dpy);
    cairo_debug_reset_static_data();                     /* closed: give the memory back */
    malloc_trim(0);
}

/* ---- managing desktops ------------------------------------------------------------------- */

static void refresh(void) {
    long n = get_card(root, A_NDESK, 1);
    if (view >= n) view = n - 1;                         /* desktops went away behind our back */
    if (cur >= n) cur = n - 1;
    read_windows();
    layout_desks();
    layout_items();
    update_hover(ptr_x, ptr_y);
    draw();
}

static void busy(int on) { sp_busy_set(dpy, root, A_BUSY, on); }   /* tells `fullscreen` to leave the layout alone */

/* Renumber the desktops: `map[old]` is the new number of every window on desktop `old` (all windows,
 * minimized and hidden ones too, not only those shown in the overview), and of every full-screen
 * app's origin. It waits until the window manager has really moved them. */
static void move_all(const long *map, long n) {
    unsigned long cnt; Window *list = client_list(&cnt);
    long *was = list ? malloc(sizeof(long) * cnt) : NULL;
    if (!was) { if (list) XFree(list); return; }
    for (unsigned long i = 0; i < cnt; i++) {
        long d = get_card(list[i], A_DESK, -1);
        was[i] = d;
        if (!sp_sticky(d) && d < n && map[d] >= 0 && map[d] != d) move_to_desktop(list[i], map[d]);
        long o = get_card(list[i], A_ORIGIN, -1);
        if (o >= 0 && o < n && map[o] >= 0 && map[o] != o)
            XChangeProperty(dpy, list[i], A_ORIGIN, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&map[o], 1);
    }
    for (unsigned long i = 0; i < cnt; i++)
        if (!sp_sticky(was[i]) && was[i] < n && map[was[i]] >= 0)
            sp_wait_card(dpy, list[i], A_DESK, map[was[i]], SP_WAIT_MS);
    free(was);
    XFree(list);
}

static void add_desktop(Window carry) {
    long n = get_card(root, A_NDESK, 1);
    if (n >= MAX_SPACES) return;
    busy(1);
    set_desktops_wait(n + 1);
    adjust_base(+1);
    if (carry != None) { move_to_desktop(carry, n); sp_wait_card(dpy, carry, A_DESK, n, SP_WAIT_MS); }
    busy(0);
    refresh();
}

static void leave_full_screen(int d) {                   /* × on a full-screen app's Space */
    Atom state = XInternAtom(dpy, "_NET_WM_STATE", False);
    for (int i = 0; i < nwins; i++)
        if (wins[i].desk == d && wins[i].fullscreen_space)
            client_msg(wins[i].w, state, 0, (long)A_FULL, 0);
    for (int t = 0; t < 600; t += 10) {
        int still = 0;
        for (int i = 0; i < nwins; i++)
            if (wins[i].desk == d && wins[i].fullscreen_space && has_atom(wins[i].w, A_STATE, A_FULL)) still = 1;
        if (!still) break;
        XSync(dpy, False);
        usleep(10000);
    }
    refresh();       /* (`fullscreen` takes the empty Space away by itself) */
}

static void remove_desktop(int d) {
    long n = get_card(root, A_NDESK, 1);
    if (n <= 1 || n > MAX_DESK || d < 0 || d >= n) return;
    if (desk_is_space(d)) { leave_full_screen(d); return; }
    long to = -1;                                        /* its windows go to the nearest ordinary desktop (before it first) */
    for (long x = d - 1; x >= 0 && to < 0; x--) if (!desk_is_space(x)) to = x;
    for (long x = d + 1; x < n && to < 0; x++) if (!desk_is_space(x)) to = x;
    if (to < 0) return;                                  /* the last ordinary desktop stays */
    long map[MAX_DESK], pmap[MAX_DESK];
    if (to < d) {                                        /* the usual case: later desktops move down one. The Spaces that came
                                                            from d now follow `to`, whose origin they take over (map[d] = to) */
        for (long x = 0; x < n; x++) map[x] = x < d ? x : x - 1;
    } else {                                             /* d is the first desktop and has nothing before it to hand its Spaces
                                                            to: they go behind the next desktop's own Spaces, in front of the rest */
        long a = 0, b = 0;
        while (d + 1 + a < n && desk_is_space(d + 1 + a)) a++;           /* d's Spaces: d+1 .. d+a */
        while (to + 1 + b < n && desk_is_space(to + 1 + b)) b++;         /* the next desktop's: to+1 .. to+b */
        for (long x = 0; x < n; x++) {
            if (x == d) map[x] = 0;
            else if (x > d && x <= d + a) map[x] = b + (x - d);          /* d's Spaces, after the next desktop's */
            else if (x == to) map[x] = 0;
            else if (x > to && x <= to + b) map[x] = x - to;
            else map[x] = x - 1;
        }
    }
    map[d] = map[to];                                    /* d's windows, and its Spaces' origin, are `to` now */
    memcpy(pmap, map, sizeof map);
    pmap[d] = -1;
    long pend[SP_MAX], was_pending = 0;
    int np = sp_pending_read(dpy, root, A_PENDING, pend, SP_MAX);
    for (int i = 0; i < np; i++) if (pend[i] == d) was_pending = 1;
    busy(1);
    move_all(map, n);
    sp_pending_remap(dpy, root, A_PENDING, pmap, (int)n);
    long here = get_card(root, A_CURDESK, 0);
    if (here >= 0 && here < n && map[here] != here) switch_wait(map[here]);   /* the same windows stay in view */
    set_desktops_wait(n - 1);
    if (!was_pending) adjust_base(-1);                   /* (an empty Space waiting to go is not an ordinary desktop) */
    cur = map[cur < n ? cur : n - 1];
    view = map[view < n ? view : n - 1];
    busy(0);
    refresh();
}

/* A full-screen Space dragged to another place (never first: it needs a desktop before it): it comes from the
 * desktop before its new place, as it would on a Mac where Spaces are simply put in any order */
static void reorder_space(int from, int to) {
    long n = get_card(root, A_NDESK, 1);
    if (to < 1) to = 1;                                  /* the first place is for a desktop */
    if (n > MAX_DESK || from < 0 || from >= n || to >= n || from == to) return;
    long order[MAX_DESK], map[MAX_DESK];
    int k = 0;
    for (long x = 0; x < n; x++) if (x != from) order[k++] = x;
    memmove(&order[to + 1], &order[to], sizeof(long) * (n - 1 - to));
    order[to] = from;
    for (long i = 0; i < n; i++) map[order[i]] = i;
    long host = 0;                                       /* the desktop it now follows, by its new number */
    for (long i = to - 1; i >= 0; i--) if (!desk_is_space((int)order[i])) { host = i; break; }
    Window moved[8]; int nm = 0;
    for (int i = 0; i < nwins && nm < 8; i++) if (wins[i].desk == from && wins[i].fullscreen_space) moved[nm++] = wins[i].w;
    busy(1);
    move_all(map, n);
    for (int i = 0; i < nm; i++)                         /* (move_all renumbered its origin; this is the new one) */
        XChangeProperty(dpy, moved[i], A_ORIGIN, XA_CARDINAL, 32, PropModeReplace, (unsigned char *)&host, 1);
    sp_pending_remap(dpy, root, A_PENDING, map, (int)n);
    long here = get_card(root, A_CURDESK, 0);
    if (here >= 0 && here < n && map[here] != here) switch_wait(map[here]);
    cur = map[cur < n ? cur : n - 1];
    view = map[view < n ? view : n - 1];
    busy(0);
    refresh();
}

/* move desktop `from` to position `to`; windows go with their desktop. A full-screen app's Space stays right
 * after the desktop it came from, so a desktop moves together with its Spaces (a Space itself is moved by
 * reorder_space) */
static void reorder_desktops(int from, int to) {
    long n = get_card(root, A_NDESK, 1);
    if (n > MAX_DESK || from < 0 || from >= n || to < 0 || to >= n || from == to) return;
    if (desk_is_space(from)) { reorder_space(from, to); return; }
    int unit[MAX_DESK], ustart[MAX_DESK], ulen[MAX_DESK], nu = 0;
    for (int x = 0; x < n; x++) {
        if (x > 0 && desk_is_space(x)) { unit[x] = unit[x - 1]; ulen[unit[x]]++; }
        else { unit[x] = nu; ustart[nu] = x; ulen[nu] = 1; nu++; }
    }
    int uf = unit[from], ut = unit[to];
    if (uf == ut) { draw(); return; }
    int order[MAX_DESK], k = 0, pos = 0;
    for (int u = 0; u < nu; u++) { if (u == ut) pos = k + (ut > uf); if (u != uf) order[k++] = u; }
    memmove(&order[pos + 1], &order[pos], sizeof(int) * (k - pos));
    order[pos] = uf;
    long map[MAX_DESK];
    int idx = 0;
    for (int i = 0; i < nu; i++) for (int j = 0; j < ulen[order[i]]; j++) map[ustart[order[i]] + j] = idx++;
    busy(1);
    move_all(map, n);
    sp_pending_remap(dpy, root, A_PENDING, map, (int)n);
    long here = get_card(root, A_CURDESK, 0);
    if (here >= 0 && here < n && map[here] != here) switch_wait(map[here]);
    cur = map[cur < n ? cur : n - 1];
    view = map[view < n ? view : n - 1];
    busy(0);
    refresh();
}

/* ---- events ------------------------------------------------------------------------------ */

static void on_release(int x, int y) {
    update_hover(x, y);
    if (desk_dragging) {
        int from = press_desk, to = drop_slot();
        desk_dragging = 0; press_desk = -1;
        if (to != from) reorder_desktops(from, to); else draw();
        return;
    }
    int pdesk = press_desk, pclose = press_close;
    press_desk = press_close = -1;
    if (dragging) {
        Window w = wins[press_item].w;
        dragging = 0; press_item = -1;
        if (hover_desk >= 0 && hover_desk != view && !desk_is_space(hover_desk)) {   /* (a full-screen app's Space is its app's alone) */
            move_to_desktop(w, hover_desk);
            sp_wait_card(dpy, w, A_DESK, hover_desk, SP_WAIT_MS);
            refresh();
        } else if (hover_plus) {
            add_desktop(w);
        } else {
            draw();
        }
        return;
    }
    int pressed = press_item;
    press_item = -1;
    if (hover_close && hover_desk >= 0) {                /* only if it was pressed there too */
        if (hover_desk == pclose) remove_desktop(hover_desk); else draw();
        return;
    }
    if (hover_plus) { add_desktop(None); return; }
    if (hover_item >= 0 && pressed >= 0 && cur_items[hover_item] == pressed) { close_mc(wins[pressed].w, -1); return; }
    if (hover_desk >= 0 && hover_desk == pdesk) { close_mc(None, hover_desk); return; }
    close_mc(None, -1);
}

static void resized(int w, int h) {                      /* the screen changed size */
    if (is_open) close_mc(None, -1);
    SW = w; SH = h; TW = THUMB_H * SW / SH;
    if (ov != None) { XDestroyWindow(dpy, ov); ov = None; }
    for (int i = 0; i < MAX_SNAP; i++) {                 /* the pictures are the wrong size now */
        if (snaps[i].img) cairo_surface_destroy(snaps[i].img);
        memset(&snaps[i], 0, sizeof snaps[i]);
    }
}

static void handle(XEvent *e) {
    if (e->type == SelectionClear) exit(0);              /* another copy took over */
    if (e->type == ConfigureNotify && e->xconfigure.window == root) {
        if (e->xconfigure.width != SW || e->xconfigure.height != SH) resized(e->xconfigure.width, e->xconfigure.height);
        return;
    }
    if (e->type == ClientMessage && e->xclient.message_type == A_MSG) {
        long what = e->xclient.data.l[0];                /* 0 toggle, 1 quit, 2 open, 3 close */
        if (what == 1) exit(0);                          /* a new copy takes over */
        if (is_open && what != 2) close_mc(None, -1);
        else if (!is_open && what != 3) open_mc();
        return;
    }
    if (e->type == PropertyNotify && e->xproperty.window == root) {
        if (e->xproperty.atom == A_CURDESK) snap_due = now_ms() + SNAP_DELAY_MS;   /* hook: arrived */
        if (is_open && (e->xproperty.atom == A_CLIENTS || e->xproperty.atom == A_CLIENTS_PLAIN ||
                        e->xproperty.atom == A_NDESK || e->xproperty.atom == A_CURDESK))
            refresh_due = now_ms() + 80;                 /* something changed the desktops or windows: show it */
        return;
    }
    /* hook: a window opened, closed, moved or resized (menus and pop-ups don't count) */
    if ((e->type == MapNotify && !e->xmap.override_redirect && e->xmap.event == root) ||
        (e->type == UnmapNotify && e->xunmap.event == root) ||
        (e->type == ConfigureNotify && !e->xconfigure.override_redirect && e->xconfigure.event == root)) {
        Window w = e->type == MapNotify ? e->xmap.window : e->type == UnmapNotify ? e->xunmap.window : e->xconfigure.window;
        XWindowAttributes wa;                            /* tooltips and menus coming and going are not worth a picture */
        int popup = e->type == UnmapNotify && XGetWindowAttributes(dpy, w, &wa) && wa.override_redirect;
        if (!is_open && w != ov && w != ctl && !popup) snap_due = now_ms() + SNAP_DELAY_MS;
        return;
    }
    if (!is_open) return;
    switch (e->type) {
    case Expose:
        if (e->xexpose.count == 0) draw();
        break;
    case MotionNotify: {
        while (XCheckTypedWindowEvent(dpy, ov, MotionNotify, e)) {}   /* only the latest position */
        ptr_x = e->xmotion.x; ptr_y = e->xmotion.y;
        int hi = hover_item, hd = hover_desk, hc = hover_close, hp = hover_plus;
        if (press_item >= 0 && !dragging && hypot(ptr_x - press_x, ptr_y - press_y) > DRAG_PX) dragging = 1;
        if (press_desk >= 0 && !desk_dragging && hypot(ptr_x - press_x, ptr_y - press_y) > DRAG_PX) desk_dragging = 1;
        update_hover(ptr_x, ptr_y);
        if (dragging || desk_dragging || hi != hover_item || hd != hover_desk || hc != hover_close || hp != hover_plus) draw();
        break;
    }
    case ButtonPress:
        if (e->xbutton.button != 1) break;
        press_x = ptr_x = e->xbutton.x; press_y = ptr_y = e->xbutton.y;
        update_hover(press_x, press_y);
        press_item = hover_item >= 0 ? cur_items[hover_item] : -1;
        press_desk = (hover_desk >= 0 && !hover_close && press_y < bar_h()) ? hover_desk : -1;
        press_close = hover_close ? hover_desk : -1;
        break;
    case ButtonRelease:
        if (e->xbutton.button == 1) on_release(e->xbutton.x, e->xbutton.y);
        break;
    case KeyPress: {
        KeySym k = XLookupKeysym(&e->xkey, 0);
        if (k == XK_Escape || k == XK_F3 || k == XF86XK_LaunchA || (k == XK_Up && (e->xkey.state & ControlMask))) close_mc(None, -1);
        else if (k == XK_Return && hover_item >= 0) close_mc(wins[cur_items[hover_item]].w, -1);
        break;
    }
    }
}

int main(int argc, char **argv) {
    int daemon = 0, what = 0;
    if (argc > 1) {
        if (!strcmp(argv[1], "--daemon")) daemon = 1;
        else if (!strcmp(argv[1], "--open")) what = 2;
        else if (!strcmp(argv[1], "--close")) what = 3;
        else { fprintf(stderr, "usage: %s [--open|--close|--daemon]\n", argv[0]); return 1; }
    }
    dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "mission-control: cannot open display\n"); return 1; }
    XSetErrorHandler(ignore_errors);
    root = DefaultRootWindow(dpy);
    SW = DisplayWidth(dpy, DefaultScreen(dpy)); SH = DisplayHeight(dpy, DefaultScreen(dpy));
    TW = THUMB_H * SW / SH;
    A_CLIENTS = XInternAtom(dpy, "_NET_CLIENT_LIST_STACKING", False);
    A_CLIENTS_PLAIN = XInternAtom(dpy, "_NET_CLIENT_LIST", False);
    A_ACTIVE = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
    A_DESK = XInternAtom(dpy, "_NET_WM_DESKTOP", False);
    A_NDESK = XInternAtom(dpy, "_NET_NUMBER_OF_DESKTOPS", False);
    A_CURDESK = XInternAtom(dpy, "_NET_CURRENT_DESKTOP", False);
    A_TYPE = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
    A_TYPE_NORMAL = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_NORMAL", False);
    A_TYPE_DIALOG = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DIALOG", False);
    A_STATE = XInternAtom(dpy, "_NET_WM_STATE", False);
    A_HIDDEN = XInternAtom(dpy, "_NET_WM_STATE_HIDDEN", False);
    A_SKIP_TB = XInternAtom(dpy, "_NET_WM_STATE_SKIP_TASKBAR", False);
    A_FULL = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
    A_NAME = XInternAtom(dpy, "_NET_WM_NAME", False);
    A_UTF8 = XInternAtom(dpy, "UTF8_STRING", False);
    A_ICON = XInternAtom(dpy, "_NET_WM_ICON", False);
    A_ORIGIN = XInternAtom(dpy, "_MACOS_FULLSCREEN_ORIGIN", False);
    A_SEL = XInternAtom(dpy, "_MACOS_MISSION_CONTROL", False);
    A_MSG = XInternAtom(dpy, "_MACOS_MISSION_CONTROL_MSG", False);
    A_PENDING = XInternAtom(dpy, "_MACOS_PENDING_SPACES", False);
    A_BUSY = XInternAtom(dpy, "_MACOS_LAYOUT_BUSY", False);

    Window owner = XGetSelectionOwner(dpy, A_SEL);
    if (owner != None) {                                 /* a copy runs: ask it */
        XEvent e = {0};
        e.xclient.type = ClientMessage; e.xclient.window = owner;
        e.xclient.message_type = A_MSG; e.xclient.format = 32;
        e.xclient.data.l[0] = daemon ? 1 : what;         /* 1: quit, this one takes over */
        XSendEvent(dpy, owner, False, NoEventMask, &e);
        XFlush(dpy);
        if (!daemon) return 0;
        usleep(200000);
    }
    ctl = XCreateSimpleWindow(dpy, root, -1, -1, 1, 1, 0, 0, 0);
    XSetSelectionOwner(dpy, A_SEL, ctl, CurrentTime);
    XSelectInput(dpy, root, PropertyChangeMask | SubstructureNotifyMask | StructureNotifyMask);
    if (what == 3) return 0;
    if (!daemon) open_mc();                              /* no copy running: open once */

    for (;;) {
        int timeout = -1;
        if (snap_due >= 0) {
            long left = snap_due - now_ms();
            if (left <= 0) {
                snap_due = -1;
                if (!is_open) { track_pixmaps(); take_snapshot(); }
            } else timeout = (int)left;
        }
        if (refresh_due >= 0) {
            long left = refresh_due - now_ms();
            if (!is_open) refresh_due = -1;
            else if (press_item >= 0 || press_desk >= 0 || dragging || desk_dragging) timeout = 100;   /* not under the pointer's feet */
            else if (left <= 0) { refresh_due = -1; refresh(); }
            else if (timeout < 0 || timeout > left) timeout = (int)left;
        }
        if (!daemon && !is_open) return 0;
        XFlush(dpy);
        if (!XPending(dpy)) {
            struct pollfd pfd = {ConnectionNumber(dpy), POLLIN, 0};
            poll(&pfd, 1, timeout);
        }
        while (XPending(dpy)) {
            XEvent e;
            XNextEvent(dpy, &e);
            handle(&e);
        }
    }
}
