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
- **`check-cloudinit-ssh-import.sh`** — catches a cloud-init `ssh_import_id`
  that will never be read, before you flash the card and find out the
  headless way. From
  [cloud-init calls your user-data valid]({{ '/2026/08/29/cloud-init-validates-the-key-it-never-reads/' | relative_url }}).
- **`check-docker-log-integrity.sh`** — tells you whether `docker logs` is
  returning everything on disk, or stopping at a NUL byte with exit 0 and
  hiding the rest. From
  [docker logs stops at a NUL byte and exits 0]({{ '/2026/09/12/docker-logs-stops-at-a-nul-byte-and-exits-0/' | relative_url }}).
- **`check-llama-response-format.sh`** — tells you which `response_format`
  forms a running `llama-server` actually enforces. The one its README shows
  is accepted and ignored. From
  [llama-server ignores the response_format its own README shows]({{ '/2026/09/12/llama-server-ignores-the-response-format-its-readme-shows/' | relative_url }}).
- **`check-cloudinit-instance-id.sh`** — answers whether a `user-data` you
  place on a disk will be acted on at all. On a plain image write it will not
  be, and cloud-init logs the skip as `SUCCESS`. From
  [cloud-init never reads the instance-id Raspberry Pi OS sets]({{ '/2026/09/11/cloud-init-never-reads-the-instance-id-you-set/' | relative_url }}).
- **`check-iptables-backend.sh`** — tells you whether legacy iptables can
  work on this kernel at all, before you install something that assumes it.
  From
  [iptables says your kernel needs upgrading]({{ '/2026/08/27/iptables-legacy-modules-gone-from-pi-kernel/' | relative_url }}).
- **`check-network-config-location.sh`** — finds where your WiFi credentials
  are actually stored, and warns when the directory every guide names is
  empty so your backup silently captures nothing. From
  [tar backed up your WiFi config and exited 0]({{ '/2026/08/26/wifi-config-not-in-system-connections/' | relative_url }}).
- **`check-container-firewall-bypass.sh`** — finds container ports that are
  reachable from your network while your firewall reports them as denied.
  Docker's chains are evaluated before UFW's, so both are true at once. From
  [UFW says the port is closed]({{ '/2026/08/22/docker-publishes-past-ufw/' | relative_url }}).

Also relevant if you're building your own delivery pipeline:
[Stripe retries a failed webhook for three days]({{ '/2026/08/18/stripe-webhook-retries-and-idempotency/' | relative_url }}) — the idempotency bug this toolkit's own delivery Worker hit and fixed.

New scripts are added as new incidents happen — this is a living collection,
not a one-time release.

{% assign live_packs = site.packs | where_exp: "p", "p.buy_url" | where_exp: "p", "p.buy_url != ''" %}{% if live_packs.size > 0 %}
## Pick the checks you need — $5 each

Each pack answers one question and contains only the scripts for it. Buy the one
that matches what you are about to do; you are not paying for checks that do not
apply to your machine.

{% for p in live_packs %}
<div class="callout">
  <h3>{{ p.title }} — {{ p.price }}</h3>
  <p><strong>{{ p.question }}</strong></p>
  <p>{{ p.detail }}</p>
  <a class="btn" href="{{ p.buy_url }}">Buy {{ p.title }} &rarr;</a>
</div>
{% endfor %}

Every script in every pack is also in the complete toolkit below, so there is no
reason to buy both.

{% endif %}{% assign pack_total = live_packs.size | times: 5 %}<div class="callout">
  <h3>Get everything &mdash; $15</h3>
  <p>
    Every script in the toolkit, including the ones that are not in any pack.
    {% if live_packs.size > 3 %}Buying the {{ live_packs.size }} packs separately is
    ${{ pack_total }}, so this is the cheaper route if you want more than two of
    them.{% endif %} One-time purchase: the download link is emailed to you
    immediately, and every script added later is part of the same purchase.
  </p>
  <a class="btn" href="https://buy.stripe.com/14A28qgrW6WE0hB6uI5Vu06">Buy the toolkit &rarr;</a>
</div>
