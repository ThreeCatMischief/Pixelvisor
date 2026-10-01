#!/usr/bin/env python3
"""A fake Pixelvisor for developing the apps without hardware (docs/protocol.md). Standard library only.

    python3 tools/mock_device.py                     # HTTP :8080, DDP :4048, Bonjour via dns-sd
    python3 tools/mock_device.py --show              # render the strip in the terminal
    python3 tools/mock_device.py --latency-ms 300 --fail-rate 0.1
    python3 tools/mock_device.py --self-test         # validation rules against protocol/fixtures

Validation follows firmware/src/model.cpp, so the self-test runs the same fixture cases as
the firmware tests.
"""

import argparse
import json
import pathlib
import random
import socket
import struct
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIXTURES = pathlib.Path(__file__).resolve().parent.parent / "protocol" / "fixtures"
EFFECTS = json.loads((FIXTURES / "effects.json").read_text())
COLOR_ORDERS = ["RGB", "RBG", "GRB", "GBR", "BRG", "BGR"]
DATA_PINS = [0, 1, 3, 4, 5, 6, 7, 10, 20]


class Invalid(Exception):
    def __init__(self, message, field=None):
        super().__init__(message)
        self.field = field


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def byte(v, field, what):
    if not is_int(v) or not 0 <= v <= 255:
        raise Invalid(f"{what} must be an integer 0-255", field)
    return v


def rgb(v, field):
    if not isinstance(v, list) or len(v) != 3 or not all(is_int(c) and 0 <= c <= 255 for c in v):
        raise Invalid(f"{field} must be [r, g, b] with integers 0-255", field)
    return v


def patch_state(state, body):
    """Returns (new_state, has_mode, transition_ms). All-or-nothing."""
    if not isinstance(body, dict):
        raise Invalid("body must be a JSON object")
    s = json.loads(json.dumps(state))
    if body.get("on") is not None:
        if not isinstance(body["on"], bool):
            raise Invalid("on must be true or false", "on")
        s["on"] = body["on"]
    if body.get("brightness") is not None:
        s["brightness"] = byte(body["brightness"], "brightness", "brightness")
    if body.get("mode") is not None:
        if body["mode"] not in ("solid", "effect"):
            raise Invalid('mode must be "solid" or "effect"', "mode")
        s["mode"] = body["mode"]
    if body.get("color") is not None:
        s["color"] = rgb(body["color"], "color")
    effect = body.get("effect")
    if effect is not None:
        if not isinstance(effect, dict):
            raise Invalid("effect must be an object", "effect")
        if effect.get("id") is not None:
            if effect["id"] not in [e["id"] for e in EFFECTS]:
                raise Invalid("unknown effect id, see GET /api/effects", "effect.id")
            s["effect"]["id"] = effect["id"]
        if effect.get("speed") is not None:
            s["effect"]["speed"] = byte(effect["speed"], "effect.speed", "effect.speed")
        if effect.get("color2") is not None:
            s["effect"]["color2"] = rgb(effect["color2"], "effect.color2")
    transition = body.get("transition_ms", 400)
    if transition is None:
        transition = 400
    if not is_int(transition) or not 0 <= transition <= 10000:
        raise Invalid("transition_ms must be an integer 0-10000", "transition_ms")
    return s, body.get("mode") is not None, transition


def patch_config(config, body):
    if not isinstance(body, dict):
        raise Invalid("body must be a JSON object")
    c = dict(config)

    def check(field, ok, message):
        if body.get(field) is not None:
            if not ok(body[field]):
                raise Invalid(message, field)
            c[field] = body[field]

    check("name", lambda v: isinstance(v, str) and 1 <= len(v) <= 32 and len(v.encode()) <= 63, "name must be 1-32 characters")
    check("hostname", lambda v: isinstance(v, str) and 1 <= len(v) <= 24 and all(ch in "abcdefghijklmnopqrstuvwxyz0123456789-" for ch in v),
          "hostname must match [a-z0-9-]{1,24}")
    check("led_count", lambda v: is_int(v) and 1 <= v <= 480, "led_count must be an integer 1-480")
    check("data_pin", lambda v: is_int(v) and v in DATA_PINS, "data_pin is not an allowed GPIO on this board")
    check("color_order", lambda v: v in COLOR_ORDERS, "color_order must be RGB, RBG, GRB, GBR, BRG or BGR")
    check("reverse", lambda v: isinstance(v, bool), "reverse must be true or false")
    check("max_current_ma", lambda v: is_int(v) and (v == 0 or 100 <= v <= 20000), "max_current_ma must be 0 or 100-20000")
    check("ma_per_channel", lambda v: is_int(v) and 1 <= v <= 60, "ma_per_channel must be an integer 1-60")
    if body.get("white_balance") is not None:
        c["white_balance"] = rgb(body["white_balance"], "white_balance")
    check("gamma", lambda v: isinstance(v, (int, float)) and not isinstance(v, bool) and 1.0 <= v <= 3.0, "gamma must be a number 1.0-3.0")
    check("dither", lambda v: isinstance(v, bool), "dither must be true or false")
    check("power_on", lambda v: v in ("restore", "on", "off"), 'power_on must be "restore", "on" or "off"')
    return c


