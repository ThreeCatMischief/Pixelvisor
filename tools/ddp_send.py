#!/usr/bin/env python3
"""Sends DDP frames to a Pixelvisor (docs/protocol.md, Realtime: DDP). Standard library only.

    python3 tools/ddp_send.py pixelvisor.local --pattern rainbow --fps 60
    python3 tools/ddp_send.py 192.168.1.42 --pattern solid 255,80,0 --seconds 5
    python3 tools/ddp_send.py pixelvisor.local --pattern index

Patterns: solid R,G,B | rainbow | chase | gradient R,G,B R,G,B | index (LED 0 red, last LED
blue, the rest dim white; shows whether `reverse` is set correctly). --leds defaults to
led_count from GET /api/info.
"""

import argparse
import colorsys
import json
import socket
import struct
import time
import urllib.request

PATTERNS = {"solid": 1, "rainbow": 0, "chase": 0, "gradient": 2, "index": 0}  # name: colors


def rgb(text):
    parts = text.split(",")
    if len(parts) != 3 or not all(p.isdigit() and int(p) <= 255 for p in parts):
        raise ValueError(f"expected R,G,B with values 0-255, got {text!r}")
    return [int(p) for p in parts]


def packet(seq, data):
    # Version 1 with PUSH, sequence 1-15, RGB 8 bit, default output, offset 0.
    return struct.pack(">BBBBIH", 0x41, seq, 0x0B, 0x01, 0, len(data)) + data


def frame(pattern, colors, n, t):
    if pattern == "solid":
        pixels = [colors[0]] * n
    elif pattern == "rainbow":
        pixels = [[round(c * 255) for c in colorsys.hsv_to_rgb((i / n + t / 5) % 1, 1, 1)] for i in range(n)]
    elif pattern == "chase":
        head = int(t * n / 2) % n  # crosses the strip in 2 s
        pixels = [[255, 255, 255] if i == head else [0, 0, 0] for i in range(n)]
    elif pattern == "gradient":
        a, b = colors
        pixels = [[round(a[k] + (b[k] - a[k]) * i / max(n - 1, 1)) for k in range(3)] for i in range(n)]
    else:
        pixels = [[10, 10, 10]] * n
        pixels[0], pixels[-1] = [255, 0, 0], [0, 0, 255]
    return bytes(v for p in pixels for v in p)


def main():
    parser = argparse.ArgumentParser(description="Send DDP frames to a Pixelvisor.")
    parser.add_argument("host")
    parser.add_argument("--pattern", nargs="+", default=["rainbow"], metavar="NAME [R,G,B ...]")
    parser.add_argument("--leds", type=int, help="LED count (default: led_count from /api/info)")
    parser.add_argument("--port", type=int, default=4048)
    parser.add_argument("--fps", type=float, default=30)
    parser.add_argument("--seconds", type=float, default=0, help="0 runs until Ctrl-C")
    args = parser.parse_args()

    name = args.pattern[0]
    try:
        colors = [rgb(c) for c in args.pattern[1:]]
    except ValueError as e:
        parser.error(str(e))
    if PATTERNS.get(name) != len(colors):
        parser.error("patterns: solid R,G,B | rainbow | chase | gradient R,G,B R,G,B | index")

    address = socket.gethostbyname(args.host)
    n = args.leds
    if n is None:
        with urllib.request.urlopen(f"http://{address}/api/info", timeout=3) as response:
            n = json.load(response)["led_count"]

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    start = time.monotonic()
    sent = 0
    try:
        while not args.seconds or time.monotonic() - start < args.seconds:
            sock.sendto(packet(sent % 15 + 1, frame(name, colors, n, time.monotonic() - start)), (address, args.port))
            sent += 1
            time.sleep(max(0.0, start + sent / args.fps - time.monotonic()))
    except KeyboardInterrupt:
        pass
    print(f"sent {sent} frames of {n} LEDs to {address}:{args.port}")


if __name__ == "__main__":
    main()
