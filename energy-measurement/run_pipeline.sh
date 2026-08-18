#!/usr/bin/env bash

set -euo pipefail

RUN_NUM="${1:?run number required (e.g. 1)}"
PROJECT_NAME="torchvision"
IMAGE_NAME="${IMAGE_NAME:-torchvision-medicao}"
MEDICAO_DIR="$HOME/experimentos/medicao/repositorios/vision"
RESULTS_DIR="${RESULTS_DIR:-$HOME/experimentos/medicao/resultados/torchvision/runs}"
RAPL_BASE="/sys/class/powercap/intel-rapl"
# Idle baseline measured before each run; its per-second rate is subtracted
# from every stage so reported energy reflects workload above idle.
BASELINE_DURATION=120
TIME_FILE="/tmp/torchvision_time_$$.txt"
CSV_FILE="$RESULTS_DIR/run_$(printf '%02d' "$RUN_NUM").csv"
EXITS_FILE="$RESULTS_DIR/exit_codes_run_$(printf '%02d' "$RUN_NUM").txt"

PIPELINE_EXIT=0
FAILED_STAGES=""

MEM_LIMIT="${MEM_LIMIT:-14g}"
MEM_SWAP="${MEM_SWAP:-$MEM_LIMIT}"

MAX_JOBS="${MAX_JOBS:-}"

SWAP_WARN_PAGES="${SWAP_WARN_PAGES:-256}"

mkdir -p "$RESULTS_DIR"

LOGS_DIR="${LOGS_DIR:-$HOME/experimentos/medicao/resultados/torchvision/logs}"
mkdir -p "$LOGS_DIR"

if [ ! -d "$RAPL_BASE" ]; then
  echo "RAPL not available at $RAPL_BASE" >&2
  exit 1
fi

if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "Docker image '$IMAGE_NAME' not found." >&2
  echo "   Construa primeiro:" >&2
  echo "   docker build -t $IMAGE_NAME -f $MEDICAO_DIR/Dockerfile \\" >&2
  echo "     ~/experimentos/repositorios/inference-only/vision/" >&2
  exit 1
fi

if ! docker run --rm --network none "$IMAGE_NAME" bash -c \
       'W=/root/.cache/torch/hub/checkpoints/resnet50-11ad3fa6.pth; test -f "$W" && [ "$(stat -c%s "$W")" -gt 94000000 ]'; then
  echo "Image '$IMAGE_NAME' does NOT contain the pre-baked resnet50 weights." >&2
  echo "   O smoke_test.py morreria sob --network none. Reconstrua a imagem." >&2
  exit 1
fi

if ! docker run --rm --network none "$IMAGE_NAME" \
       conda run -n ci python -c "import torch, torchvision; assert torch.ops.torchvision.nms is not None" 2>/dev/null; then
  echo "torchvision in image '$IMAGE_NAME' does not load the C++ extension." >&2
  echo "   O stage 'test' falharia com 'operator torchvision::nms does not exist'." >&2
  echo "   Reconstrua a imagem (ver Dockerfile, GATE 2)." >&2
  exit 1
fi

: > "$EXITS_FILE"

read_rapl() {
  local domain_name="$1"
  local value=0
  for dir in "$RAPL_BASE"/*/; do
    local name_file="$dir/name"
    [ -f "$name_file" ] || continue
    local name
    name=$(cat "$name_file")
    if [[ "$name" == "package-0" && "$domain_name" == "pkg" ]] || \
       [[ "$name" == "core"      && "$domain_name" == "cores" ]] || \
       [[ "$name" == "uncore"    && "$domain_name" == "gpu" ]] || \
       [[ "$name" == "dram"      && "$domain_name" == "ram" ]]; then
      local energy_file="$dir/energy_uj"
      [ -f "$energy_file" ] && value=$(cat "$energy_file") && break
    fi
    for subdir in "$dir"*/; do
      local sub_name_file="$subdir/name"
      [ -f "$sub_name_file" ] || continue
      local sub_name
      sub_name=$(cat "$sub_name_file")
      if [[ "$sub_name" == "core"   && "$domain_name" == "cores" ]] || \
         [[ "$sub_name" == "uncore" && "$domain_name" == "gpu" ]] || \
         [[ "$sub_name" == "dram"   && "$domain_name" == "ram" ]]; then
        local sub_energy="$subdir/energy_uj"
        [ -f "$sub_energy" ] && value=$(cat "$sub_energy") && break 2
      fi
    done
  done
  echo "$value"
}

