#!/usr/bin/env bash
#
# HDD Burn-In — one-shot, keep it simple
# Usage: sudo ./burnin.sh /dev/sdX
#
# DESTROYS ALL DATA ON THE TARGET DRIVE.
#
# Total time for 8TB via USB 3.0: ~50-60 hours
#

DRIVE="${1:?Usage: sudo $0 /dev/sdX}"
LOGDIR="$(pwd)/burnin-logs"

# ── preflight ────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || {
  echo "Run as root."
  exit 1
}
[[ -b "$DRIVE" ]] || {
  echo "$DRIVE is not a block device."
  exit 1
}
lsblk -n -o MOUNTPOINT "$DRIVE" | grep -q . && {
  echo "$DRIVE has mounted partitions. Unmount first."
  exit 1
}

for cmd in smartctl badblocks fio lsblk; do
  command -v "$cmd" &>/dev/null || {
    echo "$cmd not found."
    exit 1
  }
done

mkdir -p "$LOGDIR"
SERIAL=$(smartctl -i "$DRIVE" | awk '/Serial Number/{print $3}')
MODEL=$(smartctl -i "$DRIVE" | awk '/Device Model/{$1=$2=""; print $0}' | xargs)
LOGFILE="${LOGDIR}/burnin_${SERIAL:-unknown}_$(date +%Y%m%d_%H%M%S).log"

# send everything to both console and log
exec > >(tee -a "$LOGFILE") 2>&1
set -euo pipefail
trap '[[ $? -eq 0 ]] || echo "!!! Aborted at $(date)"' EXIT

# ── helpers ──────────────────────────────────────────────────────────────────

check_smart() {
  local out
  out=$(smartctl -A "$DRIVE")
  echo "$out"
  local bad=0
  for attr in 5 197 198; do
    local val
    val=$(echo "$out" | awk -v id="$attr" '$1==id{print $10+0}')
    val=${val:-0}
    if [[ "$val" -ne 0 ]]; then
      echo "!!! SMART attribute $attr is non-zero ($val) — FAIL."
      bad=1
    fi
  done
  local crc
  crc=$(echo "$out" | awk '$1==199{print $10+0}')
  crc=${crc:-0}
  [[ "$crc" -eq 0 ]] || echo "WARNING: UDMA CRC errors ($crc) — adapter/cable issue; retest on SATA if drive is suspect."
  [[ $bad -eq 0 ]] || exit 1
}

check_selftest() {
  local label="$1"
  local log
  log=$(smartctl -l selftest "$DRIVE")
  echo "$log"
  echo "$log" | awk '/^# 1 /{print}' | grep -q "Completed without error" || {
    echo "!!! $label did not complete without error — FAIL."
    exit 1
  }
}

wait_selftest() {
  local label="$1" max_secs="${2:-43200}"
  local elapsed=300
  sleep 300
  while smartctl -a "$DRIVE" | grep -q "Self-test routine in progress"; do
    echo "$(date): $label still running..."
    elapsed=$((elapsed + 300))
    if [[ $elapsed -ge $max_secs ]]; then
      echo "!!! $label timed out after ${max_secs}s — FAIL."
      exit 1
    fi
    sleep 300
  done
  check_selftest "$label"
}

run_tool() {
  local label="$1"
  shift
  echo ">>> $label starting at $(date)"
  set +e
  "$@"
  local rc=$?
  set -e
  echo ">>> $label finished at $(date) with exit code $rc"
  if [[ $rc -ne 0 ]]; then
    echo "!!! $label FAILED (exit $rc)."
    smartctl -A "$DRIVE"
    exit 1
  fi
}

# ── burn-in ──────────────────────────────────────────────────────────────────

echo "============================================"
echo "BURN-IN: $MODEL | S/N: $SERIAL"
echo "Device:  $DRIVE"
echo "Started: $(date)"
echo "Log:     $LOGFILE"
echo "============================================"

# step 0: baseline
smartctl -x "$DRIVE" | tee "${LOGDIR}/baseline_${SERIAL}.txt"
check_smart

# step 1: SMART short self-test (~2 min)
smartctl -t short "$DRIVE"
wait_selftest "Short self-test" 1800

# step 2: SMART conveyance test (~5 min)
smartctl -t conveyance "$DRIVE"
wait_selftest "Conveyance self-test" 1800

# step 3: SMART extended self-test, pre-stress (~10 hrs)
# polling with smartctl also keeps the USB adapter awake
smartctl -t long "$DRIVE"
wait_selftest "Pre-stress extended self-test"
check_smart

# step 4: badblocks destructive write test (~24 hrs)
# four-pass write/read, -e 1 aborts on first bad block
run_tool "badblocks" badblocks -wsv -b 4096 -e 1 "$DRIVE"
check_smart

# step 5: fio random I/O stress test (~4 hrs)
# stresses actuator/heads with random seeks — catches failures
# that sequential badblocks misses; conservative iodepth for USB
run_tool "fio" fio --name=burnin \
  --filename="$DRIVE" \
  --rw=randrw \
  --rwmixread=50 \
  --bs=4k \
  --direct=1 \
  --numjobs=1 \
  --iodepth=16 \
  --time_based \
  --runtime=14400 \
  --eta-newline=60 \
  --group_reporting
check_smart

# step 6: SMART extended self-test, post-stress (~10 hrs)
smartctl -t long "$DRIVE"
wait_selftest "Post-stress extended self-test"

# step 7: final snapshot
smartctl -x "$DRIVE" | tee "${LOGDIR}/final_${SERIAL}.txt"
check_smart

echo ""
echo "============================================"
echo "BURN-IN COMPLETE: $MODEL | S/N: $SERIAL"
echo "Finished: $(date)"
echo "============================================"
echo ""
echo "Compare: diff ${LOGDIR}/baseline_${SERIAL}.txt ${LOGDIR}/final_${SERIAL}.txt"
echo ""
echo "Key attributes to eyeball in the diff:"
echo "  ID 5   Reallocated_Sector_Ct  — must be 0"
echo "  ID 197 Current_Pending_Sector — must be 0"
echo "  ID 198 Offline_Uncorrectable  — must be 0"
echo "  ID 199 UDMA_CRC_Error_Count   — must be 0 (non-zero = adapter issue)"
echo ""
echo "If all four are zero → deploy with confidence."
echo "============================================"
