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

# Decimate to a polygon budget. The glTF exporter is single-threaded Python and
# is dominated by raw face count (diagnosis: a 49 MB .blend loaded in ~5s but
# its export never finished in 7 min — load-fast, export-bound). A dense scene
# would also be too heavy to render on a phone, so we cap faces: add a COLLAPSE
# Decimate modifier sized to bring the total under CONVERT_TRI_BUDGET, then bake
# it on export. Models already under budget are untouched.
TRI_BUDGET = int(os.environ.get("CONVERT_TRI_BUDGET", "400000"))
meshes = [o for o in bpy.data.objects if o.type == "MESH" and o.data]
total_faces = sum(len(o.data.polygons) for o in meshes)
decimated = False
if total_faces > TRI_BUDGET and total_faces > 0:
    ratio = max(0.005, TRI_BUDGET / total_faces)
    for o in meshes:
        mod = o.modifiers.new(name="hold_decimate", type="DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = ratio
    decimated = True
    _log(f"decimating {total_faces} faces -> ratio {ratio:.4f}")

# Export everything as a single binary glTF. export_apply bakes modifiers
# (including our decimate) — forced on when we decimated so the reduction takes
# effect; otherwise env-toggleable. +Y up matches the renderer's convention.
apply = decimated or os.environ.get("CONVERT_APPLY", "1") != "0"
_t = time.monotonic()
bpy.ops.export_scene.gltf(
    filepath=out,
    export_format="GLB",
    export_apply=apply,
    export_yup=True,
)
_log(f"exported (apply={apply}, decimated={decimated}) in {time.monotonic() - _t:.1f}s")

if not os.path.exists(out):
    raise SystemExit("export_scene.gltf wrote no file")