read_rapl_max() {
  local domain_name="$1"
  local value=0
  for dir in "$RAPL_BASE"/*/; do
    local name_file="$dir/name"
    [ -f "$name_file" ] || continue
    local name
    name=$(cat "$name_file")
    if [[ "$name" == "package-0" && "$domain_name" == "pkg" ]]; then
      local max_file="$dir/max_energy_range_uj"
      [ -f "$max_file" ] && value=$(cat "$max_file") && break
    fi
    for subdir in "$dir"*/; do
      local sub_name_file="$subdir/name"
      [ -f "$sub_name_file" ] || continue
      local sub_name
      sub_name=$(cat "$sub_name_file")
      if [[ "$sub_name" == "core"   && "$domain_name" == "cores" ]] || \
         [[ "$sub_name" == "uncore" && "$domain_name" == "gpu" ]] || \
         [[ "$sub_name" == "dram"   && "$domain_name" == "ram" ]]; then
        local sub_max="$subdir/max_energy_range_uj"
        [ -f "$sub_max" ] && value=$(cat "$sub_max") && break 2
      fi
    done
  done
  [ "$value" -eq 0 ] && value=999999999999
  echo "$value"
}

# RAPL counters wrap at max_energy_range_uj; deltas are overflow-corrected.
delta_uj() {
  local ini="$1" fin="$2" max="$3"
  if [ "$fin" -ge "$ini" ]; then
    echo $(( fin - ini ))
  else
    echo $(( max - ini + fin ))
  fi
}

echo ""
echo ""
echo " Run $RUN_NUM - $PROJECT_NAME"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "⏳ Repouso para baseline (${BASELINE_DURATION}s)..."

b_pkg_ini=$(read_rapl pkg)
b_cores_ini=$(read_rapl cores)
b_gpu_ini=$(read_rapl gpu)
b_ram_ini=$(read_rapl ram)

sleep "$BASELINE_DURATION"

b_pkg_fin=$(read_rapl pkg)
b_cores_fin=$(read_rapl cores)
b_gpu_fin=$(read_rapl gpu)
b_ram_fin=$(read_rapl ram)

max_pkg=$(read_rapl_max pkg)
max_cores=$(read_rapl_max cores)
max_gpu=$(read_rapl_max gpu)
max_ram=$(read_rapl_max ram)

b_delta_pkg=$(delta_uj "$b_pkg_ini" "$b_pkg_fin" "$max_pkg")
b_delta_cores=$(delta_uj "$b_cores_ini" "$b_cores_fin" "$max_cores")
b_delta_gpu=$(delta_uj "$b_gpu_ini" "$b_gpu_fin" "$max_gpu")
b_delta_ram=$(delta_uj "$b_ram_ini" "$b_ram_fin" "$max_ram")

taxa_pkg=$(awk  "BEGIN {printf \"%.6f\", $b_delta_pkg  / $BASELINE_DURATION}")
taxa_cores=$(awk "BEGIN {printf \"%.6f\", $b_delta_cores / $BASELINE_DURATION}")
taxa_gpu=$(awk  "BEGIN {printf \"%.6f\", $b_delta_gpu  / $BASELINE_DURATION}")
taxa_ram=$(awk  "BEGIN {printf \"%.6f\", $b_delta_ram  / $BASELINE_DURATION}")

echo " Baseline calculado:"
echo "   pkg:   $(awk "BEGIN {printf \"%.2f\", $taxa_pkg / 1e6}") W"
echo "   cores: $(awk "BEGIN {printf \"%.2f\", $taxa_cores / 1e6}") W"
echo "   ram:   $(awk "BEGIN {printf \"%.2f\", $taxa_ram / 1e6}") W"

echo "run,stage,energy_pkg_j,energy_cores_j,energy_gpu_j,energy_ram_j,wall_time_s,user_time_s,sys_time_s,energy_ram_liquid_raw_j,wall_time_container_s,swap_in_pages,swap_out_pages" \
  > "$CSV_FILE"

total_pkg=0; total_cores=0; total_gpu=0; total_ram=0; total_ram_raw=0
total_wall=0; total_user=0; total_sys=0; total_wall_container=0
total_swap_in=0; total_swap_out=0

