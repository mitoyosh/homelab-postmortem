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
- **`check-wifi-autoconnect-block.sh`** — tells you whether NetworkManager
  will bring WiFi back on its own after one failed WPA handshake. On Trixie it
  will not: the profile is blocked from autoconnect and a headless Pi stays
  offline until someone runs `nmcli connection up`. Reports exposure and, on
  request, installs the 30-second timer that does it for you. From
  [One failed WPA handshake and a headless Pi on Trixie stays off WiFi]({{ '/2026/09/18/trixie-networkmanager-one-failed-handshake-and-the-pi-stays-off-wifi/' | relative_url }}).
- **`check-nmcli-provisioning.sh`** — flags the `nmcli` abbreviation that
  NetworkManager 1.52 made ambiguous, and WiFi profiles left with no key
  management that look configured and can never associate. From
  [A new NetworkManager property broke a decade of scripts]({{ '/2026/08/19/nmcli-abbreviation-ambiguity-trixie/' | relative_url }}).
- **`check-cloudinit-ssh-import.sh`** — catches a cloud-init `ssh_import_id`
  that will never be read, before you flash the card and find out the
  headless way. From
  [cloud-init calls your user-data valid]({{ '/2026/08/29/cloud-init-validates-the-key-it-never-reads/' | relative_url }}).
