#!/usr/bin/env bash
# Run Fruity Fly Triops smoke suite without an interactive display.
#
# Default: Xvfb + Vulkan (Godot --headless alone forces dummy renderer = CPU only).
# Usage:
#   ./tools/run_tests.sh              # GPU via Xvfb
#   ./tools/run_tests.sh --cpu        # true Godot --headless (CPU LIF)
#   ./tools/run_tests.sh res://scripts/debug/behavior_smoke.gd
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT=(flatpak run org.godotengine.Godot)
MODE=gpu
SCRIPT="res://scripts/debug/headless_suite.gd"

for arg in "$@"; do
  case "$arg" in
    --cpu) MODE=cpu ;;
    --gpu) MODE=gpu ;;
    res://*) SCRIPT="$arg" ;;
    *) SCRIPT="$arg" ;;
  esac
done

export GODOT_SILENCE_ROOT_WARNING=1
if [[ "$MODE" == "cpu" ]]; then
  cmd=("${GODOT[@]}" --path "$ROOT" --headless -s "$SCRIPT")
else
  cmd=(xvfb-run -a -s "-screen 0 1280x720x24" "${GODOT[@]}" --path "$ROOT" --display-driver x11 --audio-driver Dummy -s "$SCRIPT")
fi
echo "+ ${cmd[*]}"
exec "${cmd[@]}"
