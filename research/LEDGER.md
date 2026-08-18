# Triage ledger

One row per candidate that has been looked at. The `/postmortem` workflow reads
this to avoid re-offering things that were already handled, and appends to it as
decisions get made.

Status values:

- `published` — verified on hardware and shipped; link the post
- `rejected` — decided not to pursue; say why in one line
- `did-not-reproduce` — checked on the reference Pi, problem isn't present
- `deferred` — worth doing, not now

| Date added | Candidate | Status | Outcome / reason |
|---|---|---|---|
| 2026-08-16 | Docker `--memory` silently unenforced (missing cgroup params) | deferred | Strong candidate. Reproduction check not yet run on the Pi. |
| 2026-08-16 | Trixie NetworkManager migration breaks static IP / DNS | deferred | Real but broad; needs narrowing before it's a post. |
| 2026-08-16 | Pi 5 NVMe/PCIe boot instability | rejected | Pi 5 hardware; no Pi 5 on hand to verify. |
| 2026-08-16 | Home Assistant recorder DB corruption | rejected | Not Pi-specific; off-topic for this site. |
| 2026-08-17 | Pi 5 NVMe I/O errors under load | rejected | Same reason — no Pi 5 to verify against. |
| 2026-08-17 | Trixie `/etc/sysctl.conf` silently stops applying | deferred | Plausible and checkable; not yet run. |
| 2026-08-17 | Proxmox VE 8→9 NIC rename locks out host | rejected | No Proxmox in this lab; can't verify first-hand. |
| 2026-08-17 | Proxmox VE 9 LVM-thin autoactivation | rejected | Same — no Proxmox. |
| 2026-08-17 | Trixie Samba guest access breaks after upgrade | deferred | Checkable but no Samba configured yet. |
| 2026-08-18 | Trixie journald volatile storage (logs lost on reboot) | published | [Trixie throws away your logs on reboot](https://homelabpostmortem.com/2026/08/18/trixie-journald-volatile-logs/) |
| 2026-08-18 | nmcli ≥1.52 ambiguous property breaks provisioning scripts | deferred | Interesting, but only one documented instance so far. |
