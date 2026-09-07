#!/usr/bin/env python3
"""Generate assets/icon.png -- the icon Sileo shows for the package.

A git-branch glyph: a trunk with one branch curving off it, three nodes. It
reads at 40px, which is the only size that matters in a package list.

Pure stdlib, same approach as the sibling CCForiOS project: render at 4x and
box-downsample for antialiasing, then write the PNG by hand, so the build needs
no image libraries on any runner.
"""
import math
import os
import struct
import zlib

S = 256          # final size
SS = 4           # supersample factor
N = S * SS

BG = (0x0D, 0x11, 0x17)      # github dark canvas
FG = (0xE6, 0xED, 0xF3)      # near-white
ACC = (0x3F, 0xB9, 0x50)     # github green

R = int(N * 0.225)           # corner radius


def inside_rounded(x, y):
    if R <= x < N - R or R <= y < N - R:
        return 0 <= x < N and 0 <= y < N
    cx = R if x < R else N - R - 1
    cy = R if y < R else N - R - 1
    return (x - cx) ** 2 + (y - cy) ** 2 <= R * R


def stroke(buf, x0, y0, x1, y1, w, color):
    """Filled capsule from (x0,y0) to (x1,y1), radius w."""
    dx, dy = x1 - x0, y1 - y0
    L2 = dx * dx + dy * dy
    lo_x, hi_x = int(min(x0, x1) - w - 1), int(max(x0, x1) + w + 2)
    lo_y, hi_y = int(min(y0, y1) - w - 1), int(max(y0, y1) + w + 2)
    for y in range(max(0, lo_y), min(N, hi_y)):
        for x in range(max(0, lo_x), min(N, hi_x)):
            t = 0.0 if L2 == 0 else ((x - x0) * dx + (y - y0) * dy) / L2
            t = 0.0 if t < 0 else (1.0 if t > 1 else t)
            px, py = x0 + t * dx, y0 + t * dy
            if (x - px) ** 2 + (y - py) ** 2 <= w * w:
                buf[y * N + x] = color


def arc(buf, cx, cy, rad, a0, a1, w, color, steps=160):
    """Stroked arc, drawn as a chain of short capsules."""
    prev = None
    for i in range(steps + 1):
        a = math.radians(a0 + (a1 - a0) * i / steps)
        p = (cx + rad * math.cos(a), cy + rad * math.sin(a))
        if prev:
            stroke(buf, prev[0], prev[1], p[0], p[1], w, color)
        prev = p


def disc(buf, cx, cy, rad, color):
    stroke(buf, cx, cy, cx, cy, rad, color)


def ring(buf, cx, cy, rad, w, color, bg):
    disc(buf, cx, cy, rad, color)
    disc(buf, cx, cy, rad - w, bg)


def main():
    buf = [None] * (N * N)
    for y in range(N):
        for x in range(N):
            if inside_rounded(x, y):
                buf[y * N + x] = BG

    u = N / 100.0
    w = 5.0 * u          # stroke half-width
    nr = 10.0 * u        # node radius
    trunk_x = 33 * u
    branch_x = 67 * u

    # trunk, top node to bottom node
    stroke(buf, trunk_x, 24 * u, trunk_x, 76 * u, w, FG)
    # branch: leaves the trunk, curves right and up to the branch node
    stroke(buf, trunk_x, 56 * u, branch_x - 16 * u, 56 * u, w, ACC)
    arc(buf, branch_x - 16 * u, 40 * u, 16 * u, 90, 0, w, ACC)
    stroke(buf, branch_x, 40 * u, branch_x, 34 * u, w, ACC)

    ring(buf, trunk_x, 24 * u, nr, w * 1.15, FG, BG)      # trunk head
    ring(buf, trunk_x, 76 * u, nr, w * 1.15, FG, BG)      # trunk tail
    ring(buf, branch_x, 24 * u, nr, w * 1.15, ACC, BG)    # branch head

    # downsample with alpha from coverage
    out = bytearray()
    k = SS * SS
    for y in range(S):
        out.append(0)
        for x in range(S):
            r = g = b = a = 0
            for j in range(SS):
                row = (y * SS + j) * N + x * SS
                for i in range(SS):
                    p = buf[row + i]
                    if p is not None:
                        r += p[0]; g += p[1]; b += p[2]; a += 255
            if a:
                n = a // 255
                out += bytes((r // n, g // n, b // n, a // k))
            else:
                out += b"\0\0\0\0"

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(out), 9))
           + chunk(b"IEND", b""))

    dst = os.path.join(os.path.dirname(__file__), "..", "assets", "icon.png")
    with open(dst, "wb") as f:
        f.write(png)
    print("wrote %s (%d bytes, %dx%d)" % (os.path.normpath(dst), len(png), S, S))


main()
