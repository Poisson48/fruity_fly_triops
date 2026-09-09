#!/usr/bin/env python3
"""Build a compact binary FlyWire connectome for Godot (.ffc).

Format (.ffc little-endian):
  magic: b'FFC1'
  u32 neuron_count
  u32 synapse_count
  u32 neuropil_count
  u32 flags
  For each neuron: u64 flywire_id, u16 primary_neuropil_index, u16 reserved
  neuropil names: for each, u16 len + utf8
  CSR outgoing: i32 offsets[n+1], i32 targets[m], f32 weights[m]
  mapping lists: u32 count + i32 indices  (left, right, median, motor)
"""

from __future__ import annotations

import argparse
import collections
import csv
import gzip
import json
import struct
from pathlib import Path


def open_text(path: Path):
    if str(path).endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", newline="")
    return path.open("rt", encoding="utf-8", newline="")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--min-synapses", type=int, default=5)
    ap.add_argument("--max-edges", type=int, default=0)
    ap.add_argument("--dataset", default="flywire_fafb_v783_connections_princeton")
    ap.add_argument(
        "--citation",
        default="Dorkenwald et al., Nature 2024; FlyWire Codex connections_princeton",
    )
    args = ap.parse_args()

    print("Scanning…")
    edges: list[tuple[str, str, float, str, str]] = []
    with open_text(args.csv) as f:
        r = csv.DictReader(f)
        for row in r:
            w = float(row["syn_count"])
            if w < args.min_synapses:
                continue
            edges.append(
                (
                    str(int(float(row["pre_root_id"]))),
                    str(int(float(row["post_root_id"]))),
                    w,
                    row.get("neuropil", "") or "",
                    (row.get("nt_type", "") or "").upper(),
                )
            )
            if args.max_edges and len(edges) >= args.max_edges:
                break
    print(f"edges kept: {len(edges)}")

    id_map: dict[str, int] = {}
    fly_ids: list[str] = []

    def nid(x: str) -> int:
        if x not in id_map:
            id_map[x] = len(id_map)
            fly_ids.append(x)
        return id_map[x]

    outs: list[list[tuple[int, float]]] = []
    neuron_np_count: list[collections.Counter] = []
    neuropil_names: list[str] = []
    neuropil_index: dict[str, int] = {}

    def np_id(name: str) -> int:
        if not name:
            return 0xFFFF
        if name not in neuropil_index:
            neuropil_index[name] = len(neuropil_names)
            neuropil_names.append(name)
        return neuropil_index[name]

    def ensure(i: int) -> None:
        while len(outs) <= i:
            outs.append([])
        while len(neuron_np_count) <= i:
            neuron_np_count.append(collections.Counter())

    for s, t, w, npv, nt in edges:
        si, ti = nid(s), nid(t)
        ensure(max(si, ti))
        if npv:
            np_id(npv)
            neuron_np_count[si][npv] += w
            neuron_np_count[ti][npv] += w
        sign = -1.0 if nt == "GABA" else 1.0
        weight = sign * min(w / 25.0, 3.0)
        outs[si].append((ti, weight))

    n = len(fly_ids)
    ensure(n - 1)
    primary_np = []
    for i in range(n):
        if neuron_np_count[i]:
            name = neuron_np_count[i].most_common(1)[0][0]
            primary_np.append(neuropil_index[name])
        else:
            primary_np.append(0xFFFF)

    offsets = [0]
    targets: list[int] = []
    weights: list[float] = []
    for i in range(n):
        for t, w in outs[i]:
            targets.append(t)
            weights.append(w)
        offsets.append(len(targets))
    m = len(targets)
    print(f"neurons={n} synapses={m} neuropils={len(neuropil_names)}")

    def collect(prefixes: tuple[str, ...], limit: int) -> list[int]:
        hits = []
        for i, pnp in enumerate(primary_np):
            if pnp == 0xFFFF:
                continue
            name = neuropil_names[pnp]
            if any(name == px or name.startswith(px) for px in prefixes):
                hits.append(i)
        hits.sort(key=lambda i: offsets[i + 1] - offsets[i], reverse=True)
        return hits[:limit]

    left = collect(("ME_L", "LO_L"), 256)
    right = collect(("ME_R", "LO_R"), 256)
    median = collect(("LOP_L", "LOP_R"), 256)
    motor = collect(("GNG", "SAD"), 128)
    if len(motor) < 32:
        deg = sorted(range(n), key=lambda i: offsets[i + 1] - offsets[i], reverse=True)
        motor = deg[:128]
    print(f"map L={len(left)} R={len(right)} M={len(median)} motor={len(motor)}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("wb") as f:
        f.write(b"FFC1")
        f.write(struct.pack("<IIII", n, m, len(neuropil_names), 0))
        for i in range(n):
            fid = int(fly_ids[i]) & ((1 << 64) - 1)
            f.write(struct.pack("<QHH", fid, primary_np[i] & 0xFFFF, 0))
        for name in neuropil_names:
            b = name.encode("utf-8")
            f.write(struct.pack("<H", len(b)))
            f.write(b)
        f.write(struct.pack(f"<{n + 1}i", *offsets))
        f.write(struct.pack(f"<{m}i", *targets))
        f.write(struct.pack(f"<{m}f", *weights))

        def write_list(lst: list[int]) -> None:
            f.write(struct.pack("<I", len(lst)))
            if lst:
                f.write(struct.pack(f"<{len(lst)}i", *lst))

        write_list(left)
        write_list(right)
        write_list(median)
        write_list(motor)

    side = {
        "provenance": {
            "kind": "flywire",
            "dataset": args.dataset,
            "citation": args.citation,
            "source_file": str(args.csv),
            "min_synapses": args.min_synapses,
            "neuron_count": n,
            "synapse_count": m,
            "neuropil_count": len(neuropil_names),
            "binary": str(args.out.name),
            "format": "FFC1",
            "coverage": "all neuropils from connections_princeton above synapse threshold",
            "eye_mapping": {
                "left": "ME_L/LO_L primary neuropil neurons",
                "right": "ME_R/LO_R",
                "median": "LOP_L/LOP_R",
                "motor": "GNG/SAD or top out-degree",
                "note": "Uses real FlyWire visual neuropil anatomy as Triops interface scaffold.",
            },
        }
    }
    side_path = Path(str(args.out) + ".json")
    side_path.write_text(json.dumps(side, indent=2), encoding="utf-8")
    print(f"Wrote {args.out} ({args.out.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
