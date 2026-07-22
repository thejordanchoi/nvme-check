#!/usr/bin/env bash
#
# nvme_health_check.sh — full health check for NVMe drives, with emphasis on
# catching controller fatal status (CSTS.CFS) and other pre-failure signals.
#
# Usage:
#   sudo ./nvme_health_check.sh              # check all /dev/nvme* controllers
#   sudo ./nvme_health_check.sh /dev/nvme1   # check one controller
#   sudo ./nvme_health_check.sh -s ...       # also kick off a short self-test
#
set -uo pipefail

RUN_SELF_TEST=0
while getopts ":s" opt; do
  case "$opt" in
    s) RUN_SELF_TEST=1 ;;
    *) ;;
  esac
done
shift $((OPTIND - 1))

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; BLD=$'\033[1m'; RST=$'\033[0m'
WARNINGS=0
FAILURES=0

note()  { printf '%s\n' "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$YEL" "$RST" "$*"; WARNINGS=$((WARNINGS+1)); }
fail()  { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*"; FAILURES=$((FAILURES+1)); }
ok()    { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
hdr()   { printf '\n%s==== %s ====%s\n' "$BLD" "$*" "$RST"; }

if [[ $EUID -ne 0 ]]; then
  echo "This script needs root (nvme-cli register/log reads require it). Re-run with sudo." >&2
  exit 1
fi

if ! command -v nvme >/dev/null 2>&1; then
  echo "nvme-cli not found. Install it: apt install nvme-cli  (or) yum install nvme-cli" >&2
  exit 1
fi

HAVE_SMARTCTL=0
command -v smartctl >/dev/null 2>&1 && HAVE_SMARTCTL=1

# Figure out which controllers to check.
if [[ $# -ge 1 ]]; then
  DEVICES=("$@")
else
  mapfile -t DEVICES < <(nvme list -o json 2>/dev/null \
    | grep -o '"DevicePath" *: *"[^"]*"' | sed -E 's/.*"([^"]+)"$/\1/' \
    | sed -E 's/n[0-9]+$//' | sort -u)
  if [[ ${#DEVICES[@]} -eq 0 ]]; then
    mapfile -t DEVICES < <(ls /dev/nvme[0-9]* 2>/dev/null | grep -E 'nvme[0-9]+$')
  fi
fi

if [[ ${#DEVICES[@]} -eq 0 ]]; then
  hdr "No /dev/nvme* controllers found — checking PCI bus"

  PCI_NVME=""
  if command -v lspci >/dev/null 2>&1; then
    # Class 0108xx = Non-Volatile memory controller (covers 010802 NVMe and friends).
    PCI_NVME=$(lspci -nn -d ::0108 2>/dev/null)
  else
    note "lspci not available; cannot cross-check the PCI bus."
  fi

  if [[ -n "$PCI_NVME" ]]; then
    fail "NVMe controller visible on PCI bus but NOT enumerated as /dev/nvme* — driver is not bound to it."
    echo "$PCI_NVME"
    note "This usually means the controller dropped off (crashed/reset) and the kernel gave up on it,"
    note "or it never bound to the nvme driver in the first place. Details below."

    PCI_SLOT=$(echo "$PCI_NVME" | awk '{print $1; exit}')
    if [[ -n "$PCI_SLOT" ]] && command -v lspci >/dev/null 2>&1; then
      hdr "lspci -vvv for $PCI_SLOT (driver binding, AER status)"
      lspci -vvvs "$PCI_SLOT" 2>&1
    fi

    if command -v dmesg >/dev/null 2>&1; then
      hdr "Recent dmesg mentions of nvme/PCIe errors"
      DMESG_HITS=$(dmesg -T 2>/dev/null | grep -iE 'nvme|pcie.*(aer|error)|link.*(down|degraded)' | tail -50)
      if [[ -n "$DMESG_HITS" ]]; then
        echo "$DMESG_HITS"
        echo "$DMESG_HITS" | grep -qiE 'cfs|fatal'      && fail "dmesg shows CFS/fatal controller error events."
        echo "$DMESG_HITS" | grep -qiE 'removed|surprise' && fail "dmesg shows the device being removed/surprise-removed."
        echo "$DMESG_HITS" | grep -qiE 'timeout|reset'   && fail "dmesg shows NVMe command timeouts/resets — consistent with a dying controller."
      else
        note "No matching lines in current dmesg buffer (note: buffer may have rotated — try journalctl -k)."
      fi
    else
      note "dmesg not available."
    fi

    hdr "Summary"
    printf '%s%d failure(s), %d warning(s) — controller is present on PCIe but has fallen off the nvme driver; treat as failed/failing.%s\n' "$RED" "$FAILURES" "$WARNINGS" "$RST"
    exit 2
  else
    echo "No NVMe controllers found on the PCI bus either — no NVMe hardware detected." >&2
    exit 1
  fi
fi

echo "NVMe controllers to check: ${DEVICES[*]}"

for dev in "${DEVICES[@]}"; do
  hdr "Controller: $dev"

  # --- Identify ---
  MODEL=$(nvme id-ctrl "$dev" 2>/dev/null | awk -F: '/^mn / {gsub(/^ +| +$/,"",$2); print $2; exit}')
  SERIAL=$(nvme id-ctrl "$dev" 2>/dev/null | awk -F: '/^sn / {gsub(/^ +| +$/,"",$2); print $2; exit}')
  FW=$(nvme id-ctrl "$dev" 2>/dev/null | awk -F: '/^fr / {gsub(/^ +| +$/,"",$2); print $2; exit}')
  note "Model: ${MODEL:-unknown}   Serial: ${SERIAL:-unknown}   FW: ${FW:-unknown}"

  # --- Controller registers: this is where CFS actually lives (CSTS bit 1) ---
  hdr "$dev — Controller Status Register (CSTS)"
  REGS=$(nvme show-regs "$dev" 2>&1)
  if [[ $? -ne 0 ]]; then
    warn "Could not read controller registers on $dev (needs recent nvme-cli / kernel support)."
  else
    echo "$REGS" | grep -Ei 'csts|cap |vs ' || echo "$REGS"
    CSTS_LINE=$(echo "$REGS" | grep -i '^csts' || true)
    if echo "$CSTS_LINE" | grep -qi 'cfs'; then
      # nvme-cli decodes csts and prints flags like "rdy+ cfs+ ..." when set
      if echo "$CSTS_LINE" | grep -qiE 'cfs\+|cfs[[:space:]]*:[[:space:]]*1'; then
        fail "$dev CSTS shows CFS (Controller Fatal Status) SET RIGHT NOW — controller reports an unrecoverable internal error."
      else
        ok "CFS bit not currently set."
      fi
    else
      note "Raw CSTS value above — check bit 1 (CFS) manually if the decode didn't include a label."
    fi
  fi

  # --- SMART / health log ---
  hdr "$dev — SMART / Health Log"
  SMART=$(nvme smart-log "$dev" 2>&1)
  echo "$SMART"

  CRIT=$(echo "$SMART" | awk -F: '/critical_warning/ {gsub(/[^0-9x]/,"",$2); print $2}')
  if [[ -n "${CRIT:-}" ]]; then
    CRIT_DEC=$((CRIT))
    if [[ $CRIT_DEC -eq 0 ]]; then
      ok "critical_warning = 0 (no bits set)"
    else
      fail "critical_warning = $CRIT_DEC (nonzero — see bit decode below)"
      [[ $((CRIT_DEC & 0x01)) -ne 0 ]] && fail "  bit0: available spare below threshold"
      [[ $((CRIT_DEC & 0x02)) -ne 0 ]] && fail "  bit1: temperature above/below critical threshold"
      [[ $((CRIT_DEC & 0x04)) -ne 0 ]] && fail "  bit2: NVM subsystem reliability degraded"
      [[ $((CRIT_DEC & 0x08)) -ne 0 ]] && fail "  bit3: media placed in read-only mode"
      [[ $((CRIT_DEC & 0x10)) -ne 0 ]] && fail "  bit4: volatile memory backup device failed"
      [[ $((CRIT_DEC & 0x20)) -ne 0 ]] && warn "  bit5: persistent memory region unreliable"
    fi
  fi

  SPARE=$(echo "$SMART" | awk -F: '/available_spare / && !/threshold/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
  SPARE_THRESH=$(echo "$SMART" | awk -F: '/available_spare_threshold/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
  if [[ -n "${SPARE:-}" && -n "${SPARE_THRESH:-}" ]]; then
    if [[ $SPARE -le $SPARE_THRESH ]]; then
      fail "available_spare ($SPARE%) at/below threshold ($SPARE_THRESH%)"
    else
      ok "available_spare $SPARE% (threshold $SPARE_THRESH%)"
    fi
  fi

  PCT_USED=$(echo "$SMART" | awk -F: '/percentage_used/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
  if [[ -n "${PCT_USED:-}" ]]; then
    if [[ $PCT_USED -ge 100 ]]; then
      fail "percentage_used = $PCT_USED% — endurance limit reached/exceeded"
    elif [[ $PCT_USED -ge 90 ]]; then
      warn "percentage_used = $PCT_USED% — approaching endurance limit"
    else
      ok "percentage_used = $PCT_USED%"
    fi
  fi

  MEDIA_ERR=$(echo "$SMART" | awk -F: '/media_errors/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
  if [[ -n "${MEDIA_ERR:-}" ]]; then
    if [[ $MEDIA_ERR -gt 0 ]]; then
      fail "media_errors = $MEDIA_ERR (nonzero — uncorrectable media errors recorded)"
    else
      ok "media_errors = 0"
    fi
  fi

  ERR_LOG_ENTRIES=$(echo "$SMART" | awk -F: '/num_err_log_entries/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
  [[ -n "${ERR_LOG_ENTRIES:-}" ]] && note "num_err_log_entries (lifetime) = $ERR_LOG_ENTRIES"

  UNSAFE_SHUT=$(echo "$SMART" | awk -F: '/unsafe_shutdowns/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
  [[ -n "${UNSAFE_SHUT:-}" ]] && note "unsafe_shutdowns = $UNSAFE_SHUT"

  TEMP=$(echo "$SMART" | awk -F: '/^temperature/ {print $2; exit}' | grep -oE '[0-9]+' | head -1)
  if [[ -n "${TEMP:-}" ]]; then
    if [[ $TEMP -ge 85 ]]; then
      fail "temperature ${TEMP}C — very high"
    elif [[ $TEMP -ge 75 ]]; then
      warn "temperature ${TEMP}C — elevated"
    else
      ok "temperature ${TEMP}C"
    fi
  fi

  # --- Error log: recent entries, this is where CFS-triggering events show up ---
  hdr "$dev — Error Log (most recent entries)"
  ERRLOG=$(nvme error-log "$dev" 2>&1)
  echo "$ERRLOG" | head -80
  NONZERO_ERRORS=$(echo "$ERRLOG" | grep -c '^error_count' || true)
  if echo "$ERRLOG" | grep -qE 'status_field.*[1-9a-fA-F]'; then
    warn "$dev has nonzero status_field entries in error-log — review above for repeated/fatal codes."
  fi

  # --- Firmware log ---
  hdr "$dev — Firmware Slot Log"
  nvme fw-log "$dev" 2>&1

  # --- Self-test log / optional new self-test ---
  hdr "$dev — Self-Test Log"
  nvme self-test-log "$dev" 2>&1 || note "(device/controller may not support self-test log)"

  if [[ $RUN_SELF_TEST -eq 1 ]]; then
    note "Starting short self-test on $dev ..."
    nvme device-self-test "$dev" -s 1 2>&1
    note "Self-test started; poll with: nvme self-test-log $dev"
  fi

  # --- Kernel log corroboration ---
  hdr "$dev — Recent dmesg mentions"
  DEVNAME=$(basename "$dev")
  if command -v dmesg >/dev/null 2>&1; then
    DMESG_HITS=$(dmesg -T 2>/dev/null | grep -iE "$DEVNAME|nvme.*(cfs|fatal|controller.*error|timeout|reset)" | tail -30)
    if [[ -n "$DMESG_HITS" ]]; then
      echo "$DMESG_HITS"
      echo "$DMESG_HITS" | grep -qi 'cfs' && fail "$dev: dmesg shows CFS (controller fatal status) events."
      echo "$DMESG_HITS" | grep -qi 'fatal'  && fail "$dev: dmesg shows fatal error events."
    else
      ok "No matching NVMe error lines in current dmesg buffer (note: buffer may have rotated)."
    fi
  else
    note "dmesg not available."
  fi

  # --- smartctl cross-check, if present ---
  if [[ $HAVE_SMARTCTL -eq 1 ]]; then
    hdr "$dev — smartctl cross-check"
    smartctl -a -d nvme "$dev" 2>&1 | sed -n '1,60p'
  fi

done

hdr "Summary"
if [[ $FAILURES -gt 0 ]]; then
  printf '%s%d failure(s), %d warning(s) — drive(s) likely need attention/replacement.%s\n' "$RED" "$FAILURES" "$WARNINGS" "$RST"
  exit 2
elif [[ $WARNINGS -gt 0 ]]; then
  printf '%s%d warning(s), no hard failures — keep an eye on it.%s\n' "$YEL" "$WARNINGS" "$RST"
  exit 1
else
  printf '%sAll checks passed.%s\n' "$GRN" "$RST"
  exit 0
fi
