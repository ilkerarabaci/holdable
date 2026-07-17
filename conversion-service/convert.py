"""Run inside headless Blender:

    blender --background --factory-startup --python convert.py -- <input> <output.glb>

Loads the input (.blend or USD) into an empty scene and exports a single .glb.
"""

import os
import sys
import time

import bmesh
import bpy


def _log(msg):
    print(f"[convert] {msg}", file=sys.stderr, flush=True)


_timings = []
_mesh_log = []  # per-mesh clean/decimate lines, surfaced in diag.txt


def _phase(label, t0):
    """Record + log a phase duration. The list is also written into diag.txt so a
    slow conversion is diagnosable per-phase (load/cap/bake/decimate/export)
    instead of as one opaque wall-clock — on success AND on timeout."""
    dt = time.monotonic() - t0
    _timings.append(f"{label}={dt:.1f}s")
    _log(f"[phase] {label} {dt:.1f}s")
    return time.monotonic()


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

_phase("load", _t)

# Mobile-fit reduction, each phase timed (stderr [phase] lines + diag.txt) so a
# slow run is diagnosable per-phase instead of as one opaque wall-clock:
#   1) Cap Subdivision levels (Subsurf/Multires) so the bake can't explode.
#   2) BAKE the whole modifier stack ONCE: apply it via the depsgraph and drop the
#      modifiers. The glTF export's export_apply otherwise re-evaluates every
#      modifier a SECOND time; on a heavy asset (4Holdable2: 15x Shrinkwrap +
#      Geometry Nodes, ~3.2M evaluated faces) that double evaluation is what blew
#      the runtime past 15 min. After baking, decimate + export run on static meshes.
#   3) Decimate the static heavy meshes to the budget, protecting small meshes.
TRI_BUDGET = int(os.environ.get("CONVERT_TRI_BUDGET", "400000"))
SUBSURF_MAX = int(os.environ.get("CONVERT_SUBSURF_MAX", "2"))
DECIMATE_FLOOR = int(os.environ.get("CONVERT_DECIMATE_FLOOR", "500"))
meshes = [o for o in bpy.data.objects if o.type == "MESH" and o.data]

# Capture each mesh's ORIGINAL modifier stack + base count NOW (baking clears the
# modifiers) — this is the core timeout diagnostic.
orig = []
for o in meshes:
    mods = ",".join(m.type for m in o.modifiers) or "-"
    orig.append((o.name, len(o.data.polygons), mods))
    _log(f"object '{o.name}': base_faces={len(o.data.polygons)} modifiers=[{mods}]")


def _write_diag(faces, baked, capped):
    """Modifier stacks + counts + phase timings, surfaced by job_worker into
    status.json on success OR timeout — no Cloud Run log spelunking needed."""
    try:
        lines = [f"meshes={len(meshes)} baked={baked} faces={faces} "
                 f"capped={capped} budget={TRI_BUDGET}",
                 "timings: " + " ".join(_timings)]
        lines += _mesh_log
        for name, bf, mods in orig:
            lines.append(f"{name}: base={bf} mods=[{mods}]")
        with open(os.path.join(os.path.dirname(out), "diag.txt"), "w") as f:
            f.write("\n".join(lines))
    except Exception as e:  # noqa: BLE001
        _log(f"diag write failed: {e}")


# (1) Cap Subdivision levels (BOTH viewport `levels` and `render_levels`, since the
# bake applies viewport settings) so the bake can't evaluate an exploded mesh.
_t = time.monotonic()
capped = 0
for o in meshes:
    for m in list(o.modifiers):
        if m.type in ("SUBSURF", "MULTIRES"):
            try:
                if m.render_levels > SUBSURF_MAX:
                    m.render_levels = SUBSURF_MAX
                    capped += 1
                if m.levels > SUBSURF_MAX:
                    m.levels = SUBSURF_MAX
            except Exception as e:  # noqa: BLE001 - a modifier quirk must not abort
                _log(f"cap failed on {o.name}/{m.type}: {e}")
_phase("cap", _t)

