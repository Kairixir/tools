#!/usr/bin/env bash
#
# HDD Burn-In — one-shot, keep it simple
# Usage: sudo ./burnin.sh /dev/sdX
#
# DESTROYS ALL DATA ON THE TARGET DRIVE.
#
# Total time for 8TB via USB 3.0: ~60-90 hours
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

fio --enghelp=libaio &>/dev/null || {
  echo "fio libaio engine not available. Install libaio (pacman -S libaio / apt install libaio-dev)."
  exit 1
}

mkdir -p "$LOGDIR"
SERIAL=$(smartctl -i "$DRIVE" | awk '/Serial Number/{print $3}')
MODEL=$(smartctl -i "$DRIVE" | awk '/Device Model/{$1=$2=""; print $0}' | xargs)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOGFILE="${LOGDIR}/burnin_${SERIAL:-unknown}_${TIMESTAMP}.log"

# parse self-test durations from drive, add margin, convert to seconds
SMART_CAP=$(smartctl -c "$DRIVE")
SHORT_MINS=$(echo "$SMART_CAP" | grep -A1 "Short self-test" | awk -F'[()]' '/polling/{print $2+0}')
CONV_MINS=$(echo "$SMART_CAP" | grep -A1 "Conveyance self-test" | awk -F'[()]' '/polling/{print $2+0}')
LONG_MINS=$(echo "$SMART_CAP" | grep -A1 "Extended self-test" | awk -F'[()]' '/polling/{print $2+0}')
: "${SHORT_MINS:=5}"
: "${CONV_MINS:=10}"
: "${LONG_MINS:=660}"
SHORT_SECS=$((SHORT_MINS * 3 * 60 / 2))
CONV_SECS=$((CONV_MINS * 3 * 60 / 2))
LONG_SECS=$(((LONG_MINS + LONG_MINS / 15 + 1) * 60))

# send everything to both console and log
exec > >(tee -a "$LOGFILE") 2>&1
# strict mode after exec so preflight above handles its own errors with clear messages
set -euo pipefail
trap '[[ $? -eq 0 ]] || echo "!!! Aborted at $(date)"' EXIT

# abort any self-test left over from a previous interrupted run
smartctl -X "$DRIVE" 2>/dev/null || true

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
  local label="$1" secs="$2"
  echo ">>> $label: sleeping ${secs}s (~$((secs / 60))m)"
  sleep "$secs"
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
echo "Self-test sleep times: short=${SHORT_SECS}s conv=${CONV_SECS}s long=${LONG_SECS}s"
echo "============================================"

# step 0: baseline
smartctl -x "$DRIVE" | tee "${LOGDIR}/baseline_${SERIAL}_${TIMESTAMP}.txt"
check_smart

# step 1: SMART short self-test
smartctl -t short "$DRIVE"
wait_selftest "Short self-test" "$SHORT_SECS"

# step 2: SMART conveyance test
smartctl -t conveyance "$DRIVE"
wait_selftest "Conveyance self-test" "$CONV_SECS"

# step 3: SMART extended self-test, pre-stress
# no status polling — ATA commands suspend the test on this drive
smartctl -X "$DRIVE" 2>/dev/null || true
smartctl -t long "$DRIVE"
wait_selftest "Pre-stress extended self-test" "$LONG_SECS"
check_smart

# step 4: badblocks destructive write test
# four-pass write/read, -e 1 aborts on first bad block
run_tool "badblocks" badblocks -wsv -b 4096 -e 1 "$DRIVE"
check_smart

# step 5: fio random I/O stress test (~4 hrs)
# stresses actuator/heads with random seeks — catches failures
# that sequential badblocks misses; iodepth=16 via libaio pushes
# 16 concurrent I/Os which is near the mechanical seek limit anyway
run_tool "fio" fio --name=burnin \
  --filename="$DRIVE" \
  --ioengine=libaio \
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

# step 6: SMART extended self-test, post-stress
smartctl -X "$DRIVE" 2>/dev/null || true
smartctl -t long "$DRIVE"
wait_selftest "Post-stress extended self-test" "$LONG_SECS"

# step 7: final snapshot
smartctl -x "$DRIVE" | tee "${LOGDIR}/final_${SERIAL}_${TIMESTAMP}.txt"
check_smart

echo ""
echo "============================================"
echo "BURN-IN COMPLETE: $MODEL | S/N: $SERIAL"
echo "Finished: $(date)"
echo "============================================"
echo ""
echo "Compare: diff ${LOGDIR}/baseline_${SERIAL}_${TIMESTAMP}.txt ${LOGDIR}/final_${SERIAL}_${TIMESTAMP}.txt"
echo ""
echo "Key attributes to eyeball in the diff:"
echo "  ID 5   Reallocated_Sector_Ct  — must be 0"
echo "  ID 197 Current_Pending_Sector — must be 0"
echo "  ID 198 Offline_Uncorrectable  — must be 0"
echo "  ID 199 UDMA_CRC_Error_Count   — must be 0 (non-zero = adapter issue)"
echo ""
echo "If all four are zero → deploy with confidence."
echo "============================================"
