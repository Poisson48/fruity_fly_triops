#!/usr/bin/env python3
"""Import FlyWire/Codex connection CSV (.csv or .csv.gz) into project JSON.

Remaps 64-bit root IDs to dense indices (JSON numbers cannot safely store
FlyWire root IDs). Does NOT invent biological connectivity.

Example:
  python3 tools/import_connectome_csv.py \\
    --csv ressources/connections_princeton.csv.gz \\
    --out data/brains/flywire_fafb_visual_subset.json \\
    --dataset flywire_fafb_v783 \\
    --citation "Dorkenwald et al., Nature 2024; FlyWire Codex connections_princeton" \\
    --kind flywire \\
    --max-edges 8000 \\
    --neuropils ME_L,ME_R,LO_L,LO_R,LOP_L,LOP_R \\
    --min-synapses 5
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
from collections import defaultdict
from pathlib import Path


def open_text(path: Path):
    if str(path).endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", newline="")
    return path.open("rt", encoding="utf-8", newline="")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--csv", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--dataset", required=True)
    p.add_argument("--citation", required=True)
    p.add_argument("--kind", default="flywire")
    p.add_argument("--max-edges", type=int, default=8000)
    p.add_argument("--min-synapses", type=int, default=5)
    p.add_argument(
        "--neuropils",
        default="ME_L,ME_R,LO_L,LO_R,LOP_L,LOP_R",
        help="Comma-separated neuropil filter (empty = all)",
    )
    p.add_argument("--source-col", default="")
    p.add_argument("--target-col", default="")
    p.add_argument("--weight-col", default="")
    args = p.parse_args()

    neuropil_filter = {x.strip() for x in args.neuropils.split(",") if x.strip()}

    with open_text(args.csv) as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            raise SystemExit("CSV has no header")
        fields = {name.lower(): name for name in reader.fieldnames}

        def pick(*cands: str) -> str:
            for c in cands:
                if c.lower() in fields:
                    return fields[c.lower()]
            return ""

        src_c = args.source_col or pick("source", "pre", "pre_root_id", "bodyId_pre")
        tgt_c = args.target_col or pick("target", "post", "post_root_id", "bodyId_post")
        w_c = args.weight_col or pick("weight", "synapses", "syn_count", "roi_weight", "count")
        np_c = pick("neuropil", "roi", "region")
        nt_c = pick("nt_type", "neurotransmitter", "nt")
        if not src_c or not tgt_c:
            raise SystemExit(f"Cannot find source/target columns in {reader.fieldnames}")

        # Collect candidate edges (filter first, keep strongest).
        candidates: list[tuple[float, str, str, str, str]] = []
        scanned = 0
        for row in reader:
            scanned += 1
            if neuropil_filter and np_c:
                npv = (row.get(np_c) or "").strip()
                if npv not in neuropil_filter:
                    continue
            try:
                s = str(int(float(row[src_c])))
                t = str(int(float(row[tgt_c])))
            except (KeyError, ValueError):
                continue
            w = 1.0
            if w_c and row.get(w_c, "") != "":
                try:
                    w = float(row[w_c])
                except ValueError:
                    w = 1.0
            if w < args.min_synapses:
                continue
            nt = (row.get(nt_c) or "") if nt_c else ""
            npv = (row.get(np_c) or "") if np_c else ""
            candidates.append((w, s, t, npv, nt))

    # Prefer strong synapses.
    candidates.sort(key=lambda x: x[0], reverse=True)
    selected = candidates[: args.max_edges]

    id_map: dict[str, int] = {}
    neurons: list[dict] = []
    connections: list[dict] = []
    out_degree: dict[int, int] = defaultdict(int)
    in_degree: dict[int, int] = defaultdict(int)
    visual_pre: set[int] = set()
    visual_post: set[int] = set()

    def nid(root: str) -> int:
        if root not in id_map:
            id_map[root] = len(id_map)
            neurons.append({"id": id_map[root], "flywire_id": root})
        return id_map[root]

    for w, s, t, npv, nt in selected:
        si = nid(s)
        ti = nid(t)
        # Sign: GABA inhibitory heuristic from nt_type (documented, not invented topology).
        sign = -1.0 if str(nt).upper() == "GABA" else 1.0
        weight = sign * min(w / 20.0, 2.0)
        conn = {
            "source": si,
            "target": ti,
            "weight": weight,
            "synapses": w,
        }
        if npv:
            conn["neuropil"] = npv
        if nt:
            conn["nt_type"] = nt
        connections.append(conn)
        out_degree[si] += 1
        in_degree[ti] += 1
        if npv.startswith("ME") or npv.startswith("LO"):
            visual_pre.add(si)
            visual_post.add(ti)

    # Experimental Triops interface (NOT claimed biological mapping):
    # drive visual-pathway neurons; read high out-degree nodes as motor proxies.
    ranked_in = sorted(visual_post or in_degree.keys(), key=lambda i: in_degree[i], reverse=True)
    ranked_out = sorted(out_degree.keys(), key=lambda i: out_degree[i], reverse=True)
    input_ids = ranked_in[:9]
    # Prefer outputs not overlapping inputs.
    output_ids = []
    for i in ranked_out:
        if i not in input_ids:
            output_ids.append(i)
        if len(output_ids) >= 5:
            break
    while len(output_ids) < 5 and ranked_out:
        output_ids.append(ranked_out[len(output_ids) % len(ranked_out)])
        if len(output_ids) >= 5:
            break

    payload = {
        "provenance": {
            "kind": args.kind,
            "dataset": args.dataset,
            "citation": args.citation,
            "source_file": str(args.csv),
            "rows_scanned": scanned,
            "candidates": len(candidates),
            "edge_count": len(connections),
            "neuron_count": len(neurons),
            "neuropil_filter": sorted(neuropil_filter),
            "min_synapses": args.min_synapses,
            "id_mapping": "dense_index_with_flywire_id_string",
            "note": (
                "Real FlyWire connectivity subset. "
                "input_neuron_ids/output_neuron_ids are EXPERIMENTAL Triops interface "
                "placeholders — not validated biological sensory/motor mappings. "
                "Connectome ≠ complete brain simulation."
            ),
        },
        "neurons": neurons,
        "connections": connections,
        "input_neuron_ids": input_ids,
        "output_neuron_ids": output_ids,
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    print(
        f"Wrote {args.out} ({len(neurons)} neurons, {len(connections)} edges, "
        f"scanned={scanned}, candidates={len(candidates)})"
    )
    print(f"inputs={input_ids}")
    print(f"outputs={output_ids}")


if __name__ == "__main__":
    main()
