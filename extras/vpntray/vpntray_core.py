"""vpntray core: parsing of the VPN command-line tool's output and a small provider adapter.

No GUI imports here, so it can be unit-tested without a display. Unofficial; not affiliated
with any VPN provider.
"""
import os
import re
import subprocess
from dataclasses import dataclass, field

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def strip_ansi(text):
    return ANSI_RE.sub("", text or "")


@dataclass
class Status:
    connected: bool = False
    location: str = ""
    raw: str = ""


@dataclass
class Account:
    logged_in: bool = False
    email: str = ""
    plan: str = ""
    valid_until: str = ""


@dataclass
class Location:
    iso: str
    country: str
    city: str
    ping: int = -1  # milliseconds; -1 when unknown

    @property
    def flag(self):
        """Flag emoji from the two-letter ISO code (empty if it is not one)."""
        iso = self.iso.upper()
        if len(iso) != 2 or not iso.isalpha():
            return ""
        return "".join(chr(0x1F1E6 + ord(c) - ord("A")) for c in iso)


@dataclass
class Result:
    ok: bool
    out: str = ""
    err: str = ""

    @property
    def message(self):
        """First useful line of output, for showing inline."""
        text = (self.err or self.out).strip()
        lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
        return lines[0] if lines else ""


def parse_status(text):
    """Defensive: only 'disconnected' / 'connected' are known to exist."""
    clean = strip_ansi(text).strip()
    low = clean.lower()
    if not clean or "disconnected" in low or "not connected" in low:
        return Status(False, "", clean)
    if "connected" not in low:
        return Status(False, "", clean)
    loc = ""
    m = re.search(r"connected to\s+(.+?)(?:\s+in\s+\w+\s+mode|,?\s+running on\b.*|\s*$)",
                  clean, re.IGNORECASE | re.MULTILINE)
    if m:
        loc = m.group(1).strip().rstrip(".,")
    else:
        m = re.search(r"^\s*location\s*:\s*(.+)$", clean, re.IGNORECASE | re.MULTILINE)
        if m:
            loc = m.group(1).strip()
    return Status(True, loc, clean)


def parse_license(text):
    clean = strip_ansi(text)
    m = re.search(r"Logged in as\s+(\S+)", clean)
    if not m:
        return Account(False)
    plan = ""
    p = re.search(r"using the\s+(.+?)\s+version", clean, re.IGNORECASE)
    if p:
        plan = p.group(1).strip().title()
    v = re.search(r"valid until\s+(\S+)", clean, re.IGNORECASE)
    return Account(True, m.group(1).strip().rstrip(".,"), plan, v.group(1) if v else "")


def parse_locations(text):
    """Table 'ISO COUNTRY CITY PING ESTIMATE' (sorted by ping by the tool)."""
    lines = strip_ansi(text).splitlines()
    cols = None
    out = []
    for line in lines:
        if cols is None and "ISO" in line and "COUNTRY" in line and "CITY" in line:
            cols = (line.index("COUNTRY"), line.index("CITY"),
                    line.index("PING") if "PING" in line else len(line))
            continue
        if not re.match(r"^[A-Z]{2}\s", line):
            continue
        iso = line[:2]
        fields = None
        if cols:
            a, b, c = cols
            country, city, ping = line[a:b].strip(), line[b:c].strip(), line[c:].strip()
            # sliced columns are only trusted when they fit the row's visible gaps
            if country and city and re.match(r"^\d+", ping) and line[a - 1:a].isspace() \
                    and line[b - 1:b].isspace():
                fields = (country, city, ping)
        if fields is None:
            parts = re.split(r"\s{2,}", line.strip())
            if len(parts) < 3:
                continue
            fields = (parts[1], parts[2], parts[3] if len(parts) > 3 else "")
        pm = re.match(r"\d+", fields[2])
        out.append(Location(iso, fields[0], fields[1], int(pm.group()) if pm else -1))
    return out


class AdGuard:
    """Adapter for the AdGuard VPN command-line tool (unofficial)."""

    name = "AdGuard VPN"

    def __init__(self, cmd="adguardvpn-cli", askpass=None):
        self.cmd = cmd
        self.askpass = askpass

    def run(self, args, stdin=None, timeout=20):
        env = dict(os.environ, NO_COLOR="1")
        if self.askpass:
            env["SUDO_ASKPASS"] = self.askpass
        try:
            p = subprocess.run([self.cmd, *args], input=stdin, capture_output=True, text=True,
                               timeout=timeout, env=env, start_new_session=True,
                               stdin=None if stdin is not None else subprocess.DEVNULL)
        except FileNotFoundError:
            return Result(False, "", f"'{self.cmd}' was not found")
        except subprocess.TimeoutExpired:
            return Result(False, "", "The command timed out")
        return Result(p.returncode == 0, strip_ansi(p.stdout), strip_ansi(p.stderr))

    def status(self):
        r = self.run(["status"])
        return parse_status(r.out) if r.ok or r.out else Status(False, "", r.message)

    def account(self):
        return parse_license(self.run(["license"]).out)

    def locations(self):
        return parse_locations(self.run(["list-locations", "500"], timeout=30).out)

    def connect(self, location=None):
        args = ["connect", "-y"] + (["-l", location] if location else ["-f"])
        return self.run(args, timeout=90)

    def disconnect(self):
        return self.run(["disconnect"], timeout=30)

    def login(self, email, password):
        """The password goes to the tool's stdin only; nothing is stored here."""
        return self.run(["login"], stdin=f"{email}\n{password}\n", timeout=30)

    def logout(self):
        return self.run(["logout"])
