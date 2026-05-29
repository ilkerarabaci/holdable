# Forkable / Study-able GitHub Repos (alpha priorities)

| Repo | What to take from it | License |
|---|---|---|
| **[google/model-viewer](https://github.com/google/model-viewer)** | The web component we're wrapping. Study AR launcher logic, gesture handling, shader presets. | Apache-2.0 |
| **[the3deer/android-3D-model-viewer](https://github.com/the3deer/android-3D-model-viewer)** | 1.6k★. Native Android STL/OBJ parser logic, gesture controls. Port concepts to Flutter. | MIT |
| **[donmccurdy/three-gltf-viewer](https://github.com/donmccurdy/three-gltf-viewer)** | Drag-drop UX for 3D viewers. Could embed via WebView for premium features. | MIT |
| **[playcanvas/model-viewer](https://github.com/playcanvas/model-viewer)** | 1.5k★. UI/UX inspiration. Polished web viewer. | MIT |
| **[nmfisher/thermion](https://github.com/nmfisher/thermion)** | Plan B if model_viewer_plus performance is unacceptable. Native Filament Flutter bindings. Their example app = starter scaffold. | MIT |
| **[dbrant/ModelViewer3D](https://github.com/dbrant/ModelViewer3D)** | Minimal Android STL/OBJ/PLY reference. | (check repo) |

**Three.js loaders in WebView** — we'll likely need to inject these into model_viewer_plus's WebView for OBJ/STL → glTF conversion:
- [three.js OBJLoader](https://threejs.org/docs/#examples/en/loaders/OBJLoader)
- [three.js STLLoader](https://threejs.org/docs/#examples/en/loaders/STLLoader)
- [three.js GLTFExporter](https://threejs.org/docs/#examples/en/exporters/GLTFExporter)

**CC0 sample models for `assets/sample_models/`:**
- [Poly Haven](https://polyhaven.com) — CC0, .gltf/.fbx/.obj
- [NASA 3D](https://science.nasa.gov/3d-resources/) — public domain
- [Smithsonian 3D](https://3d.si.edu) — CC0

Bundle 3-5 curated samples, max 5MB each. Aim for: 1 organic (vase), 1 mechanical (bracket), 1 archicultural-ish (chair).
