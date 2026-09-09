#!/usr/bin/env python3
"""Rebuild map_motor inside an existing .ffc without re-parsing the CSV.

Selection:
  - SEZ / descending-like neuropils: GNG, SAD, AMMC, PRW, FLA, IPS (+ light LAL/VES)
  - Rank by synaptic in-weight from visual maps (ME/LO/LOP)
  - Pack channels for 5-way readout:
      [forward | vertical | yaw_L | pitch | yaw_R]
    so yaw = mean(yaw_L) - mean(yaw_R) in the motor shader / CPU reader.
"""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path


def read_list(f) -> list[int]:
    (n,) = struct.unpack("<I", f.read(4))
    if n == 0:
        return []
    return list(struct.unpack(f"<{n}i", f.read(n * 4)))


def write_list(f, lst: list[int]) -> None:
    f.write(struct.pack("<I", len(lst)))
    if lst:
        f.write(struct.pack(f"<{len(lst)}i", *lst))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ffc", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--motor-count", type=int, default=80)
    args = ap.parse_args()
    out = args.out or args.ffc

    data = args.ffc.read_bytes()
    magic = data[:4]
    if magic != b"FFC1":
        raise SystemExit(f"bad magic {magic!r}")

    n, m, n_np, _flags = struct.unpack_from("<IIII", data, 4)
    off = 20
    primary_np = []
    for _ in range(n):
        _fid, pnp, _res = struct.unpack_from("<QHH", data, off)
        primary_np.append(pnp)
        off += 12

    neuropil_names: list[str] = []
    for _ in range(n_np):
        (ln,) = struct.unpack_from("<H", data, off)
        off += 2
        name = data[off : off + ln].decode("utf-8")
        off += ln
        neuropil_names.append(name)

    offsets = list(struct.unpack_from(f"<{n + 1}i", data, off))
    off += (n + 1) * 4
    targets = list(struct.unpack_from(f"<{m}i", data, off))
    off += m * 4
    weights = list(struct.unpack_from(f"<{m}f", data, off))
    off += m * 4

    # Remaining is four index lists — parse via memoryview cursor.
    rest = memoryview(data)[off:]

    def take_list(buf: memoryview) -> tuple[list[int], memoryview]:
        (cnt,) = struct.unpack_from("<I", buf, 0)
        payload = buf[4 : 4 + cnt * 4]
        lst = list(struct.unpack(f"<{cnt}i", payload)) if cnt else []
        return lst, buf[4 + cnt * 4 :]

    left, rest = take_list(rest)
    right, rest = take_list(rest)
    median, rest = take_list(rest)
    _old_motor, rest = take_list(rest)
    header_and_csr = data[:off]

    visual = set(left) | set(right) | set(median)
    left_set = set(left)
    right_set = set(right)
    median_set = set(median)

    # In-weight from visual sources → candidate motor cells.
    in_vis = [0.0] * n
    in_l = [0.0] * n
    in_r = [0.0] * n
    in_m = [0.0] * n
    for src in visual:
        a = offsets[src]
        b = offsets[src + 1]
        for e in range(a, b):
            tgt = targets[e]
            w = abs(weights[e])
            in_vis[tgt] += w
            if src in left_set:
                in_l[tgt] += w
            if src in right_set:
                in_r[tgt] += w
            if src in median_set:
                in_m[tgt] += w

    sez_prefixes = (
        "GNG",
        "SAD",
        "AMMC",
        "PRW",
        "FLA",
        "IPS",
        "LAL",
        "VES",
    )

    def is_sez(i: int) -> bool:
        pnp = primary_np[i]
        if pnp == 0xFFFF or pnp >= len(neuropil_names):
            return False
        name = neuropil_names[pnp]
        return any(name == p or name.startswith(p) for p in sez_prefixes)

    candidates = [i for i in range(n) if is_sez(i) and in_vis[i] > 0.0]
    if len(candidates) < args.motor_count:
        # Fallback: any SEZ by out-degree, then visual hubs.
        extra = [i for i in range(n) if is_sez(i) and i not in candidates]
        extra.sort(key=lambda i: offsets[i + 1] - offsets[i], reverse=True)
        candidates.extend(extra)
    if len(candidates) < args.motor_count:
        hubs = sorted(range(n), key=lambda i: in_vis[i], reverse=True)
        for i in hubs:
            if i not in candidates:
                candidates.append(i)
            if len(candidates) >= args.motor_count * 3:
                break

    # Prefer high visual in-weight; break ties by out-degree.
    candidates = sorted(
        set(candidates),
        key=lambda i: (in_vis[i], offsets[i + 1] - offsets[i]),
        reverse=True,
    )

    per = max(1, args.motor_count // 5)
    yaw_l = sorted(
        candidates,
        key=lambda i: (in_l[i] - in_r[i], in_vis[i]),
        reverse=True,
    )[:per]
    used = set(yaw_l)
    yaw_r = sorted(
        (i for i in candidates if i not in used),
        key=lambda i: (in_r[i] - in_l[i], in_vis[i]),
        reverse=True,
    )[:per]
    used |= set(yaw_r)
    vertical = sorted(
        (i for i in candidates if i not in used),
        key=lambda i: (in_m[i], in_vis[i]),
        reverse=True,
    )[:per]
    used |= set(vertical)
    forward = sorted(
        (i for i in candidates if i not in used),
        key=lambda i: in_vis[i],
        reverse=True,
    )[:per]
    used |= set(forward)
    pitch = sorted(
        (i for i in candidates if i not in used),
        key=lambda i: (in_m[i] * 0.5 + in_vis[i],),
        reverse=True,
    )[:per]

    motor = forward + vertical + yaw_l + pitch + yaw_r
    # Pad / trim to exact motor_count (5*per may be < motor_count if not divisible).
    if len(motor) < args.motor_count:
        for i in candidates:
            if i not in motor:
                motor.append(i)
            if len(motor) >= args.motor_count:
                break
    motor = motor[: args.motor_count]

    print(
        f"motor={len(motor)} per_channel={per} "
        f"fwd_vis={sum(in_vis[i] for i in forward):.1f} "
        f"yawL_bias={sum(in_l[i]-in_r[i] for i in yaw_l):.1f} "
        f"yawR_bias={sum(in_r[i]-in_l[i] for i in yaw_r):.1f}"
    )

    with out.open("wb") as f:
        f.write(header_and_csr)
        write_list(f, left)
        write_list(f, right)
        write_list(f, median)
        write_list(f, motor)

    side_path = Path(str(out) + ".json")
    if side_path.exists():
        side = json.loads(side_path.read_text(encoding="utf-8"))
    else:
        side = {"provenance": {}}
    prov = side.setdefault("provenance", {})
    em = prov.setdefault("eye_mapping", {})
    em["motor"] = (
        "SEZ (GNG/SAD/AMMC/PRW/FLA/IPS/LAL/VES) ranked by in-weight from ME/LO/LOP; "
        "packed [forward|vertical|yaw_L|pitch|yaw_R] for L−R yaw readout"
    )
    em["motor_count"] = len(motor)
    em["motor_layout"] = {
        "forward": [0, per],
        "vertical": [per, 2 * per],
        "yaw_L": [2 * per, 3 * per],
        "pitch": [3 * per, 4 * per],
        "yaw_R": [4 * per, 5 * per],
        "yaw_channel": "mean(yaw_L) - mean(yaw_R)",
    }
    em["note"] = (
        "Uses real FlyWire neuropil anatomy as Triops↔fly interface scaffold; "
        "not validated descending neuron IDs (DNp)."
    )
    side_path.write_text(json.dumps(side, indent=2), encoding="utf-8")
    print(f"Wrote {out} ({out.stat().st_size / 1e6:.1f} MB) + {side_path.name}")


if __name__ == "__main__":
    main()
