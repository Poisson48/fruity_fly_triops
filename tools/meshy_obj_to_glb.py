#!/usr/bin/env python3
"""Convert Meshy textured OBJ → GLB for Godot MultiMesh.

Do NOT aggressively decimate: a previous ~4k-tri pass shattered the mesh
into visible triangle islands. Keep full topology + UVs.

Critical: trimesh PBR baseColorFactor must be uint8 0–255 (float 1.0 can
be mangled to ~0.004 and the model goes black in Godot).
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import trimesh
from PIL import Image
from trimesh.visual.material import PBRMaterial


def main() -> None:
	ap = argparse.ArgumentParser()
	ap.add_argument("obj", type=Path)
	ap.add_argument("--png", type=Path, default=None)
	ap.add_argument("--out-glb", type=Path, required=True)
	ap.add_argument("--out-png", type=Path, required=True)
	ap.add_argument("--max-tex", type=int, default=1024)
	args = ap.parse_args()

	png = args.png or args.obj.with_suffix(".png")
	if not png.exists():
		raise SystemExit(f"texture PNG not found: {png}")

	mesh = trimesh.load(args.obj, force="mesh", process=False)

	img = Image.open(png).convert("RGBA")
	if max(img.size) > args.max_tex:
		img = img.resize((args.max_tex, args.max_tex), Image.Resampling.LANCZOS)
	args.out_png.parent.mkdir(parents=True, exist_ok=True)
	img.save(args.out_png, optimize=True)

	mat = PBRMaterial()
	mat.baseColorTexture = img
	mat.baseColorFactor = np.array([255, 255, 255, 255], dtype=np.uint8)
	mat.metallicFactor = 0.0
	mat.roughnessFactor = 0.85
	mat.alphaMode = "OPAQUE"
	mat.doubleSided = True

	mesh.visual = trimesh.visual.texture.TextureVisuals(
		uv=np.asarray(mesh.visual.uv, dtype=np.float64), material=mat
	)
	mesh.fix_normals()
	mesh.apply_translation(-mesh.bounds.mean(axis=0))

	print(
		f"tris={len(mesh.faces)} verts={len(mesh.vertices)} "
		f"comps={len(mesh.split(only_watertight=False))} extents={mesh.extents}"
	)

	args.out_glb.parent.mkdir(parents=True, exist_ok=True)
	args.out_glb.write_bytes(
		trimesh.exchange.gltf.export_glb(
			trimesh.Scene(geometry={"triops": mesh}), include_normals=True
		)
	)
	print(f"wrote {args.out_glb} ({args.out_glb.stat().st_size} bytes) and {args.out_png}")


if __name__ == "__main__":
	main()
