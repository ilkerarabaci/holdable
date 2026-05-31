#!/usr/bin/env python3
"""Generate a binary STL of an approximate target size for perf testing.

Produces a UV-sphere mesh whose triangle count is tuned so the resulting
binary STL lands near the requested megabytes. Binary STL layout:
  80-byte header + uint32 triangle count + 50 bytes per triangle.

Not bundled in the app — generate locally and `adb push` to the device,
then import via the Holdable file picker.

Usage:
  python tools/gen_stl.py 10 25 50          # MB sizes -> perf_<n>mb.stl
  python tools/gen_stl.py 50 --out big.stl  # single size, custom name
"""
import argparse
import math
import struct
import sys

BYTES_PER_TRI = 50
HEADER = 84  # 80-byte header + 4-byte count


def uv_sphere(stacks, slices, radius=50.0):
    """Yield (v0, v1, v2) triangles for a UV sphere centered at origin."""
    def vert(i, j):
        phi = math.pi * i / stacks          # 0..pi  (lat)
        theta = 2.0 * math.pi * j / slices  # 0..2pi (lon)
        x = radius * math.sin(phi) * math.cos(theta)
        y = radius * math.cos(phi)
        z = radius * math.sin(phi) * math.sin(theta)
        return (x, y, z)

    for i in range(stacks):
        for j in range(slices):
            a = vert(i, j)
            b = vert(i + 1, j)
            c = vert(i + 1, j + 1)
            d = vert(i, j + 1)
            if i != 0:                       # top cap: one tri per quad
                yield (a, b, c)
            if i != stacks - 1:              # bottom cap: one tri per quad
                yield (a, c, d)


def write_stl(path, triangles):
    n = len(triangles)
    with open(path, "wb") as f:
        f.write(b"Holdable perf fixture".ljust(80, b"\0"))
        f.write(struct.pack("<I", n))
        for (v0, v1, v2) in triangles:
            f.write(struct.pack("<3f", 0.0, 0.0, 0.0))  # normal (0 = recompute)
            for v in (v0, v1, v2):
                f.write(struct.pack("<3f", *v))
            f.write(struct.pack("<H", 0))               # attribute byte count
    return n


def gen_for_mb(mb, out):
    target_tris = int((mb * 1024 * 1024 - HEADER) / BYTES_PER_TRI)
    # UV sphere triangle count ~= 2 * slices * (stacks-1); use stacks=slices=k.
    k = max(4, round(math.sqrt(target_tris / 2.0)))
    tris = list(uv_sphere(k, k))
    n = write_stl(out, tris)
    size_mb = (HEADER + n * BYTES_PER_TRI) / (1024 * 1024)
    print(f"  {out}: {n:,} tris, {size_mb:.1f} MB (target {mb} MB, k={k})")


def main(argv):
    p = argparse.ArgumentParser(description="Generate binary STL perf fixtures.")
    p.add_argument("sizes", type=int, nargs="+", help="target sizes in MB")
    p.add_argument("--out", help="output filename (only valid with one size)")
    args = p.parse_args(argv)

    if args.out and len(args.sizes) != 1:
        p.error("--out requires exactly one size")

    print("Generating STL fixtures:")
    for mb in args.sizes:
        out = args.out or f"perf_{mb}mb.stl"
        gen_for_mb(mb, out)


if __name__ == "__main__":
    main(sys.argv[1:])