measure_stage() {
  local stage="$1"
  echo ""
  echo " Stage: $stage - $(date '+%H:%M:%S')"

  local timing_dir
  timing_dir=$(mktemp -d)

  local ini_pkg ini_cores ini_gpu ini_ram
  ini_pkg=$(read_rapl pkg)
  ini_cores=$(read_rapl cores)
  ini_gpu=$(read_rapl gpu)
  ini_ram=$(read_rapl ram)

  local pswpin_ini pswpout_ini
  pswpin_ini=$(awk '/^pswpin/{print $2}' /proc/vmstat)
  pswpout_ini=$(awk '/^pswpout/{print $2}' /proc/vmstat)

  local stage_log="$LOGS_DIR/run_$(printf '%02d' "$RUN_NUM")_${stage}.log"
  local stage_exit=0
  set +e
  /usr/bin/time -f "%e" -o "$TIME_FILE" \
    # --network none: all inputs are pre-baked into the image; measured energy
    # must not include network traffic (construct definition).
    docker run --rm --privileged --network none \
      --memory="$MEM_LIMIT" --memory-swap="$MEM_SWAP" \
      -v "$MEDICAO_DIR:/medicao:ro" \
      -v "$timing_dir:/timing" \
      -e "STAGE=$stage" \
      --add-host sourceforge.net:127.0.0.1 \
      --add-host drive.google.com:127.0.0.1 \
      ${MAX_JOBS:+-e "MAX_JOBS=$MAX_JOBS"} \
      "$IMAGE_NAME" \
      bash -c 'exec 3>&2; TIMEFORMAT="%R %U %S"; { time bash /medicao/commands.sh "$STAGE" 2>&3; } 2>/timing/time.txt' \
  # fd3 preserves the workload stderr while `time` captures wall/user/sys
  # inside the container, so child CPU time is attributed to the stage.
      2>&1 | tee "$stage_log"
  stage_exit=${PIPESTATUS[0]}
  set -e
  echo "    log do stage em $stage_log"

  echo "$RUN_NUM,$stage,$stage_exit" >> "$EXITS_FILE"
  if [ "$stage_exit" -ne 0 ]; then
    echo "  stage '$stage': container exited with exit=$stage_exit (measurement PRESERVED, see $EXITS_FILE)"
    PIPELINE_EXIT="$stage_exit"
    FAILED_STAGES="${FAILED_STAGES:+$FAILED_STAGES }$stage(exit=$stage_exit)"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "::warning title=Stage exited non-zero::Run $RUN_NUM, stage '$stage': exit=$stage_exit. The CSV row WAS written."
    fi
  else
    echo "    etapa '$stage': container saiu com exit=0"
  fi

  local fin_pkg fin_cores fin_gpu fin_ram
  fin_pkg=$(read_rapl pkg)
  fin_cores=$(read_rapl cores)
  fin_gpu=$(read_rapl gpu)
  fin_ram=$(read_rapl ram)

  local pswpin_fim pswpout_fim swap_in swap_out
  pswpin_fim=$(awk '/^pswpin/{print $2}' /proc/vmstat)
  pswpout_fim=$(awk '/^pswpout/{print $2}' /proc/vmstat)
  swap_in=$(( pswpin_fim - pswpin_ini ))
  swap_out=$(( pswpout_fim - pswpout_ini ))

  local wall wall_container_t user_t sys_t
  wall=$(tail -n 1 "$TIME_FILE")
  if ! [[ "$wall" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "  non-numeric wall_time ('$wall') - writing 0 and continuing" >&2
    wall="0.00"
  fi
  if [ -f "$timing_dir/time.txt" ]; then
    read -r wall_container_t user_t sys_t < "$timing_dir/time.txt"
  else
    wall_container_t="0.000"; user_t="0.000"; sys_t="0.000"
  fi
  rm -rf "$timing_dir"

  local d_pkg d_cores d_gpu d_ram
  d_pkg=$(delta_uj   "$ini_pkg"   "$fin_pkg"   "$max_pkg")
  d_cores=$(delta_uj "$ini_cores" "$fin_cores" "$max_cores")
  d_gpu=$(delta_uj   "$ini_gpu"   "$fin_gpu"   "$max_gpu")
  d_ram=$(delta_uj   "$ini_ram"   "$fin_ram"   "$max_ram")

  local j_pkg j_cores j_gpu j_ram j_ram_raw
  j_pkg=$(awk   "BEGIN {v=($d_pkg   - $taxa_pkg   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_cores=$(awk "BEGIN {v=($d_cores - $taxa_cores * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_gpu=$(awk   "BEGIN {v=($d_gpu   - $taxa_gpu   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_ram=$(awk   "BEGIN {v=($d_ram   - $taxa_ram   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")

  j_ram_raw=$(awk "BEGIN {printf \"%.6f\", ($d_ram - $taxa_ram * $wall) / 1e6}")

  echo "   ▶ ram: delta=${d_ram}µJ baseline=$(awk "BEGIN {printf \"%.0f\", $taxa_ram * $wall}")µJ net=$(awk "BEGIN {printf \"%.3f\", ($d_ram - $taxa_ram * $wall) / 1e6}")J  ${j_ram}J"

  if [ "$swap_out" -gt "$SWAP_WARN_PAGES" ]; then
    echo "     PAGINAÇÃO DO HOST na etapa '$stage': swap_out_pages=$swap_out (swap_in_pages=$swap_in)"
    echo "::warning title=Host paging during measurement::Run $RUN_NUM, stage '$stage': swap_out_pages=$swap_out (> $SWAP_WARN_PAGES pages = $((SWAP_WARN_PAGES*4/1024)) MiB). The host was under memory pressure inside the measured window (the container itself cannot page: memory.swap.max=0). Run suspect for I/O contention - review before including it in the valid set."
  elif [ "$swap_out" -gt 0 ]; then
    echo "  swap_out_pages=$swap_out (below the $SWAP_WARN_PAGES threshold - noise, no alert)"
  fi

  echo "$RUN_NUM,$stage,$j_pkg,$j_cores,$j_gpu,$j_ram,$wall,$user_t,$sys_t,$j_ram_raw,$wall_container_t,$swap_in,$swap_out" >> "$CSV_FILE"

  total_pkg=$(awk   "BEGIN {printf \"%.6f\", $total_pkg   + $j_pkg}")
  total_cores=$(awk "BEGIN {printf \"%.6f\", $total_cores + $j_cores}")
  total_gpu=$(awk   "BEGIN {printf \"%.6f\", $total_gpu   + $j_gpu}")
  total_ram=$(awk   "BEGIN {printf \"%.6f\", $total_ram   + $j_ram}")
  total_ram_raw=$(awk "BEGIN {printf \"%.6f\", $total_ram_raw + $j_ram_raw}")
  total_wall=$(awk  "BEGIN {printf \"%.3f\", $total_wall  + $wall}")
  total_user=$(awk  "BEGIN {printf \"%.3f\", $total_user  + $user_t}")
  total_sys=$(awk   "BEGIN {printf \"%.3f\", $total_sys   + $sys_t}")
  total_wall_container=$(awk "BEGIN {printf \"%.3f\", $total_wall_container + $wall_container_t}")
  total_swap_in=$(( total_swap_in + swap_in ))
  total_swap_out=$(( total_swap_out + swap_out ))

  echo "    pkg: ${j_pkg}J | cores: ${j_cores}J | ram: ${j_ram}J | wall: ${wall}s | swap_out: ${swap_out}p"
}

measure_stage build
measure_stage test

echo "$RUN_NUM,total,$total_pkg,$total_cores,$total_gpu,$total_ram,$total_wall,$total_user,$total_sys,$total_ram_raw,$total_wall_container,$total_swap_in,$total_swap_out" \
  >> "$CSV_FILE"

echo ""
echo ""
echo "Run $RUN_NUM finished - $(date '+%H:%M:%S')"
echo " CSV: $CSV_FILE"
echo " Total: pkg=${total_pkg}J | wall=${total_wall}s"
if [ "$total_swap_out" -gt "$SWAP_WARN_PAGES" ]; then
  echo "  Paging: swap_in=${total_swap_in}p swap_out=${total_swap_out}p (> $SWAP_WARN_PAGES) - RUN SUSPECT"
elif [ "$total_swap_out" -gt 0 ]; then
  echo "  Negligible paging: swap_out=${total_swap_out}p (threshold $SWAP_WARN_PAGES)"
else
  echo "  No paging: swap_in=${total_swap_in}p swap_out=${total_swap_out}p"
fi
echo ""
echo ""

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<EOF

## Run $RUN_NUM - $PROJECT_NAME

| Stage | pkg (J) | cores (J) | gpu (J) | ram (J) | wall (s) |
|-------|---------|-----------|---------|---------|----------|
$(grep "^$RUN_NUM," "$CSV_FILE" | awk -F',' '{printf "| %s | %s | %s | %s | %s | %s |\n", $2,$3,$4,$5,$6,$7}')
EOF
fi

rm -f "$TIME_FILE"

if [ "$PIPELINE_EXIT" -ne 0 ]; then
  echo "Run $RUN_NUM: stage(s) with non-zero exit  $FAILED_STAGES"
  echo "   CSV completo em $CSV_FILE · exit codes em $EXITS_FILE"
  exit "$PIPELINE_EXIT"
fi
