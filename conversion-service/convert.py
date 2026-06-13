"""Run inside headless Blender:

    blender --background --factory-startup --python convert.py -- <input> <output.glb>

Loads the input (.blend or USD) into an empty scene and exports a single .glb.
"""

import os
import sys
import time

import bpy


def _log(msg):
    print(f"[convert] {msg}", file=sys.stderr, flush=True)


argv = sys.argv[sys.argv.index("--") + 1:]
if len(argv) < 2:
    raise SystemExit("usage: convert.py -- <input> <output.glb>")
src, out = argv[0], argv[1]
ext = os.path.splitext(src)[1].lower()

_t = time.monotonic()
if ext == ".blend":
    # Opening a .blend replaces the whole scene with its contents.
    bpy.ops.wm.open_mainfile(filepath=src)
else:
    # Everything else: start from a truly empty scene, then import.
    bpy.ops.wm.read_factory_settings(use_empty=True)
    if ext in (".usd", ".usda", ".usdc", ".usdz"):
        bpy.ops.wm.usd_import(filepath=src)
    elif ext == ".stl":
        # The intermediate mesh FreeCAD produces for STEP/IGES.
        bpy.ops.wm.stl_import(filepath=src)
    else:
        raise SystemExit(f"unsupported extension: {ext}")

_log(f"loaded {ext} in {time.monotonic() - _t:.1f}s")

# Export everything as a single binary glTF. `export_apply` evaluates modifiers
# (what-you-see-is-what-you-get) but on a heavy modifier stack (subsurf/array)
# that can explode geometry and dominate export time — so it's env-toggleable
# (CONVERT_APPLY=0) for diagnosis / a future "fast / decimated" mode.
apply = os.environ.get("CONVERT_APPLY", "1") != "0"
_t = time.monotonic()
bpy.ops.export_scene.gltf(
    filepath=out,
    export_format="GLB",
    export_apply=apply,
    export_yup=True,
)
_log(f"exported (apply={apply}) in {time.monotonic() - _t:.1f}s")

if not os.path.exists(out):
    raise SystemExit("export_scene.gltf wrote no file")
