/* idle-watch: tells you when the screen is about to go to sleep for lack of activity, and when you
 * are back. Prints "idle" when you have been inactive as long as the screen's power-save timer, and
 * "active" at the next key press or pointer movement. It sleeps in between: the X server tells it
 * (an XSync alarm on the idle counter), nothing is polled.
 *
 * The time is the one the screen uses: the X server's DPMS timeout, which Xfce's Power Manager sets
 * from its "Display" settings (and swaps when you plug or unplug the charger). The smallest of the
 * standby/suspend/off times that is not zero, and of the screen saver's time (that is when the screen
 * locker locks, and locking hands the session to the login screen, which may stop the keyboard light
 * from being changed any more). It says "idle" 10 seconds before that, so the light is already off when
 * the screen blanks or locks. DPMS off and no screen saver: it never says "idle".
 * It is read again at every "active", so a change in Power Manager is picked up.
 *
 * For tests: IDLE_WATCH_SECONDS=N uses N seconds instead of the DPMS time.
 */
#include <X11/Xlib.h>
#include <X11/extensions/dpms.h>
#include <X11/extensions/sync.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static Display *dpy;
static XSyncCounter idle_counter = None;
static XSyncAlarm alarm_id = None;
static int sync_event_base;

#define NEVER_MS (1LL << 40)               /* "never": further away than anyone will be idle */

static long long idle_threshold_ms(void) {
    const char *over = getenv("IDLE_WATCH_SECONDS");
    if (over && atol(over) > 0) return atol(over) * 1000LL;
    long long best = 0;
    int dummy1, dummy2;
    if (DPMSQueryExtension(dpy, &dummy1, &dummy2) && DPMSCapable(dpy)) {
        CARD16 level; BOOL on;
        DPMSInfo(dpy, &level, &on);
        if (on) {
            CARD16 standby = 0, suspend = 0, off = 0;
            DPMSGetTimeouts(dpy, &standby, &suspend, &off);
            CARD16 t[3] = {standby, suspend, off};
            for (int i = 0; i < 3; i++)
                if (t[i] && (!best || t[i] * 1000LL < best)) best = t[i] * 1000LL;
        }
    }
    int timeout, interval, prefer, allow;                      /* the screen saver / locker time */
    XGetScreenSaver(dpy, &timeout, &interval, &prefer, &allow);
    if (timeout > 0 && (!best || timeout * 1000LL < best)) best = timeout * 1000LL;
    if (!best) return NEVER_MS;
    return best > 30000 ? best - 10000 : best;                 /* a head start: off before it blanks or locks */
}

static XSyncValue value_of(long long ms) {
    XSyncValue v;
    XSyncIntsToValue(&v, (unsigned int)(ms & 0xFFFFFFFF), (int)(ms >> 32));
    return v;
}

/* arm: wait for "idle for ms" (positive) or for "activity" (the counter dropping below 1 ms) */
static void arm(int want_idle, long long ms) {
    XSyncAlarmAttributes a;
    unsigned long flags = XSyncCACounter | XSyncCAValueType | XSyncCATestType | XSyncCAValue | XSyncCADelta | XSyncCAEvents;
    a.trigger.counter = idle_counter;
    a.trigger.value_type = XSyncAbsolute;
    a.trigger.test_type = want_idle ? XSyncPositiveTransition : XSyncNegativeTransition;
    a.trigger.wait_value = value_of(want_idle ? ms : 1);
    XSyncIntToValue(&a.delta, 0);
    a.events = True;
    if (alarm_id == None) alarm_id = XSyncCreateAlarm(dpy, flags, &a);
    else XSyncChangeAlarm(dpy, alarm_id, flags, &a);
    XFlush(dpy);
}

int main(void) {
    dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "idle-watch: cannot open display\n"); return 1; }
    int err, major, minor;
    if (!XSyncQueryExtension(dpy, &sync_event_base, &err) || !XSyncInitialize(dpy, &major, &minor)) {
        fprintf(stderr, "idle-watch: no XSync extension\n");
        return 1;
    }
    int n;
    XSyncSystemCounter *counters = XSyncListSystemCounters(dpy, &n);
    for (int i = 0; counters && i < n; i++)
        if (!strcmp(counters[i].name, "IDLETIME")) idle_counter = counters[i].counter;
    if (counters) XSyncFreeSystemCounterList(counters);
    if (idle_counter == None) { fprintf(stderr, "idle-watch: no idle counter\n"); return 1; }

    int waiting_for_idle = 1;
    arm(1, idle_threshold_ms());
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (;;) {
        XEvent e;
        XNextEvent(dpy, &e);                       /* sleeps here until the X server has something to say */
        if (e.type != sync_event_base + XSyncAlarmNotify) continue;
        XSyncAlarmNotifyEvent *ev = (XSyncAlarmNotifyEvent *)&e;
        if (ev->alarm != alarm_id || ev->state != XSyncAlarmActive) continue;
        if (waiting_for_idle) {                    /* the idle time has come */
            printf("idle\n");
            waiting_for_idle = 0;
            arm(0, 0);                             /* now wait for the next activity */
        } else {                                   /* you are back */
            printf("active\n");
            waiting_for_idle = 1;
            arm(1, idle_threshold_ms());           /* the screen's timer may have changed: read it again */
        }
    }
}
