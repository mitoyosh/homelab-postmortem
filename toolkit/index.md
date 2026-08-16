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
  of a hex code.

New scripts are added as new incidents happen — this is a living collection,
not a one-time release.

<div class="callout">
  <h3>Get the toolkit</h3>
  <p>Purchase and download links are being set up — check back shortly.</p>
</div>
