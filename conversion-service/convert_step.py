"""Run inside headless FreeCAD:

    CONVERT_IN=<step/iges> CONVERT_OUT=<out.stl> freecadcmd convert_step.py

Reads a STEP/IGES B-rep (OpenCASCADE) and tessellates it to a triangle mesh
(.stl). A Blender pass then turns the .stl into the .glb the app wants. Paths
come from env vars to avoid freecadcmd's argv quirks.
"""

import os

import Part
import MeshPart

inp = os.environ["CONVERT_IN"]
out = os.environ["CONVERT_OUT"]

shape = Part.Shape()
shape.read(inp)  # STEP / IGES, via OpenCASCADE

# Tessellate the solid. LinearDeflection drives triangle density (smaller = finer
# but heavier); these values are a reasonable default for viewing.
mesh = MeshPart.meshFromShape(
    Shape=shape,
    LinearDeflection=0.1,
    AngularDeflection=0.523599,  # 30 deg
    Relative=False,
)
mesh.write(out)

if not os.path.exists(out):
    raise SystemExit("FreeCAD wrote no mesh")
