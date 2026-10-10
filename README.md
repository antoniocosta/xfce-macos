# Linux Utilities

Make **Linux Mint Xfce** feel like **macOS**, with as little CPU and memory as possible: every part is
built with performance and a low footprint in mind (see [Light by design](#macos-xfce)). It's
for old Macs and low-end laptops, where macOS no longer updates or a heavy desktop no longer
fits. The goal is that someone coming from a Mac doesn't have to relearn anything: the same
shortcuts, gestures, menu bar, dock, Mission Control, hot corners, and settings with the same
names, where a Mac user would look for them.

`macos-xfce/` is the core: one installer sets up everything macOS does. Each part lives in
its own folder inside it and can also be installed alone. `extras/` holds things macOS
doesn't do out of the box.

```
macos-xfce/          the core: ./macos-xfce/install.sh sets up all of it
  hotcorner/         ├ hot corners
  desktop-slide/     ├ the slide between desktops
  volume-feedback/   ├ the volume click
  disk-label/        ├ "Macintosh HD" with free space on the desktop
  auto-brightness/   ├ automatic screen and keyboard brightness
  ssh-keyring/       ├ SSH key unlocked at login, like the Keychain
  fullscreen/        ├ full screen: green button, its own Space, menu bar at the top edge
  mission-control/   └ Mission Control: the Spaces bar on top, the current desktop's windows below
extras/
  net-badge/         network latency in the menu bar
lib/common.sh        helpers shared by the installers
```

| Part | What it does |
|---|---|
| [macos-xfce](#macos-xfce) | The macOS look and feel for Mint Xfce: Cmd-key shortcuts, menu bar with a global menu, dock, Spotlight, Launchpad, Mission Control, Spaces with the slide, Cmd+Tab, screenshots, macOS cursors, and the parts below. |
| [hotcorner](#hotcorner) | Hot corners: top right shows the desktop, bottom right opens Mission Control. A tiny C program. |
| [desktop-slide](#desktop-slide) | The macOS slide when you switch desktops (Spaces) with Ctrl+arrows or a 3-finger swipe. |
| [volume-feedback](#volume-feedback) | The click when you change the volume. |
| [disk-label](#disk-label) | A "Macintosh HD / 91 GB free" icon on the desktop, with live free space. |
| [auto-brightness](#auto-brightness) | Screen and keyboard backlight follow the room light, like a MacBook (needs its light sensor). |
| [mission-control](#mission-control) | Mission Control: every desktop in a Spaces bar on top, the current desktop's windows below; drag windows between desktops, + and × to add and remove desktops. |
| [fullscreen](#fullscreen) | Full screen like macOS: the green button and Cmd+Ctrl+F go full screen in a Space of its own; at the top edge the menu bar and title bar slide in. |
| [ssh-keyring](#ssh-keyring) | Unlocks your SSH key at login from the login keyring, like the macOS Keychain (only when you have a key). |
| **Extras** | |
| [net-badge](#net-badge) | Network latency in the menu bar ("● 24 ms"), with a popover. |

Tested on Linux Mint 22.3 Xfce (X11) on a MacBook Air mid 2012 (Intel HD 4000, 8 GB).
Nothing is tied to that machine: Mac-only parts (fan control, light sensor, Apple trackpad
thresholds) switch themselves on only where the hardware is there.

## Install

```
git clone https://github.com/antoniocosta/linux-utilities.git
cd linux-utilities
./macos-xfce/install.sh                  # everything (asks for sudo once, for packages)
```

Then **log out and back in** once (the global menu and Toshy need a fresh session).

Options, all off by default:

```
./macos-xfce/install.sh --trim           # also switch off services and remove apps a laptop rarely needs (see Trim)
./macos-xfce/install.sh --english-only   # also remove other languages' translations, help and manuals
./macos-xfce/install.sh --user           # skip packages (already installed): no sudo
```

One part on its own: its `install.sh`, for example `./macos-xfce/hotcorner/install.sh` or
`./extras/net-badge/install.sh`.

Everything is safe to re-run: each step checks before it changes anything. Programs go in
`~/.local/bin`, settings in your Xfce settings and `~/.config`. Where a file is shared with other
tools (`gtk.css`, `~/.xsessionrc`, Firefox's `user.js`, Toshy's config), the change sits in a
block marked `linux-utilities` that a re-run replaces instead of duplicating.

## Footprint

Measured on the 2012 MacBook Air over a 12-hour session (resident memory, average CPU):

| Process | Memory | CPU |
|---|---|---|
| hotcorner | 3 MB | 0.01 % |
| fullscreen | 9 MB | 0 (sleeps until a window changes; watches the pointer only in full screen) |
| volume-feedback | 11 MB | 0 (sleeps until the volume changes) |
| disk-label | 4 MB | 0 (checks once a minute) |
| mission-control (waiting) | 2 MB own, 7 MB with shared | 0 (wakes only on a desktop switch) |
| Touchégg client | 15 MB | 0 |
| Plank (dock) | 57 MB | 0 |
| picom (desktop slide; replaces Xfce's compositor) | 79 MB | 0.3 % |

picom under a redraw load: Xfce's own compositor 7.8 % CPU, picom with vsync 13.9 %, picom
without vsync 9.9 % (used; no visible tearing). `desktop-slide off` goes back to Xfce's
compositor.

---

## macos-xfce

**Light by design.** Everything here is chosen for performance and a small footprint first,
so it runs well on a 2012 MacBook Air with 2 cores and the oldest Intel graphics that still work.
The rules every part follows:

- **Xfce's own features first.** Desktops, window dragging across them, the Cmd+Tab switcher,
  notifications and the menu bar are Xfce's, only configured. Nothing replaces the window manager
  or the panel.
- **No resident process unless it must be one.** Helpers are a few lines of shell, Python or C
  and sleep until something happens: volume-feedback waits on audio events, net-badge runs from
  the panel's timer, settings dialogs only exist while open.
- **When something must poll, it polls cheaply.** hotcorner asks X for the pointer position
  5 times a second and speeds up only near a corner (3 MB, about 0.01 % CPU).
- **The heaviest part is optional.** The desktop slide needs a compositor (picom, 0.3 % CPU on
  average); `desktop-slide off` goes back to Xfce's own.
- **Less running in the background.** `--trim` switches off services a laptop rarely needs (about
  350 MB of RAM back on the test machine); Firefox gets fewer processes and unloads idle tabs.
- **Measured, not assumed.** Every part's memory and CPU are checked on the test machine after
  each change; see [Footprint](#footprint).

| macOS | Here | How |
|---|---|---|
| Cmd-key shortcuts (Cmd+C/V/T/W/Q…, Cmd+C/V in terminals; Ctrl+C still interrupts) | same | [Toshy](https://github.com/RedBearAK/toshy), plus keymaps in its `user_apps` slice (`toshy-keymaps.py`) |
| Cmd+Tab | app icons from every desktop, dark rounded panel | Xfce's switcher, styled in `files/gtk3-overrides.css` |
| Ctrl+Tab / Ctrl+Shift+Tab | next / previous tab | Toshy keymap |
| Ctrl+← / Ctrl+→ | previous / next desktop, with the slide | `desktop-switch` ([desktop-slide](#desktop-slide)) |
| green button, Cmd+Ctrl+F | full screen in its own Space; menu bar and title bar at the top edge | [fullscreen](#fullscreen) |
| Ctrl+↑, F3, 3-finger swipe up, bottom-right corner | Mission Control: the Spaces bar on top, the current desktop's windows below | [mission-control](#mission-control) |
| F4 | Launchpad: full-screen app grid, type to filter | rofi, `files/.config/rofi/launchpad.rasi` |
| Cmd+Space | Spotlight-style app search | rofi, `files/.config/rofi/config.rasi` |
| Cmd+Shift+3 / 4 / 5 | full screen / area / tool, saved to `~/Pictures/Screenshots` | xfce4-screenshooter |
| 3-finger swipe left / right / up / down, spread thumb and three fingers | previous / next desktop, Mission Control open / closed, show desktop | Touchégg, `files/.config/touchegg/touchegg.conf`; its client runs under `touchegg-client`, which restarts it if it crashes |
| Spaces | 4 desktops; drag a window against the left/right screen edge to carry it over | Xfce's window manager (`wrap_windows`) |
| a window asking for attention | takes you to its desktop (Xfce's default pulls it to yours) | Xfce `activate_action = switch` |
| menu bar | menu · app menu (global menu) ··· status icons · volume · battery · notifications · clock | xfce4-panel + `xfce4-appmenu-plugin` |
| Dock | Plank Reloaded: WhiteSur theme, magnification, auto-hide; Finder (Files), Launchpad, Firefox, App Store (Software Manager), System Settings, Downloads, Trash | `files/plank-dock1.dconf`; a dock you already arranged keeps its items |
| look | WhiteSur dark window theme, Inter font, macOS cursors, Mint's app icons with a horizontal macOS battery, dark mode for Firefox and GTK4 apps too | `setup_theme` |
| window buttons | close / minimize / maximize on the left, centred title | Xfce window manager |
| desktop | "Macintosh HD / 91 GB free", USB drives and servers in a column at the top right | xfdesktop + [disk-label](#disk-label) |
| Firefox | trackpad scrolling slowed to macOS speed, leaner (4 content processes, tabs unloaded when memory runs low, no telemetry or sponsored content; site isolation kept), hardware video decoding where the GPU has it | Firefox `user.js` |

Also: notifications at the top right, without Wi-Fi "connected" pop-ups; menu bar status icons in
a fixed order and one battery icon; window buttons on the left in apps that draw their own title
bar too (Firefox, GTK4); `mbpfan` (fan control) and the Broadcom Wi-Fi driver on Macs, `tlp`
(battery life) on laptops, zram (compressed swap in RAM), the VA-API `i965` driver on older Intel
GPUs, and the Update Manager shield shown only when there are updates.

### Trim (`--trim`)

Background services and preinstalled apps that a typical laptop doesn't need. About 350 MB
of RAM and 1.5 GB of disk on the test machine.

| What | Why | Undo |
|---|---|---|
| printing (`cups`, `cups-browsed`) | cups-browsed keeps scanning the network | `sudo systemctl enable --now cups cups-browsed` |
| `kerneloops`, `motd-news` | crash reports, login news | `sudo systemctl enable --now kerneloops motd-news.timer` |
| `ModemManager` | no mobile modem | `sudo systemctl unmask ModemManager` |
| `colord` + `xiccd` | no colour profiles | `sudo systemctl unmask colord` |
| `rsyslog` | journald already keeps every log | `sudo systemctl unmask rsyslog syslog.socket` |
| `fwupd`, `boltd` (Macs only) | Apple ships no firmware through fwupd; no boltd needed for Thunderbolt 1/2 | `sudo systemctl unmask fwupd bolt` |
| `switcheroo-control` (one GPU), `iio-sensor-proxy` (no rotation sensor) | nothing to switch or rotate | `sudo systemctl unmask …` |
| LibreOffice, Thunderbird, GNOME Calendar, Yaru icons, Mint-L theme | rarely used / unused | reinstall from Software Manager |
| calendar and contacts services, reminder popups, GNOME Online Accounts | only GNOME Calendar used them | `systemctl --user unmask evolution-source-registry evolution-calendar-factory evolution-addressbook-factory` |
| tray icons: printer, System Reports, Toshy | printing is off; System Reports polls constantly (it's still in the menu); the keys work without Toshy's icon | delete their files in `~/.config/autostart/` |
| PackageKit's debconf helper | can busy-loop at 100 % CPU for a minute after login; Mint's tools don't need it | `systemctl --user unmask pk-debconf-helper.socket pk-debconf-helper.service` |

Kept on purpose: the previous kernel, Chinese/Japanese/Korean fonts (otherwise such text shows
as boxes), Bluetooth, `avahi`, `thermald`, Thunar's daemon.

### English only (`--english-only`)

Removes other languages' app translations, help pages and manuals, and adds
`/etc/dpkg/dpkg.cfg.d/90-english-only` so updates keep it that way. Region formats (dates,
numbers) are not affected. Undo: delete that file and reinstall a package to get its
translations back.

### Gotchas

- Toshy turns the physical **Ctrl key into Super in GUI apps** (it stays Ctrl in terminals), so
  Ctrl shortcuts are bound as `<Super>…`.
- The global menu loads through `GTK_MODULES` at login. Switching it on live crashes running tray
  apps, so it only appears after logging in again.
- A Toshy reinstall brings its rainbow tray icon back; re-run the installer.

### Undo

- Theme, menu bar, shortcuts: Settings → Appearance / Window Manager / Panel / Keyboard.
- Desktop slide: `desktop-slide off`.
- Helpers: delete their entries in `~/.config/autostart/` and log out.
- Marked blocks: delete the `linux-utilities` blocks from `~/.config/gtk-3.0/gtk.css`,
  `~/.xsessionrc`, the Firefox profile's `user.js` and `~/.config/toshy/toshy_config.py`.

---

## hotcorner

Move the pointer into a corner and rest it there for a moment: top right shows the desktop (do
it again to bring the windows back), bottom right opens Mission Control. It doesn't fire while a
mouse button is held, so dragging a window into a corner does nothing.

`hotcorner.c` asks X where the pointer is 5 times a second, and 50 times a second only while the
pointer is near a corner, so it reacts quickly and still uses almost nothing. Polling, rather
than an invisible window in the corner, keeps it working when the dock or a full-screen window
covers the corner. `hot-corners` starts it with the corners and restarts it if it ever stops.

---

## desktop-slide

Xfce switches desktops instantly. macOS slides the old desktop out and the new one in, in the
direction you swiped. Xfce's compositor can't animate, and Mint's picom (v10) can only fade, so
this builds picom v13 from source, which has animations. picom knows nothing about desktops or
directions, so `desktop-switch` marks the windows that leave and arrive with
`_MAC_SLIDE = fwd/back` just before switching, and picom's rules (`picom.conf`) slide them by a
screen width in 0.35 s. Switches from Cmd+Tab or Mission Control stay instant, as on macOS.

```
desktop-slide on | off | status    # off: back to Xfce's own compositor
desktop-switch next | prev         # what Ctrl+arrows and the swipes run
```

---

## volume-feedback

Plays the freedesktop volume click whenever the output volume changes, like macOS. It listens to
`pactl subscribe`, so it sleeps until something happens. Silent while muted; quick repeats
restart the click instead of piling up.

---

## disk-label

Xfce's desktop can't show free space under the File System icon, so this keeps a launcher on the
desktop named "Macintosh HD" with the free space underneath (decimal gigabytes, like macOS). It
opens `/` in the file manager, checks once a minute, and only rewrites the launcher when the
number changes.

---

## auto-brightness

MacBooks have an ambient light sensor that Linux exposes but nothing uses. This reads it every
2 seconds, smooths it, and moves the screen backlight along a curve, one step at a time; the
keyboard backlight fades on in the dark and off in bright light. When you change the brightness
yourself, it keeps that offset, like macOS. Brightness is set through logind, so no root is
needed. Turn screen or keyboard on and off in Settings Manager → **Auto Brightness**.

Installs only where there is a light sensor.

---

## mission-control

macOS Mission Control. The **Spaces bar** across the top shows every desktop, with a full-screen
app's Space named after the app; below it, the **current desktop's windows**, side by side, with
their icons (and the title of the one under the pointer).

- Click a window to go to it; click a desktop to switch to it; Esc, F3, Ctrl+↑, a 3-finger swipe
  down or a click on empty space closes it.
- Drag a window onto a desktop to move it there, or onto **+** to give it a desktop of its own.
- **+** adds a desktop; the **×** on a hovered desktop removes it (its windows move to the
  neighbouring desktop; on a full-screen Space it leaves full screen).

How it stays light: one small C program that sleeps in the background (about 2 MB of its own).
X keeps no picture of hidden desktops, so when you arrive on a desktop (an event from the window
manager, no timer) it waits for the slide to finish and takes one small snapshot: that's the
desktop's picture in the Spaces bar. A desktop without one yet shows its windows' outlines and
icons. While open, the windows are drawn from their own composited images, so they're live.

```
mission-control              toggle (F3, Ctrl+↑, the bottom-right corner)
mission-control --open       open (3-finger swipe up)   --close: close (swipe down)
```

---

## fullscreen

macOS full screen, for every app:

- **The green button goes full screen** instead of maximizing, for Xfce's title bars and for apps
  that draw their own (Firefox). **Cmd+Ctrl+F** toggles it too, and apps' own full screen (F11,
  a video's full-screen button) behaves the same.
- **Its own Space.** The window moves to a new desktop right after its own, and the screen slides
  to it; Ctrl+arrows, the swipes and Mission Control reach it like any desktop. Leaving full
  screen (or closing the window) slides back to the window's own desktop and removes the Space.
- **The top edge.** Rest the pointer at the top: the menu bar slides in, with the app's own
  menus, and the window's title bar below it. Red closes the window, green leaves full screen,
  yellow is greyed out (as on macOS). Move away and they hide again; an open menu keeps them.

How it stays light: one small C program that sleeps until a window changes. Clicks come in as
XInput2 raw events (no grab, nothing taken from other apps); a click in a window's button area
followed by that window's maximize state changing is the green button. The pointer is only
watched while the active window is full screen. Inserting the Space moves the later desktops up
one (and back when it goes), but never while a mouse button is held: renumbering desktops under
a window that's being dragged is what breaks things. Each window keeps its own desktop number
on itself, so a restart of the program never strands it.

Xfce keeps a focused full-screen window above the panel, so while the title bar shows, it takes
the focus (carrying the app's menu properties, so the global menu stays the app's); the window
is alone on its Space, so nothing else comes up in between.

`fullscreen -G` leaves the green button alone, `-P` turns off the top edge, `-S` keeps
full-screen windows on their own desktop (no Spaces).

---

## ssh-keyring

On macOS the Keychain unlocks your SSH key when you log in. This does the same with the login
keyring: the passphrase is stored there once, and at login `ssh-keyring unlock` adds the key to
the session's ssh-agent. The key file stays encrypted on disk, and the passphrase never appears
on a command line.

```
./macos-xfce/ssh-keyring/install.sh [KEY]   # default ~/.ssh/id_ed25519
ssh-keyring store                  # once: type the passphrase; it's checked, then saved
ssh-keyring forget                 # remove it from the keyring
```

---

# Extras

## net-badge

A coloured dot and the current latency in the menu bar, measured every 5 seconds as one TCP
handshake to Apple's captive-portal server. Colours follow
[Network Badge](https://github.com/Someniak/macos-network-badge)'s tiers (< 30 / 80 / 150 /
300 ms). The tooltip and a click popover show the connection, Wi-Fi name, a sparkline of the
last 3 minutes and min/avg/max; a notification appears when the connection turns poor. Runs in
Xfce's Generic Monitor plugin, so there's no extra process between measurements.

---

## License

MIT, see [LICENSE](LICENSE). The projects the installers download keep their own licences:
see [THIRD_PARTY.md](THIRD_PARTY.md).