- **`check-llama-cache-ram.sh`** — tells you whether a running `llama-server`
  uses `--cache-ram -1`, documented as "no limit": it keeps less than the
  default on dense models and has no memory bound on hybrid ones. From
  [llama-server's `--cache-ram -1` is not "no limit"]({{ '/2026/09/24/llama-server-cache-ram-minus-one-is-not-no-limit/' | relative_url }}).
- **`check-decision-temperatures.sh`** — lists calibration temperatures in Laya
  checkpoints and edgejev builds that make a decision model's confidence
  meaningless — the English checkpoint's 0.1 for 11+-option questions, which
  laya clamps at load time but ports inherit from the file. From
  [The Laya checkpoint still ships a 0.1 temperature]({{ '/2026/09/26/laya-onnx-port-skips-the-temperature-clamp/' | relative_url }}).
- **`check-ollama-gpu-overhead.sh`** — checks whether the VRAM you reserved
  with `OLLAMA_GPU_OVERHEAD` is actually left free. Ollama 0.34.x prints the
  reservation in its log, but the llama-server runner that places the layers
  never receives it; the script measures free VRAM with a model loaded and
  prints the `LLAMA_ARG_FIT_TARGET` to set instead. From
  [Ollama 0.34 logs your OLLAMA_GPU_OVERHEAD reservation as applied]({{ '/2026/09/28/ollama-gpu-overhead-is-logged-but-never-reaches-llama-server/' | relative_url }}).
- **`check-ollama-v1-sampling.sh`** — lists the Ollama models whose
  `temperature`, `top_p` or penalties the OpenAI-compatible API replaces when a
  client leaves them out, while `ollama show` keeps printing the model's
  values; `--probe` measures it on your server. From
  [Ollama's OpenAI-compatible API replaces your model's temperature and top_p with 1.0]({{ '/2026/09/29/ollama-openai-api-replaces-your-model-temperature-with-1/' | relative_url }}).
- **`check-eog-text-tokens.sh`** — finds end-of-generation tokens that
  plain text can produce, for a model in your own llama.cpp build: entries the
  build forced into its stop list because of how they are spelled. On PLaMo-2
  and PLaMo-3 that is the closing strikethrough tag, and output stops at it with
  `finish_reason: "stop"`. From
  [llama.cpp picks stop tokens partly by their spelling]({{ '/2026/09/29/llama-cpp-stops-plamo-at-the-first-closing-s-tag/' | relative_url }}).
- **`check-llama-sleep-race.sh`** — finds `llama-server` processes and router
  presets with `--sleep-idle-seconds` on, where a request that arrives just
  before the server sleeps is left in the queue or crashes it, and says whether
  systemd would restart it. From
  [llama-server's sleep mode loses, or crashes on, a request that arrives just before it sleeps]({{ '/2026/10/03/llama-server-sleep-mode-loses-or-crashes-on-a-request-at-bedtime/' | relative_url }}).
- **`check-ollama-schema-order.sh`** — sends a two-key JSON schema in reverse
  alphabetical order to each Ollama model and reports whether the output kept
  the declared order; on Ollama's native chat path it doesn't. From
  [On one of Ollama's two chat paths, your JSON schema's keys are re-sorted]({{ '/2026/10/03/ollama-native-chat-path-sorts-your-json-schema-keys/' | relative_url }}).
- **`check-ollama-format-think.sh`** — sends short prompts to a thinking model
  with `think: true` and a JSON schema, and reports how many replies skipped
  thinking and came back outside the schema. From
  [With think enabled, Ollama only enforces your JSON schema after the model has thought]({{ '/2026/10/05/ollama-thinking-model-skips-your-json-schema-when-it-answers-directly/' | relative_url }}).
- **`check-lora-patterns.py`** — reads LoRA `adapter_config.json` files and
  lists the modules whose `rank_pattern` / `alpha_pattern` give them a scale
  vLLM won't apply, with the factor to fold into `lora_B`. From
  [vLLM serves a LoRA adapter that uses rank_pattern or alpha_pattern at the wrong scale]({{ '/2026/10/03/vllm-ignores-lora-rank-pattern-and-alpha-pattern/' | relative_url }}).
- **`check-embd-determinism.sh`** — tells you whether decoding through
  `llama_batch.embd` gives the same logits every time on your build and model,
  and when it does not, confirms whether the cause is the known heap over-read:
  on M-RoPE models the batch code reads four positions per token from an array
  the header told you to size at one. From
  [llama.cpp reads past your pos array on every embedding batch for an M-RoPE model]({{ '/2026/09/16/llama-cpp-reads-past-your-pos-array-for-embedding-batches-on-mrope-models/' | relative_url }}).
- **`check-tool-param-names.sh`** — finds tool parameters named `type`,
  `description`, `required`, `properties` or `nullable`, which Ollama's gemma4
  renderer never shows the model while still marking them required — so the
  model omits the argument or makes one up. Checks a tools file statically, or
  probes a live server. From
  [Ollama's gemma4 renderer never shows the model a tool parameter named type]({{ '/2026/09/16/ollama-gemma4-drops-tool-parameters-named-type/' | relative_url }}).
- **`check-responses-state.sh`** — tells you whether a Responses-API server
  honours `previous_response_id` or accepts it, returns 200, and forgets the
  conversation. Ollama does the second. From
  [Ollama's Responses API accepts previous_response_id and starts every turn from nothing]({{ '/2026/09/14/ollama-responses-api-drops-previous-response-id/' | relative_url }}).
- **`check-docker-log-integrity.sh`** — tells you whether `docker logs` is
  returning everything on disk, or stopping at a NUL byte with exit 0 and
  hiding the rest. From
  [docker logs stops at a NUL byte and exits 0]({{ '/2026/09/12/docker-logs-stops-at-a-nul-byte-and-exits-0/' | relative_url }}).
- **`check-overlay-sandbox.sh`** — on a Docker swarm node, finds containers
  that are running but have lost their overlay network: failed container starts
  can take the node's join count to zero, and a service retrying on a taken host
  port did it in 20 seconds. Full toolkit only. From
  [A Docker swarm service failing on a taken host port cut every container off its overlay network]({{ '/2026/10/03/docker-swarm-failed-starts-cut-healthy-containers-off-the-overlay/' | relative_url }}).
- **`check-podman-compat-update-restart.sh`** — lists the running Podman
  containers that have no restart policy and probes whether this Podman's
  Docker-compatible `update` endpoint resets the policy to `no` when the body
  omits it — it does on 5.4.2, even for `{}`, while Docker keeps it. From
  [Podman's compat API resets the restart policy on any update that omits it]({{ '/2026/09/18/podman-compat-api-update-resets-the-restart-policy-to-no/' | relative_url }}).
- **`check-podman-subpath-cp.sh`** — lists the Podman containers for which a
  `podman cp` while stopped will read and write the volume root instead of the
  `subpath=` they mount — a different file out, another container's file
  overwritten in. From
  [podman cp on a stopped container ignores the volume's subpath]({{ '/2026/09/26/podman-cp-ignores-volume-subpath-when-the-container-is-stopped/' | relative_url }}).
- **`check-podman-export-idmap.sh`** — lists the Podman containers with their
  own user-namespace mapping, such as rootless `--userns=keep-id` ones, whose
  `podman export` and `podman cp` archives carry every file owner shifted, and
  checks an export without writing it. From
  [Rootless podman export of a keep-id container shifts every file owner]({{ '/2026/09/30/podman-export-of-a-keep-id-container-shifts-every-owner/' | relative_url }}).
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
