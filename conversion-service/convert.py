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

# Cap the polygon budget. The glTF exporter is single-threaded Python and is
# dominated by raw face count, and export_apply bakes the FULL modifier stack
# first — so a model whose faces explode under a Subdivision Surface (or
# Array/Mirror) is exported at its evaluated density and blows the job timeout
# (4Holdable2: 49 MB .blend, export timed out at 1500 s). Two guards, both
# best-effort so a quirky model can never break the pipeline:
#   1) Cap Subdivision Surface levels so the exporter never has to evaluate an
#      exploded mesh (the dominant cost on detailed, modelled assets).
#   2) Size the decimate on the EVALUATED (post-modifier) face count, not the
#      base count — a low-base subsurf model otherwise skips decimation and then
#      explodes on export. Was: base-count only, which missed exactly this case.
TRI_BUDGET = int(os.environ.get("CONVERT_TRI_BUDGET", "400000"))
SUBSURF_MAX = int(os.environ.get("CONVERT_SUBSURF_MAX", "2"))
meshes = [o for o in bpy.data.objects if o.type == "MESH" and o.data]

capped = 0
for o in meshes:
    for m in list(o.modifiers):
        if m.type == "SUBSURF":
            try:
                if m.render_levels > SUBSURF_MAX:
                    m.render_levels = SUBSURF_MAX
                    capped += 1
                if m.levels > SUBSURF_MAX:
                    m.levels = SUBSURF_MAX
            except Exception as e:  # noqa: BLE001 - a modifier quirk must not abort
                _log(f"subsurf cap failed on {o.name}: {e}")

base_faces = sum(len(o.data.polygons) for o in meshes)
try:
    dg = bpy.context.evaluated_depsgraph_get()
    total_faces = sum(len(o.evaluated_get(dg).data.polygons) for o in meshes)
except Exception as e:  # noqa: BLE001
    _log(f"evaluated face count failed, using base: {e}")
    total_faces = base_faces
_log(f"meshes={len(meshes)} base_faces={base_faces} eval_faces={total_faces} "
     f"subsurf_capped={capped} budget={TRI_BUDGET}")

decimated = False
if total_faces > TRI_BUDGET and total_faces > 0:
    ratio = max(0.005, TRI_BUDGET / total_faces)
    for o in meshes:
        mod = o.modifiers.new(name="hold_decimate", type="DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = ratio
    decimated = True
    _log(f"decimating eval {total_faces} -> {TRI_BUDGET} (ratio {ratio:.4f})")

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
