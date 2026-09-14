# Triops model (Meshy)

Ship: **`triops.glb`** + **`triops_0.png`** — welded + ~28k-tri LOD (512² texture) for MultiMesh FPS.

## Perf notes

Full Meshy OBJ is ~113k tris; runtime ships a **~28k** bake (still textured) so Easy (12–40 agents) stays ≥30 FPS on Intel UHD.
Do **not** push below ~14k with naive decimate — that shatters topology.

Rebuild:

```bash
python tools/meshy_obj_to_glb.py /path/to/Meshy_*.obj \
  --out-glb assets/models/triops.glb \
  --out-png assets/models/triops_0.png \
  --max-tex 512 --faces 28000
```

## Conventions

- **Up:** Y-up
- **Forward:** Godot **−Z** (`TriopsVisual.model_basis` = 180° yaw)
- **Pivot:** bbox center
- **Scale:** `VISUAL_MODEL_SCALE = 2.5`
- Fallback: debug sphere if `triops.glb` missing
