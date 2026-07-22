# nvme_health_check.sh

Full health check for NVMe drives, with emphasis on catching **controller
fatal status (CSTS.CFS)** and other pre-failure signals — written after a
U.2 drive reported a CFS controller fatal status.

## Requirements

- Linux with the NVMe drive(s) attached
- `nvme-cli` (`sudo apt install nvme-cli`, or `yum install nvme-cli` on RHEL/CentOS)
- root privileges (register and log reads need it)
- `smartctl` (optional — used for a cross-check if present, from `smartmontools`)

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

## Output / exit codes

Each check prints `[ OK ]`, `[WARN]`, or `[FAIL]`. At the end it prints a
summary and exits:

| Exit code | Meaning                                      |
|-----------|-----------------------------------------------|
| `0`       | All checks passed                             |
| `1`       | One or more warnings, no hard failures        |
| `2`       | One or more failures — drive likely needs attention/replacement |

This makes it easy to wire into cron/monitoring (e.g. alert if exit code
is nonzero).

## Interpreting a CFS event

If a drive has previously thrown a controller fatal status:

- Check the **CSTS section** first — if CFS is set again, the controller
  is currently in a fatal state.
- Check **error-log** and **dmesg** for repeated fatal/timeout/reset
  entries — a one-off CFS after an unclean power event is less alarming
  than recurring CFS under normal operation.
- Watch **media_errors**, **available_spare**, and **unsafe_shutdowns**
  over time — climbing values alongside CFS events point toward hardware
  failure rather than a transient glitch.
