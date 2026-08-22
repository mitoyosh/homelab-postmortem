---
title: Toolkit
permalink: /toolkit/
---

Every script here comes from a specific, dated incident documented on this
site — diagnosed on real hardware, fixed, and then generalized into a script
that's safe to hand to a stranger: no silent writes, backups before anything
destructive, dry-run modes where it matters.

## What's in it

- **`fix-partuuid-after-clone.sh`** — detects and fixes the stale
  `root=PARTUUID=` reference that `rpi-clone` and similar tools leave behind
  after cloning an SD card to a USB SSD/NVMe. From
  [The rpi-clone PARTUUID trap]({{ '/2026/08/16/rpi-clone-partuuid-trap/' | relative_url }}).
- **`check-undervoltage.sh`** — one-shot Raspberry Pi power health check,
  with or without `vcgencmd` installed, plain-English explanations instead
  of a hex code. From
  [Undervoltage doesn't look like a power problem]({{ '/2026/08/17/undervoltage-looks-like-a-wifi-problem/' | relative_url }}).
- **`check-journald-persistence.sh`** — detects the vendor drop-in that keeps
  Trixie's journal in RAM, and fixes it properly — including the flush step
  most published fixes leave out. From
  [Trixie throws away your logs on reboot]({{ '/2026/08/18/trixie-journald-volatile-logs/' | relative_url }}).
- **`check-swap-mechanism.sh`** — reports which swap subsystem actually governs
  the machine, and finds disk consumed by swap that `swapon`, `free` and
  `/proc/swaps` all decline to mention. From
  [Your Pi's 2 GB swap file isn't swap]({{ '/2026/08/19/trixie-rpi-swap-writeback-file/' | relative_url }}).

- **`check-memory-cgroup.sh`** — answers whether a memory limit set on this
  machine will actually be enforced. On stock Raspberry Pi OS it will not, and
  `docker run --memory` says nothing about it. From
  [Your Pi accepts every memory limit you set]({{ '/2026/08/19/pi-memory-cgroup-disabled-by-firmware/' | relative_url }}).
- **`check-sysctl-persistence.sh`** — finds sysctl settings that apply now and
  disappear at the next reboot, and checks for the compatibility symlink that
  decides which way it goes. From
  [sysctl -p says it worked]({{ '/2026/08/19/etc-sysctl-conf-not-read-at-boot/' | relative_url }}).
- **`check-nmcli-provisioning.sh`** — flags the `nmcli` abbreviation that
  NetworkManager 1.52 made ambiguous, and WiFi profiles left with no key
  management that look configured and can never associate. From
  [A new NetworkManager property broke a decade of scripts]({{ '/2026/08/19/nmcli-abbreviation-ambiguity-trixie/' | relative_url }}).
- **`check-docker-firewall-bypass.sh`** — finds container ports that are
  reachable from your network while your firewall reports them as denied.
  Docker's chains are evaluated before UFW's, so both are true at once. From
  [UFW says the port is closed]({{ '/2026/08/22/docker-publishes-past-ufw/' | relative_url }}).

Also relevant if you're building your own delivery pipeline:
[Stripe retries a failed webhook for three days]({{ '/2026/08/18/stripe-webhook-retries-and-idempotency/' | relative_url }}) — the idempotency bug this toolkit's own delivery Worker hit and fixed.

New scripts are added as new incidents happen — this is a living collection,
not a one-time release.

<div class="callout">
  <h3>Get the toolkit — $12</h3>
  <p>
    One-time purchase. The download link is emailed to you immediately, and
    every script added later is part of the same purchase.
  </p>
  <a class="btn" href="https://buy.stripe.com/5kQ8wOa3y4OwaWf7yM5Vu01">Buy the toolkit &rarr;</a>
</div>