def reboot_required(stored, running):
    return any(stored[k] != running[k] for k in ("hostname", "led_count", "data_pin"))


class Device:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.started = time.monotonic()
        self.id = "mock01"
        state = json.loads((FIXTURES / "state.json").read_text())
        self.rev = state.pop("rev")
        state.pop("realtime")
        self.state = state
        self.config = json.loads((FIXTURES / "config.json").read_text())
        self.config.pop("reboot_required")
        self.config["led_count"] = args.leds
        self.running = dict(self.config)
        self.frame = bytes(args.leds * 3)
        self.last_frame = None
        self.source = None
        self.blocked = None
        self.blocked_until = 0.0

    def realtime_active(self):
        return self.last_frame is not None and time.monotonic() - self.last_frame < 2.5

    def state_body(self):
        active = self.realtime_active()
        return {"rev": self.rev, **self.state, "realtime": {"active": active, "source": self.source if active else None}}

    def end_realtime(self):
        if self.realtime_active():
            self.blocked, self.blocked_until = self.source, time.monotonic() + 1.0
        self.last_frame = None

    def receive(self, data, sender):
        if len(data) < 10 or data[0] >> 6 != 1 or data[2] not in (0x00, 0x01, 0x0B) or data[3] not in (1, 255):
            return
        header = 14 if data[0] & 0x10 else 10
        offset, length = struct.unpack(">IH", data[4:10])
        payload = data[header:header + length]
        now = time.monotonic()
        with self.lock:
            if self.blocked:
                if now >= self.blocked_until:
                    self.blocked = None
                elif sender == self.blocked:
                    self.blocked_until = now + 1.0
                    return
            if not self.state["on"]:
                return
            frame = bytearray(self.frame)
            end = min(offset + len(payload), len(frame))
            if offset < len(frame):
                frame[offset:end] = payload[:end - offset]
            self.frame = bytes(frame)
            if data[0] & 0x01:
                self.last_frame, self.source = now, sender

    def colors(self):
        with self.lock:
            if not self.state["on"]:
                return [(0, 0, 0)] * self.running["led_count"]
            scale = self.state["brightness"] / 255
            if self.realtime_active():
                f = self.frame
                pixels = [(f[i], f[i + 1], f[i + 2]) for i in range(0, len(f), 3)]
            else:
                pixels = [tuple(self.state["color"])] * self.running["led_count"]
            return [tuple(int(c * scale) for c in p) for p in pixels]


def make_handler(device):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *a):
            if not device.args.show:
                sys.stderr.write(f"{self.command} {self.path} -> {a[1] if len(a) > 1 else ''}\n")

        def send(self, code, body=None):
            data = b"" if body is None else json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "*")
            self.send_header("Access-Control-Allow-Headers", "*")
            self.end_headers()
            self.wfile.write(data)

        def body(self):
            length = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(length) or b"null")

        def prelude(self):
            time.sleep(device.args.latency_ms / 1000)
            if random.random() < device.args.fail_rate:
                self.close_connection = True
                return False
            return True

        def do_OPTIONS(self):
            self.send(204)

        def do_GET(self):
            if not self.prelude():
                return
            with device.lock:
                if self.path == "/api/info":
                    self.send(200, {"api": 1, "fw": "0.1.0-mock", "id": device.id, "name": device.config["name"],
                                    "hostname": device.running["hostname"], "board": "mock", "led_count": device.running["led_count"],
                                    "ip": "127.0.0.1", "rssi": -50, "uptime_s": int(time.monotonic() - device.started),
                                    "free_heap": 200000, "ddp": {"port": device.args.ddp_port, "max_leds": 480}})
                elif self.path == "/api/state":
                    self.send(200, device.state_body())
                elif self.path == "/api/effects":
                    self.send(200, EFFECTS)
                elif self.path == "/api/config":
                    self.send(200, {**device.config, "reboot_required": reboot_required(device.config, device.running)})
                elif self.path == "/api/wifi/scan":
                    self.send(200, [{"ssid": "Home", "rssi": -48, "secure": True}, {"ssid": "Cafe", "rssi": -77, "secure": False}])
                else:
                    self.send(404, {"error": "not found"})

        def do_PATCH(self):
            if not self.prelude():
                return
            try:
                body = self.body()
            except json.JSONDecodeError:
                return self.send(400, {"error": "body is not valid JSON"})
            with device.lock:
                try:
                    if self.path == "/api/state":
                        state, has_mode, _ = patch_state(device.state, body)
                        if state != device.state:
                            device.rev += 1
                        device.state = state
                        if has_mode:
                            device.end_realtime()
                        self.send(200, device.state_body())
                    elif self.path == "/api/config":
                        device.config = patch_config(device.config, body)
                        self.send(200, {**device.config, "reboot_required": reboot_required(device.config, device.running)})
                    else:
                        self.send(404, {"error": "not found"})
                except Invalid as e:
                    self.send(400, {"error": str(e), **({"field": e.field} if e.field else {})})

        def do_POST(self):
            if not self.prelude():
                return
            if self.path == "/api/ota":
                length = int(self.headers.get("Content-Length") or 0)
                self.rfile.read(length)
                time.sleep(2)
                self.send(200, {"ok": True})
                device.started = time.monotonic()  # looks like a restart
            elif self.path == "/api/wifi":
                try:
                    body = self.body()
                except json.JSONDecodeError:
                    return self.send(400, {"error": "body is not valid JSON"})
                ssid, password = (body or {}).get("ssid"), (body or {}).get("password", "")
                if not isinstance(ssid, str) or not 1 <= len(ssid.encode()) <= 32:
                    self.send(400, {"error": "ssid must be 1-32 bytes", "field": "ssid"})
                elif not isinstance(password, str) or (password and not 8 <= len(password) <= 63):
                    self.send(400, {"error": "password must be empty or 8-63 characters", "field": "password"})
                else:
                    self.send(202, {"ok": True})
            elif self.path in ("/api/reboot", "/api/identify"):
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                self.send(202, {"ok": True})
                if self.path == "/api/reboot":
                    with device.lock:
                        device.running = dict(device.config)
                        device.started = time.monotonic()
            else:
                self.send(404, {"error": "not found"})

        def do_DELETE(self):
            if self.path == "/api/wifi":
                self.send(202, {"ok": True})  # the real device restarts into its setup portal
            else:
                self.send(404, {"error": "not found"})

    return Handler


