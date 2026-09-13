#!/usr/bin/env python3
"""Measure what holding the right arrow key actually does on each supported site.

TriBoost does not control playback speed. It holds down the right arrow key and
relies on the site's own player to interpret that as "speed up". That makes every
entry in SiteMatcher.verifiedDomains a claim about someone else's code, and those
claims expire without notice: Tencent Video rewrote its player and the same held
key started seeking instead.

This script re-checks every claim. For each site it holds the key two different
ways and reports what the video did:

  single  one key-down, then nothing until key-up
  repeat  one key-down, then synthetic auto-repeat, the way real hardware behaves

The two modes matter because they fail differently. A player that times a single
press is happy with `single`. A player that counts auto-repeats — Tencent — sees
nothing at all in `single` mode and reads the release as a tap, which on that site
means seek. `single` failing while `repeat` works is precisely the regression that
cost a long afternoon to find by hand, so it is called out by name in the summary.

Keys are injected through the DevTools protocol rather than the OS, so no window
needs focus and your own browsing is never touched. What is measured is the page's
reaction, which is the part that varies between sites.

Usage:
    ./Scripts/verify-sites.py                 # every site, both modes
    ./Scripts/verify-sites.py --site 腾讯视频   # just one
    ./Scripts/verify-sites.py --use-login     # copy cookies past ads and paywalls
    ./Scripts/verify-sites.py --keep-open     # leave the browser up to look at

Exit status is non-zero when a built-in site no longer behaves as expected, so
this can run in CI.

Only standard library: a test tool that needs its own install ritual is a test
tool nobody runs.
"""

import argparse
import base64
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


# --------------------------------------------------------------------------
# What we expect, and where to look
# --------------------------------------------------------------------------

# `clock` is for players with no readable <video> element. Tencent's current
# player decodes in WASM and draws through cocos; the only honest reading of its
# position is the timestamp it prints in its own control bar.
SITES = [
    {
        "name": "B站",
        "domain": "bilibili.com",
        "url": "https://www.bilibili.com/video/BV1ciYp6XEpW",
        "expect": 3.0,
    },
    {
        "name": "爱奇艺",
        "domain": "iqiyi.com",
        "url": "https://www.iqiyi.com/v_257knoc22e8.html",
        "expect": 2.0,
        "note": "pre-roll ads unless --use-login",
    },
    {
        "name": "优酷",
        "domain": "youku.com",
        "url": "https://v.youku.com/v_show/id_XNjU2MDI1ODQxMg==",
        "expect": 3.0,
        "note": "may show a slider captcha; reported as BLOCKED, not as a failure",
    },
    {
        "name": "腾讯视频",
        "domain": "v.qq.com",
        "url": "https://v.qq.com/x/cover/mzc002000iis17y.html",
        "expect": 3.0,
        "clock": ".txp_time_current",
        "wait": 18,
        "note": "WASM player: measured from the control bar clock, not <video>",
    },
]

# Sites deliberately excluded, re-checked so that "we tested it once" does not
# quietly become "we tested it in 2026 and never again".
REJECTED = [
    {"name": "YouTube", "domain": "youtube.com",
     "url": "https://www.youtube.com/watch?v=aqz-KE-bpKQ", "expect": None},
    {"name": "芒果TV", "domain": "mgtv.com",
     "url": "https://www.mgtv.com/b/900162/24594067.html", "expect": None},
]


# --------------------------------------------------------------------------
# Minimal WebSocket client (RFC 6455, client side, text frames)
# --------------------------------------------------------------------------

