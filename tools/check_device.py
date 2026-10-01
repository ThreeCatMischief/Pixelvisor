#!/usr/bin/env python3
"""Checks a running Pixelvisor against docs/protocol.md and protocol/fixtures. Standard library only.

    python3 tools/check_device.py pixelvisor.local
    python3 tools/check_device.py 127.0.0.1:8080       # against tools/mock_device.py

The light changes while it runs (brightness, colors, a short DDP stream, identify); the
previous state is restored at the end. Config only receives invalid patches, so it stays
unchanged. Takes about 15 s.
"""

import argparse
import json
import pathlib
import socket
import struct
import sys
import time
import urllib.error
import urllib.request

FIXTURES = pathlib.Path(__file__).resolve().parent.parent / "protocol" / "fixtures"
WRITABLE = ("on", "brightness", "mode", "color", "effect")
failures = []


def fixture(name):
    return json.loads((FIXTURES / name).read_text())


def check(name, ok, detail=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else f"\n      {detail}"))
    if not ok:
        failures.append(name)


class Device:
    def __init__(self, host, ddp_port=4048):
        host, _, port = host.partition(":")
        self.address = socket.gethostbyname(host)
        self.port = int(port or 80)
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.ddp_port = ddp_port
        self.udp.connect((self.address, ddp_port))
        self.local_ip = self.udp.getsockname()[0]

    def request(self, method, path, body=None, raw=None, content_type="application/json"):
        data = raw if raw is not None else None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(f"http://{self.address}:{self.port}{path}", data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                text = r.read()
                return r.status, json.loads(text) if text else None, r.headers
        except urllib.error.HTTPError as e:
            text = e.read()
            return e.code, json.loads(text) if text else None, e.headers

    def state(self):
        return self.request("GET", "/api/state")[1]

    def patch(self, body):
        return self.request("PATCH", "/api/state", body)

    def stream(self, n, seconds, fps=30):
        frame = bytes([0, 40, 80]) * n
        end = time.monotonic() + seconds
        seq = 0
        while time.monotonic() < end:
            seq = seq % 15 + 1
            self.udp.send(struct.pack(">BBBBIH", 0x41, seq, 0x0B, 1, 0, len(frame)) + frame)
            time.sleep(1 / fps)


def state_checks(dev, original):
    target = 61 if original["brightness"] == 60 else 60
    status, s, _ = dev.patch({"brightness": target, "transition_ms": 150})
    check("PATCH brightness increments rev", status == 200 and s["brightness"] == target and s["rev"] == original["rev"] + 1, s)
    status, same, _ = dev.patch({"brightness": target})
    check("PATCH with the current value keeps rev", status == 200 and same["rev"] == s["rev"], same)
    status, form, _ = dev.request("PATCH", "/api/state", raw=b'{"brightness":70}', content_type="application/x-www-form-urlencoded")
    check("PATCH sent as a form body, like curl -d", status == 200 and form["brightness"] == 70, (status, form))

    cases = fixture("state_patches.json")
    for case in cases["cases"]:
        dev.patch(cases["base"])
        status, body, _ = dev.patch(case["patch"])
        if case["valid"]:
            ok = status == 200 and all(body.get(k) == v for k, v in case["expect"].items())
            check(f"state patch: {case['name']}", ok, (status, body))
        else:
            check(f"state patch rejected: {case['name']}", status == 400 and body.get("field") == case.get("field"), (status, body))


def config_checks(dev):
    status, before, _ = dev.request("GET", "/api/config")
    check("GET /api/config", status == 200 and before.get("reboot_required") is False, (status, before))
    for case in fixture("config_patches.json")["cases"]:
        if not case["valid"]:
            status, body, _ = dev.request("PATCH", "/api/config", case["patch"])
            check(f"config patch rejected: {case['name']}", status == 400 and body.get("field") == case["field"], (status, body))
    check("rejected config patches change nothing", dev.request("GET", "/api/config")[1] == before)


def realtime_checks(dev, n):
    dev.patch({"on": True, "transition_ms": 0})
    dev.stream(n, 0.5)
    rt = dev.state()["realtime"]
    check("DDP frames start realtime", rt == {"active": True, "source": dev.local_ip}, rt)

    _, s, _ = dev.patch({"mode": dev.state()["mode"]})
    check("PATCH with mode ends realtime", s["realtime"]["active"] is False, s["realtime"])
    dev.stream(n, 0.5)
    check("the sender stays blocked while it keeps sending", dev.state()["realtime"]["active"] is False)
    time.sleep(1.2)
    dev.stream(n, 0.3)
    check("the sender is accepted after a 1 s pause", dev.state()["realtime"]["active"] is True)
    time.sleep(2.7)
    check("realtime ends 2.5 s after the last frame", dev.state()["realtime"]["active"] is False)

    dev.patch({"on": False, "transition_ms": 0})
    dev.stream(n, 0.3)
    s = dev.state()
    check("frames are ignored while off", s["realtime"]["active"] is False and s["on"] is False, s)


def other_checks(dev):
    status, body, _ = dev.request("POST", "/api/identify")
    check("POST /api/identify", status == 202 and body == {"ok": True}, (status, body))
    time.sleep(1.6)
    status, _, headers = dev.request("OPTIONS", "/api/state")
    check("OPTIONS preflight with CORS", status == 204 and headers.get("Access-Control-Allow-Origin") == "*", (status, dict(headers)))
    status, body, _ = dev.request("GET", "/api/nope")
    check("unknown path is 404 with an error body", status == 404 and "error" in body, (status, body))
    status, body, _ = dev.request("POST", "/api/wifi", {"ssid": "x", "password": "short"})
    check("POST /api/wifi rejects a short password", status == 400 and body.get("field") == "password", (status, body))


def main():
    parser = argparse.ArgumentParser(description="Check a running Pixelvisor against the protocol.")
    parser.add_argument("host", help="host or host:port")
    parser.add_argument("--ddp-port", type=int, default=4048)
    args = parser.parse_args()
    host = args.host
    try:
        dev = Device(host, args.ddp_port)
    except OSError as e:
        sys.exit(f"cannot reach {host}: {e}")

    status, info, _ = dev.request("GET", "/api/info")
    check("GET /api/info", status == 200 and info["api"] == 1 and info["ddp"]["port"] == dev.ddp_port, info)
    print(f"      {info['name']} fw {info['fw']}, {info['led_count']} LEDs, {info['ip']}, RSSI {info['rssi']} dBm, heap {info['free_heap']}")
    status, effects, _ = dev.request("GET", "/api/effects")
    check("GET /api/effects matches effects.json", effects == fixture("effects.json"), effects)

    original = dev.state()
    try:
        state_checks(dev, original)
        config_checks(dev)
        realtime_checks(dev, info["led_count"])
        other_checks(dev)
    finally:
        dev.patch({k: original[k] for k in WRITABLE})

    print(f"\n{len(failures)} failed" if failures else "\nall passed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