# (1b) FLATTEN MATERIALS. On 4Holdable2 the glTF exporter's material pass alone
# ran >20 min while the same export with materials stripped took 0.8s — huge
# procedural shader node-trees (car-paint packs & co) are the single biggest
# conversion cost, dwarfing geometry. The device renderer only reads glTF PBR
# factors + base-color PNG/JPEG anyway, so distill each material down to what
# survives the trip: base color, metallic/roughness, and the first image
# texture (logos/liveries), wired into a minimal Principled BSDF.
def _flatten_materials():
    flattened = 0
    for mat in bpy.data.materials:
        if not mat.use_nodes or mat.node_tree is None:
            continue
        base_color = None
        base_image = None
        metallic = None
        roughness = None
        seen = set()

        def scan(nt):
            nonlocal base_color, base_image, metallic, roughness
            if nt is None or nt.name in seen:
                return
            seen.add(nt.name)
            for n in nt.nodes:
                if n.type == "TEX_IMAGE" and n.image is not None \
                        and base_image is None:
                    base_image = n.image
                elif n.type == "BSDF_PRINCIPLED":
                    if base_color is None:
                        base_color = tuple(n.inputs["Base Color"].default_value)
                    if metallic is None:
                        metallic = float(n.inputs["Metallic"].default_value)
                    if roughness is None:
                        roughness = float(n.inputs["Roughness"].default_value)
                elif n.type == "GROUP":
                    if base_color is None:
                        for s in n.inputs:
                            if s.type == "RGBA" and "color" in s.name.lower():
                                base_color = tuple(s.default_value)
                                break
                    scan(n.node_tree)

        try:
            scan(mat.node_tree)
            if base_color is None:
                base_color = tuple(mat.diffuse_color)
            tree = mat.node_tree
            tree.nodes.clear()
            out_node = tree.nodes.new("ShaderNodeOutputMaterial")
            bsdf = tree.nodes.new("ShaderNodeBsdfPrincipled")
            bsdf.inputs["Base Color"].default_value = (
                base_color[0], base_color[1], base_color[2],
                base_color[3] if len(base_color) > 3 else 1.0)
            bsdf.inputs["Metallic"].default_value = metallic if metallic is not None else 0.0
            bsdf.inputs["Roughness"].default_value = roughness if roughness is not None else 0.6
            tree.links.new(bsdf.outputs["BSDF"], out_node.inputs["Surface"])
            if base_image is not None:
                tex = tree.nodes.new("ShaderNodeTexImage")
                tex.image = base_image
                tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
            flattened += 1
        except Exception as e:  # noqa: BLE001 - a weird tree must not abort
            _log(f"material flatten failed on {mat.name}: {e}")
    _log(f"flattened {flattened} materials")


_t = time.monotonic()
if os.environ.get("CONVERT_FLATTEN_MATERIALS", "1") != "0":
    _flatten_materials()
_phase("materials", _t)

# (2) Bake the modifier stack ONCE. preserve_all_data_layers keeps UVs/vertex data
# (so textures survive); the new mesh carries the material slots along.
_t = time.monotonic()
baked = 0
dg = bpy.context.evaluated_depsgraph_get()
for o in list(meshes):
    try:
        ev = o.evaluated_get(dg)
        new_mesh = bpy.data.meshes.new_from_object(
            ev, preserve_all_data_layers=True, depsgraph=dg)
        o.modifiers.clear()
        o.data = new_mesh
        baked += 1
    except Exception as e:  # noqa: BLE001 - never let one mesh abort the batch
        _log(f"bake failed on {o.name}: {e}")
_phase("bake", _t)

# Counts now come straight from the baked (static) meshes — no second evaluation.
eval_faces = {o: len(o.data.polygons) for o in meshes}
total_faces = sum(eval_faces.values())
_log(f"meshes={len(meshes)} baked={baked} faces={total_faces} "
    f"capped={capped} budget={TRI_BUDGET}")