class WebSocket:
    """Just enough of the protocol to talk to Chrome: connect, send text, read
    text, answer pings. Written out rather than pulled from PyPI so this script
    runs on a clean machine with nothing installed."""

    def __init__(self, url, timeout=30):
        m = re.match(r"ws://([^:/]+):(\d+)(/.*)", url)
        if not m:
            raise ValueError(f"not a ws:// url: {url}")
        host, port, path = m.group(1), int(m.group(2)), m.group(3)

        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ).encode())

        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("server closed during handshake")
            head += chunk
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise ConnectionError(f"handshake refused: {head.split(chr(13).encode())[0]!r}")
        self._buf = head.split(b"\r\n\r\n", 1)[1]

    def _read(self, n):
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def send(self, text, opcode=0x1):
        payload = text.encode() if isinstance(text, str) else text
        header = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        self.sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def recv(self):
        """Returns the next complete text message, transparently reassembling
        fragments and answering pings."""
        data = b""
        opcode = None
        while True:
            b0, b1 = self._read(2)
            fin, op = b0 & 0x80, b0 & 0x0F
            masked, n = b1 & 0x80, b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if masked else None
            payload = self._read(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

            if op == 0x9:                       # ping -> pong, keep going
                self.send(payload, opcode=0xA)
                continue
            if op == 0xA:                       # pong, ignore
                continue
            if op == 0x8:                       # close
                raise ConnectionError("server closed the socket")

            if op != 0x0:
                opcode = op
            data += payload
            if fin:
                return data.decode("utf-8", "replace") if opcode == 0x1 else data

    def close(self):
        try:
            self.send(b"", opcode=0x8)
            self.sock.close()
        except Exception:
            pass


# --------------------------------------------------------------------------
# Chrome + DevTools protocol
# --------------------------------------------------------------------------

class Chrome:
    """A throwaway Chrome with a debugging port, driven over CDP."""

    def __init__(self, port, use_login, keep_open):
        self.port = port
        self.keep_open = keep_open
        self.profile = tempfile.mkdtemp(prefix="triboost-verify-")
        self.proc = None
        if use_login:
            self._copy_cookies()
        self._launch()
        self.ws = WebSocket(self._page_target())
        self._id = 0

    # -- lifecycle --------------------------------------------------------

    def _copy_cookies(self):
        """Reuse the signed-in session so ads and paywalls do not masquerade as
        "the site stopped working". sqlite3's online backup reads the database
        while Chrome holds it, so nothing has to be quit.

        The copy contains real credentials. It lives in a temp directory and is
        deleted on exit unless --keep-open was passed."""
        src = os.path.expanduser("~/Library/Application Support/Google/Chrome")
        dst = os.path.join(self.profile, "Default")
        os.makedirs(dst, exist_ok=True)
        try:
            subprocess.run(
                ["sqlite3", os.path.join(src, "Default", "Cookies"),
                 f".backup '{os.path.join(dst, 'Cookies')}'"],
                check=True, capture_output=True, timeout=60)
            shutil.copy(os.path.join(src, "Local State"),
                        os.path.join(self.profile, "Local State"))
            print("  (signed-in session copied; deleted when this run ends)")
        except Exception as e:
            print(f"  !! could not copy the session ({e}); continuing signed out")

    def _launch(self):
        self.proc = subprocess.Popen(
            [CHROME, f"--user-data-dir={self.profile}",
             f"--remote-debugging-port={self.port}",
             "--no-first-run", "--no-default-browser-check",
             "--autoplay-policy=no-user-gesture-required",
             "--window-size=1440,900", "about:blank"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(40):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{self.port}/json/version", timeout=2)
                return
            except Exception:
                time.sleep(0.5)
        raise RuntimeError(f"Chrome never opened the debugging port {self.port}")

    def _page_target(self):
        tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{self.port}/json"))
        page = next(t for t in tabs if t["type"] == "page")
        return page["webSocketDebuggerUrl"]

    def shutdown(self):
        try:
            self.ws.close()
        except Exception:
            pass
        if self.keep_open:
            print(f"\nBrowser left open on port {self.port}.")
            print(f"Profile (may hold session cookies): {self.profile}")
            return
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        shutil.rmtree(self.profile, ignore_errors=True)

    # -- protocol ---------------------------------------------------------

    def send(self, method, **params):
        self._id += 1
        self.ws.send(json.dumps({"id": self._id, "method": method, "params": params}))
        deadline = time.time() + 30
        while time.time() < deadline:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self._id:
                if "error" in msg:
                    raise RuntimeError(msg["error"])
                return msg.get("result", {})
        raise TimeoutError(method)

    def js(self, expr):
        r = self.send("Runtime.evaluate", expression=expr,
                      returnByValue=True, awaitPromise=True)
        if "exceptionDetails" in r:
            return None
        return r.get("result", {}).get("value")

    def goto(self, url, wait=10):
        self.send("Page.enable")
        self.send("Page.navigate", url=url)
        time.sleep(wait)

    KEY = dict(key="ArrowRight", code="ArrowRight",
               windowsVirtualKeyCode=39, nativeVirtualKeyCode=39)

    def key_down(self, autorepeat=False):
        self.send("Input.dispatchKeyEvent", type="rawKeyDown",
                  autoRepeat=autorepeat, **self.KEY)

    def key_up(self):
        self.send("Input.dispatchKeyEvent", type="keyUp", **self.KEY)


# --------------------------------------------------------------------------
# Page-side helpers
# --------------------------------------------------------------------------

# Prefer a media element that looks like the feature rather than a pre-roll ad,
# then the biggest one, which is the player on every site checked.
PICK_VIDEO = """
(() => {
  const all = [...document.querySelectorAll('video')];
  const feature = all.filter(v => v.duration > 90);
  const pool = feature.length ? feature : all;
  window.__tb = pool.sort((a,b) =>
      (b.clientWidth*b.clientHeight) - (a.clientWidth*a.clientHeight))[0] || null;
  if (!window.__tb) return null;
  window.__tb.muted = true;
  if (window.__tb.paused) { const p = window.__tb.play(); if (p && p.catch) p.catch(()=>{}); }
  // Players route their shortcuts through whatever currently has focus. Without
  // this the key arrives at the document and is then ignored, which looks exactly
  // like a site that dropped the feature.
  if (document.activeElement === document.body || !document.activeElement) window.focus();
  document.body.focus();
  return {dur: window.__tb.duration, rate: window.__tb.playbackRate,
          t: window.__tb.currentTime, paused: window.__tb.paused};
})()
"""

SAMPLE_VIDEO = ("(() => { const v = window.__tb; return v ? "
                "{rate: v.playbackRate, t: v.currentTime, paused: v.paused} : null; })()")

# A page that never receives the key would look exactly like a site that ignores
# it. Counting keydowns keeps those two apart.
LISTEN = """
(() => {
  window.__tbKeys = 0;
  if (window.__tbListener) document.removeEventListener('keydown', window.__tbListener, true);
  window.__tbListener = e => { if (e.key === 'ArrowRight') window.__tbKeys++; };
  document.addEventListener('keydown', window.__tbListener, true);
  return true;
})()
"""

BLOCKED_HINTS = ("请验证", "人机验证", "滑块", "captcha", "unusual traffic")


def clock_reader(selector):
    return ("(() => { const e = document.querySelector(%r); if (!e) return null;"
            " const p = e.textContent.trim().split(':').map(Number);"
            " if (p.some(isNaN)) return null;"
            " return p.length === 3 ? p[0]*3600 + p[1]*60 + p[2]"
            "      : p.length === 2 ? p[0]*60 + p[1] : null; })()" % selector)


def page_blocked(chrome):
    text = (chrome.js("document.body ? document.body.innerText.slice(0, 400) : ''") or "").lower()
    return any(h.lower() in text for h in BLOCKED_HINTS)


def settle(chrome, site, timeout=90):
    """Wait until something is actually playing.

    Pre-roll ads are separate media with their own duration, so the duration
    changing means the feature has not started yet. Sites with no <video> are
    judged by their own clock advancing instead."""
    clock = site.get("clock")
    deadline = time.time() + timeout
    last_dur, stable_since = None, time.time()
    play_clicks = 0

    while time.time() < deadline:
        if page_blocked(chrome):
            return "BLOCKED"
        if clock:
            t0 = chrome.js(clock_reader(clock))
            time.sleep(3)
            t1 = chrome.js(clock_reader(clock))
            if t0 is not None and t1 is not None and t1 - t0 >= 2:
                return "OK"
            # The play button is a toggle: pressing it on every pass is how a
            # playing video ends up paused. Two nudges, then let it be.
            if play_clicks < 2:
                chrome.js("(() => { const b = document.querySelector('.txp_btn_play');"
                          " if (b) b.click(); })()")
                play_clicks += 1
                time.sleep(4)
            else:
                time.sleep(3)
            continue

        state = chrome.js(PICK_VIDEO)
        if state and state.get("dur"):
            d = state["dur"]
            if d != last_dur:
                last_dur, stable_since = d, time.time()
            elif not state["paused"] and time.time() - stable_since >= 5:
                return "OK"
        time.sleep(2)

    return "NO_MEDIA" if not clock else "NOT_PLAYING"


def hold(chrome, site, repeat, seconds=4.0):
    """Hold the key one way or the other and describe what the video did."""
    clock = site.get("clock")
    read = (lambda: chrome.js(clock_reader(clock))) if clock else \
           (lambda: (chrome.js(SAMPLE_VIDEO) or {}).get("t"))

    chrome.js(LISTEN)
    # Re-select the media rather than trusting what settle() found: a pre-roll
    # giving way to the feature swaps the element out, and the stale reference
    # then reads as "no media" on a site that is playing perfectly well.
    picked = None if clock else chrome.js(PICK_VIDEO)
    if not clock and not picked:
        return {"verdict": "NO_MEDIA", "keys": 0}
    base_rate = None if clock else (chrome.js(SAMPLE_VIDEO) or {}).get("rate")
    rates = [] if clock else [base_rate]

    t_before = read()
    wall0 = time.time()
    chrome.key_down()
    next_repeat = wall0 + 0.25          # roughly a real keyboard's initial delay
    try:
        while time.time() - wall0 < seconds:
            if repeat and time.time() >= next_repeat:
                chrome.key_down(autorepeat=True)
                next_repeat = time.time() + 0.033
            if not clock:
                s = chrome.js(SAMPLE_VIDEO)
                if s:
                    rates.append(s["rate"])
            time.sleep(0.05 if repeat else 0.25)
    finally:
        chrome.key_up()                 # never leave the key down

    t_during = read()
    wall = time.time() - wall0
    time.sleep(1.2)
    t_after = read()
    keys = chrome.js("window.__tbKeys") or 0

    if t_before is None or t_during is None:
        return {"verdict": "NO_MEDIA", "keys": keys}

    effective = (t_during - t_before) / wall
    jump = (t_after - t_during) if t_after is not None else 0
    peak = max(rates) if rates and None not in rates else None

    # A rise in playbackRate is the direct evidence. Without a readable element,
    # the clock outrunning the wall clock says the same thing.
    if peak is not None and base_rate is not None and peak > base_rate + 0.05:
        verdict = "SPEED"
    elif peak is None and effective > 1.5:
        verdict = "SPEED"
    elif effective > 2.5 or jump > 2.5:
        verdict = "SEEK"
    else:
        verdict = "NONE"

    return {"verdict": verdict, "rate": peak, "base": base_rate,
            "effective": round(effective, 2), "jump": round(jump, 1),
            "keys": keys, "wall": round(wall, 1),
            # Which media was actually measured. A short duration means a pre-roll
            # ad was on screen, and the reading says nothing about the feature.
            "dur": round(picked["dur"]) if picked and picked.get("dur") else None,
            "paused": picked.get("paused") if picked else None}


# --------------------------------------------------------------------------
# Keeping this list honest about the one in the source
# --------------------------------------------------------------------------

def domains_in_source():
    """Read SiteMatcher.verifiedDomains so a domain added to the app but never
    added here cannot pass unnoticed."""
    path = os.path.join(REPO, "Sources", "TriBoostCore", "SiteMatcher.swift")
    try:
        src = open(path, encoding="utf-8").read()
    except OSError:
        return None
    block = re.search(r"verifiedDomains\s*=\s*\[(.*?)\]", src, re.S)
    if not block:
        return None
    return re.findall(r'"([^"]+)"', block.group(1))


# --------------------------------------------------------------------------

def run(args):
    targets = SITES + ([] if args.skip_rejected else REJECTED)
    if args.site:
        targets = [s for s in targets if args.site in s["name"] or args.site in s["domain"]]
        if not targets:
            print(f"no site matching {args.site!r}")
            return 2

    modes = [m for m in args.modes.split(",") if m in ("single", "repeat")]
    if not modes:
        print("--modes must name single, repeat, or both")
        return 2

    chrome = Chrome(args.port, args.use_login, args.keep_open)
    signal.signal(signal.SIGINT, lambda *_: (chrome.shutdown(), sys.exit(130)))

    results = []
    try:
        for site in targets:
            print(f"\n{site['name']}  ({site['domain']})", flush=True)
            if site.get("note"):
                print(f"  note: {site['note']}")
            results.append(check(chrome, site, modes, args))
    finally:
        chrome.shutdown()

    return report(results, modes, used_login=args.use_login)


def advice(state, used_login):
    """What to try next, given what this run already did."""
    if state == "BLOCKED":
        return ("signed-in sessions attract captchas here; try without --use-login"
                if used_login else "try --use-login, or clear it by hand in a browser")
    return ("check by hand; the player may need a real click to start"
            if used_login else "try --use-login: ads and paywalls stop playback")


def check(chrome, site, modes, args):
    """Measure one site, more than once if it looks broken.

    These players are flaky under automation: the same site can answer SPEED,
    NONE and NO_MEDIA on three consecutive runs, depending on where an ad was in
    its cycle. A checker that cries wolf gets ignored, which would make it worse
    than no checker at all — so a bad result has to repeat itself before it is
    believed. A good result is accepted immediately; nothing about this setup can
    invent a speed-up that did not happen."""
    attempts = 1 if site["expect"] is None else args.attempts

    for attempt in range(1, attempts + 1):
        if attempt > 1:
            print(f"  retrying ({attempt}/{attempts}) — sites are flaky, "
                  f"a failure has to repeat before it counts", flush=True)
        chrome.goto(site["url"], wait=site.get("wait", args.wait))
        chrome.js(LISTEN)

        state = settle(chrome, site)
        if state != "OK":
            print(f"  {state}")
            if attempt == attempts:
                return {"site": site, "state": state, "runs": {}}
            continue

        runs = {}
        for mode in modes:
            r = hold(chrome, site, repeat=(mode == "repeat"))
            runs[mode] = r
            rate = f"{r['base']}→{r['rate']}" if r.get("rate") is not None else \
                   f"{r.get('effective', '?')}x by clock"
            media = f"  media {r['dur']}s" if r.get("dur") else ""
            paused = "  PAUSED" if r.get("paused") else ""
            print(f"  {mode:7s} {r['verdict']:6s}  {rate}  "
                  f"jump {r.get('jump', '?')}s  keys {r['keys']}{media}{paused}", flush=True)
            time.sleep(2)

        if site["expect"] is None or any(r["verdict"] == "SPEED" for r in runs.values()):
            return {"site": site, "state": "OK", "runs": runs}
        if attempt == attempts:
            return {"site": site, "state": "OK", "runs": runs}

    return {"site": site, "state": "OK", "runs": {}}


def report(results, modes, used_login=False):
    print("\n" + "=" * 72)
    print("SUMMARY")
    print("=" * 72)

    failures, notes = [], []

    for row in results:
        site, runs, state = row["site"], row["runs"], row["state"]
        expected = site["expect"]
        label = f"{site['name']:9s}"

        if state != "OK":
            # A captcha or a paywall says nothing about whether the site works.
            print(f"{label} {state} — not measured")
            notes.append(f"{site['name']}: {state} — {advice(state, used_login)}")
            continue

        verdicts = {m: runs[m]["verdict"] for m in modes if m in runs}
        works = [m for m, v in verdicts.items() if v == "SPEED"]

        if expected is None:
            if works:
                print(f"{label} now speeds up in {'/'.join(works)} mode — worth adding")
                notes.append(f"{site['name']} changed: it used to ignore the key")
            else:
                print(f"{label} still not a speed-up ({', '.join(verdicts.values())}) — correctly excluded")
            continue

        if not works:
            print(f"{label} BROKEN — expected {expected}x, got {', '.join(f'{m}:{v}' for m, v in verdicts.items())}")
            failures.append(site)
        elif "single" in verdicts and "repeat" in verdicts and \
                verdicts["single"] != "SPEED" and verdicts["repeat"] == "SPEED":
            # The Tencent signature. Auto-repeat is on by default, so this is a
            # warning about what the site now depends on, not a failure.
            print(f"{label} OK, but only with auto-repeat "
                  f"(single: {verdicts['single']}) — this site counts key repeats")
            notes.append(f"{site['name']} needs auto-repeat; do not disable Thresholds.autorepeat*")
        else:
            print(f"{label} OK ({'/'.join(works)})")

    source = domains_in_source()
    if source is not None:
        listed = {s["domain"] for s in SITES}
        missing = [d for d in source if d not in listed]
        extra = [d for d in listed if d not in source]
        if missing:
            print(f"\n!! in SiteMatcher but not checked here: {', '.join(missing)}")
            notes.append("add the missing domains to SITES so they get verified")
        if extra:
            print(f"\n!! checked here but not in SiteMatcher: {', '.join(extra)}")

    if notes:
        print("\nNotes:")
        for n in notes:
            print(f"  - {n}")

    if failures:
        print(f"\nFAILED: {', '.join(s['name'] for s in failures)}")
        print("A site in the built-in list no longer speeds up on a held key.")
        print("Either the player changed, or the way we hold the key no longer")
        print("matches what it expects. Compare the two modes above first.")
        return 1

    print("\nAll built-in sites behave as expected.")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--site", help="only check sites matching this name or domain")
    p.add_argument("--modes", default="single,repeat", help="single, repeat, or both")
    p.add_argument("--use-login", action="store_true",
                   help="copy the signed-in session so ads and paywalls do not "
                        "mask a real result (temp copy, deleted on exit)")
    p.add_argument("--keep-open", action="store_true",
                   help="leave the browser running afterwards")
    p.add_argument("--skip-rejected", action="store_true",
                   help="only check the built-in sites")
    p.add_argument("--attempts", type=int, default=3,
                   help="how many times a built-in site may fail before it is "
                        "believed (default 3; these players are flaky)")
    p.add_argument("--port", type=int, default=9333)
    p.add_argument("--wait", type=float, default=10, help="seconds to wait after navigating")
    args = p.parse_args()

    if not os.path.exists(CHROME):
        print(f"Google Chrome not found at {CHROME}")
        return 2
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