def ddp_loop(device):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", device.args.ddp_port))
    while True:
        data, (host, _) = sock.recvfrom(2048)
        device.receive(data, host)


def show_loop(device):
    while True:
        line = "".join(f"\x1b[48;2;{r};{g};{b}m " for r, g, b in device.colors())
        with device.lock:
            status = f"rev {device.rev}  {device.state['mode']}  " + (f"realtime from {device.source}" if device.realtime_active() else "")
        sys.stdout.write(f"\r{line}\x1b[0m  {status:<40}")
        sys.stdout.flush()
        time.sleep(1 / 30)


def self_test():
    failures = 0
    cases = json.loads((FIXTURES / "state_patches.json").read_text())
    base = cases["base"]
    for c in cases["cases"]:
        try:
            state, _, _ = patch_state(base, c["patch"])
            ok = c["valid"] and all(state.get(k) == v for k, v in c["expect"].items())
        except Invalid as e:
            ok = not c["valid"] and e.field == c.get("field")
        failures += not ok
        print(("PASS  " if ok else "FAIL  ") + "state: " + c["name"])
    config = json.loads((FIXTURES / "config.json").read_text())
    config.pop("reboot_required")
    for c in json.loads((FIXTURES / "config_patches.json").read_text())["cases"]:
        try:
            new = patch_config(config, c["patch"])
            ok = c["valid"] and reboot_required(new, config) == c["reboot_required"]
        except Invalid as e:
            ok = not c["valid"] and e.field == c["field"]
        failures += not ok
        print(("PASS  " if ok else "FAIL  ") + "config: " + c["name"])
    print(f"{failures} failed" if failures else "all passed")
    return failures


def main():
    parser = argparse.ArgumentParser(description="A fake Pixelvisor for app development.")
    parser.add_argument("--leds", type=int, default=43)
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--ddp-port", type=int, default=4048)
    parser.add_argument("--name", default="Pixelvisor Mock")
    parser.add_argument("--no-mdns", action="store_true")
    parser.add_argument("--show", action="store_true", help="render the strip in the terminal")
    parser.add_argument("--latency-ms", type=int, default=0)
    parser.add_argument("--fail-rate", type=float, default=0.0)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        sys.exit(1 if self_test() else 0)

    device = Device(args)
    threading.Thread(target=ddp_loop, args=(device,), daemon=True).start()
    if args.show:
        threading.Thread(target=show_loop, args=(device,), daemon=True).start()
    mdns = None
    if not args.no_mdns:
        txt = [f"id={device.id}", "api=1", "fw=0.1.0-mock", f"leds={args.leds}", f"ddp={args.ddp_port}"]
        mdns = subprocess.Popen(["dns-sd", "-R", args.name, "_pixelvisor._tcp", "local", str(args.port), *txt],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"mock Pixelvisor: http://127.0.0.1:{args.port}, DDP :{args.ddp_port}" + ("" if args.no_mdns else ", advertised as _pixelvisor._tcp"))
    try:
        ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(device)).serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if mdns:
            mdns.terminate()


if __name__ == "__main__":
    main()
