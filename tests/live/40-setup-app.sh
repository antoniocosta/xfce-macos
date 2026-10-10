# setup app: the real window driving a fake installer (sourced by live.sh)

t_begin "setup app: runs the installer, streams its output, reports success or failure"
SETUP="$ROOT/macos-xfce/setup-app"
cat > "$LIVE_TMP/fake-ok.sh" <<'FAKE'
#!/bin/bash
printf '\033[1;34m[INFO]\033[0m starting %s\n' "$*"
sleep 0.3
printf '\033[1;32m[OK]\033[0m   all done\n'
FAKE
cat > "$LIVE_TMP/fake-bad.sh" <<'FAKE'
#!/bin/bash
echo "something broke"
exit 3
FAKE
cat > "$LIVE_TMP/drive.py" <<'PY'
import os, sys
sys.path.insert(0, os.environ["SETUP"])
import importlib.machinery, importlib.util
loader = importlib.machinery.SourceFileLoader("app", os.path.join(os.environ["SETUP"], "xfce-macos-setup"))
spec = importlib.util.spec_from_loader("app", loader); app = importlib.util.module_from_spec(spec); loader.exec_module(app)
import setup_core as core
s = app.Setup(); s.win.show_all()
from gi.repository import GLib, Gtk
s.finished = False
s.run(core.restore_commands(dry_run=True), "Previewing", done="Preview shown. Nothing was changed.")
GLib.timeout_add(8000, Gtk.main_quit)          # safety stop
def poll():
    if s.finished: Gtk.main_quit(); return False
    return True
GLib.timeout_add(100, poll)
Gtk.main()
text = s.buf.get_text(s.buf.get_start_iter(), s.buf.get_end_iter(), False)
print("STATUS=" + s.status.get_text()); print("FAILED=" + str(s.failed))
print("HAS_OK=" + str("[OK]   all done" in text)); print("NO_ANSI=" + str("\x1b" not in text))
print("SHOWS_COMMAND=" + str("--restore --dry-run" in text)); print("EXIT3=" + str("[exit status 3]" in text))
PY
out=$(SETUP="$SETUP" LU_SETUP_INSTALLER="$LIVE_TMP/fake-ok.sh" timeout 20 python3 "$LIVE_TMP/drive.py" 2>/dev/null)
eq "finishes and says so"                 "$(sed -n 's/^STATUS=//p' <<<"$out")" "Preview shown. Nothing was changed."
eq "not marked as failed"                 "$(sed -n 's/^FAILED=//p' <<<"$out")" False
eq "the installer's output arrives"       "$(sed -n 's/^HAS_OK=//p' <<<"$out")" True
eq "colour codes are stripped"            "$(sed -n 's/^NO_ANSI=//p' <<<"$out")" True
eq "the command that ran is shown"        "$(sed -n 's/^SHOWS_COMMAND=//p' <<<"$out")" True
out=$(SETUP="$SETUP" LU_SETUP_INSTALLER="$LIVE_TMP/fake-bad.sh" timeout 20 python3 "$LIVE_TMP/drive.py" 2>/dev/null)
eq "a failing installer is reported"      "$(sed -n 's/^FAILED=//p' <<<"$out")" True
eq "with its exit status"                 "$(sed -n 's/^EXIT3=//p' <<<"$out")" True
check "and the status line points to the log" bash -c "[[ '$(sed -n 's/^STATUS=//p' <<<"$out")' == *'went wrong'* ]]"