# (3) Decimate to the budget, PROTECTING small meshes (logos/badges/trim): a single
# uniform ratio collapses a 1-2 face branded logo to nothing. Reduce only the heavy
# meshes (> DECIMATE_FLOOR faces) to whatever budget remains after keeping the small
# ones, so logos survive while the multi-100k-face body/wheel meshes carry the cut.
#
# Applied HERE, per mesh, timed — NOT deferred to the exporter's export_apply.
# Deferring made one degenerate mesh (Circle mirror seam, 673k faces) thrash
# COLLAPSE inside the export for ~24 min with no attribution. Now each heavy mesh
# is first cleaned (merge exact-duplicate verts + drop zero-area faces — the
# topology COLLAPSE chokes on), then decimated and re-baked static, with a
# [mesh] log line per mesh so any future hog is pinpointed by name.
MERGE_DIST = float(os.environ.get("CONVERT_MERGE_DIST", "1e-5"))
_t = time.monotonic()
decimated = False
if total_faces > TRI_BUDGET and total_faces > 0:
    heavy = [o for o in meshes if eval_faces.get(o, 0) > DECIMATE_FLOOR]
    if not heavy:  # pathological: budget exceeded only by many tiny meshes
        heavy = meshes
    heavy_faces = sum(eval_faces.get(o, 0) for o in heavy)
    kept_faces = total_faces - heavy_faces
    target = max(TRI_BUDGET - kept_faces, TRI_BUDGET // 4)
    ratio = max(0.005, min(1.0, target / heavy_faces)) if heavy_faces else 1.0
    _log(f"decimating {len(heavy)}/{len(meshes)} heavy meshes (>{DECIMATE_FLOOR}f): "
         f"heavy={heavy_faces} kept_small={kept_faces} target={target} "
         f"ratio={ratio:.4f}")
    for o in sorted(heavy, key=lambda h: -eval_faces.get(h, 0)):
        t0 = time.monotonic()
        before = len(o.data.polygons)
        try:
            bm = bmesh.new()
            bm.from_mesh(o.data)
            bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=MERGE_DIST)
            bmesh.ops.dissolve_degenerate(bm, edges=bm.edges[:], dist=MERGE_DIST)
            bm.to_mesh(o.data)
            bm.free()
        except Exception as e:  # noqa: BLE001 - clean is best-effort
            _log(f"clean failed on {o.name}: {e}")
        cleaned = len(o.data.polygons)
        t_clean = time.monotonic()
        try:
            mod = o.modifiers.new(name="hold_decimate", type="DECIMATE")
            mod.decimate_type = "COLLAPSE"
            mod.ratio = ratio
            dg = bpy.context.evaluated_depsgraph_get()
            ev = o.evaluated_get(dg)
            new_mesh = bpy.data.meshes.new_from_object(
                ev, preserve_all_data_layers=True, depsgraph=dg)
            o.modifiers.clear()
            old = o.data
            o.data = new_mesh
            if old.users == 0:
                bpy.data.meshes.remove(old)  # free the pre-decimate copy (8Gi cap)
        except Exception as e:  # noqa: BLE001 - never let one mesh abort the batch
            _log(f"decimate failed on {o.name}: {e}")
            o.modifiers.clear()
        after = len(o.data.polygons)
        line = (f"{o.name}: faces {before}->{cleaned}->{after} "
                f"clean={t_clean - t0:.1f}s decimate={time.monotonic() - t_clean:.1f}s")
        _mesh_log.append(line)
        _log(f"[mesh] {line}")
    decimated = True
_phase("decimate", _t)

# Write the diag BEFORE the (now cheap, but still) export, so a timeout there
# still leaves per-phase + per-mesh timings to read.
_write_diag(total_faces, baked, capped)

# Export as a single binary glTF. Every modifier has already been baked/applied
# above, so the export is a plain static-mesh walk — export_apply would only make
# the exporter re-run depsgraph evaluation per object for nothing. +Y up matches
# the renderer. (CONVERT_APPLY=1 re-enables it as an escape hatch, e.g. for a
# scene whose NON-mesh objects carry modifiers we don't bake.)
#
# CONVERT_EXPORT_MATERIALS: EXPORT (default) | PLACEHOLDER | NONE. Diagnostic +
# rescue knob — a scene full of huge procedural shader node-trees (car-paint
# packs etc.) can make the exporter's material pass itself the bottleneck; the
# device renderer only reads base-color PNG/JPEG anyway, so PLACEHOLDER trades
# materials for a conversion that lands.
apply = os.environ.get("CONVERT_APPLY", "0") == "1"
materials = os.environ.get("CONVERT_EXPORT_MATERIALS", "EXPORT")
_t = time.monotonic()
bpy.ops.export_scene.gltf(
    filepath=out,
    export_format="GLB",
    export_apply=apply,
    export_materials=materials,
    export_yup=True,
)
_phase("export", _t)
_write_diag(total_faces, baked, capped)  # rewrite with export timing (success path)
_log(f"done apply={apply} decimated={decimated} timings=[{' '.join(_timings)}]")

if not os.path.exists(out):
    raise SystemExit("export_scene.gltf wrote no file")
