# nvme_health_check.sh

Full health check for NVMe drives, with emphasis on catching **controller
fatal status (CSTS.CFS)** and other pre-failure signals — written after a
U.2 drive reported a CFS controller fatal status.

## Requirements

- Linux with the NVMe drive(s) attached
- `nvme-cli` (`sudo apt install nvme-cli`, or `yum install nvme-cli` on RHEL/CentOS)
- root privileges (register and log reads need it)
- `smartctl` (optional — used for a cross-check if present, from `smartmontools`)
- `lspci` (optional — from `pciutils`; used to detect a controller that's on the
  PCI bus but has fallen off the `nvme` driver, see below)
- `python3` (optional — used to peek the raw CSTS register over PCI BAR0 when
  there's no `/dev/nvme*` node to talk to via `nvme-cli`)

## Usage

```bash
# Check every NVMe controller on the system
sudo ~/scripts/nvme_health_check.sh

# Check a specific controller
sudo ~/scripts/nvme_health_check.sh /dev/nvme1

# Also kick off a short self-test on the target controller(s)
sudo ~/scripts/nvme_health_check.sh -s /dev/nvme1
```

Find your device names with `nvme list` or `lsblk`.

## What it checks

For each controller:

1. **Identify** — model, serial, firmware revision.
2. **CSTS register** (`nvme show-regs`) — reads the Controller Status
   Register directly, where the CFS bit actually lives. Flags if CFS is
   set *right now*.
3. **SMART / health log** (`nvme smart-log`):
   - `critical_warning` bitmask, decoded bit-by-bit (spare low, temp
     threshold, reliability degraded, read-only mode, backup device
     failed, PMR unreliable)
   - `available_spare` vs. `available_spare_threshold`
   - `percentage_used` (endurance)
   - `media_errors`
   - `num_err_log_entries`, `unsafe_shutdowns`
   - `temperature`
4. **Error log** (`nvme error-log`) — recent controller error entries,
   which is typically where a CFS-triggering event leaves a trace.
5. **Firmware slot log** (`nvme fw-log`).
6. **Self-test log** (`nvme self-test-log`), and optionally starts a new
   short self-test with `-s`.
7. **dmesg** — greps the kernel log for `cfs`, `fatal`, `timeout`, `reset`,
   or the device name, as corroborating evidence.
8. **smartctl cross-check** — only runs if `smartctl` is installed.

### When no `/dev/nvme*` device is found

A drive can be visible on the PCIe bus (`lspci -nn`) while showing up
practically nowhere else — the controller crashed/reset hard enough that
the kernel dropped it from the `nvme` driver, or it never bound in the
first place. In that case `nvme-cli` has nothing to talk to, so the
script falls back to a PCI-bus-level check instead of just reporting "no
devices found":

1. **`lspci -D -nn -d ::0108`** — looks for a PCI Non-Volatile memory
   controller (class `0108`) even though no block device exists for it.
2. **`lspci -vvv`** on that slot — driver binding (or lack of it), link
   speed/width, and AER (Advanced Error Reporting) status.
3. **Raw CSTS register peek** — with no `/dev/nvme*` node, `nvme show-regs`
   can't run, but the PCI BAR is still reachable via
   `/sys/bus/pci/devices/<BDF>/resource0` even when unbound from any
   driver. The script reads CAP (offset `0x0`) and CSTS (offset `0x1c`)
   directly:
   - CAP reading all `1`s means the PCIe MMIO space itself is unresponsive
     — the controller is dead/hung on the bus, not just a driver-binding
     hiccup.
   - Otherwise, CSTS bit 1 (CFS) and bit 0 (RDY) are decoded directly from
     hardware, so a fatal-status controller is still caught even though it
     never got a `/dev/nvme*` node.
4. **dmesg** — greps for `nvme`, PCIe AER/error, and link down/degraded
   lines, and flags CFS/fatal, removed/surprise-removed, and
   timeout/reset mentions specifically.

If a PCI NVMe controller is found this way, the script treats it as a
hard failure (exit `2`) — a controller that's fallen off the driver
entirely is worse than one that's merely reporting bad SMART values.
Only if **nothing** shows up on the PCI bus either does it report no
NVMe hardware detected (exit `1`).

## Output / exit codes

Each check prints `[ OK ]`, `[WARN]`, or `[FAIL]`. At the end it prints a
summary and exits:

| Exit code | Meaning                                      |
|-----------|-----------------------------------------------|
| `0`       | All checks passed                             |
| `1`       | One or more warnings, no hard failures — *or* no NVMe hardware found at all (not even on the PCI bus) |
| `2`       | One or more failures — drive likely needs attention/replacement. Also used when a controller is found on the PCI bus but has fallen off the `nvme` driver entirely. |

This makes it easy to wire into cron/monitoring (e.g. alert if exit code
is nonzero).

## Interpreting a CFS event

If a drive has previously thrown a controller fatal status:

- Check the **CSTS section** first — if CFS is set again, the controller
  is currently in a fatal state. If the drive has dropped off
  `/dev/nvme*` entirely, check the PCI-bus fallback's raw register peek
  instead — it reads CSTS directly off the hardware.
- Check **error-log** and **dmesg** for repeated fatal/timeout/reset
  entries — a one-off CFS after an unclean power event is less alarming
  than recurring CFS under normal operation.
- Watch **media_errors**, **available_spare**, and **unsafe_shutdowns**
  over time — climbing values alongside CFS events point toward hardware
  failure rather than a transient glitch.
