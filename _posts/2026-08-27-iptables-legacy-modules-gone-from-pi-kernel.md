---
title: "iptables says your kernel needs upgrading. Upgrading the kernel is what broke it."
date: 2026-08-27
excerpt: "The Pi's 6.18 kernels no longer build the legacy ip_tables modules, but CONFIG_IP_NF_IPTABLES=m is still set — because the symbol that builds them is now called something else. The module directory still looks full, and the error tells you to insmod something that cannot exist."
devto_tags: raspberrypi, linux, networking, docker
---

**TL;DR**: On Raspberry Pi's 6.18 kernel line, `ip_tables.ko`, `iptable_nat.ko` and `iptable_filter.ko` are not built. This is deliberate — legacy iptables was deprecated in favour of nftables. But `CONFIG_IP_NF_IPTABLES=m` is *still set* in the shipped kernel config, because the symbol that actually builds the legacy modules is now the separately-named `CONFIG_IP_NF_IPTABLES_LEGACY`, and that one is unset. So the config appears to promise a module that no longer comes from it, the module directory is still full of `ipt_*` files, and the error you get tells you to upgrade the kernel you just upgraded.

## The symptom

A Pi 4B on the current kernel:

```bash
$ uname -r
6.18.34+rpt-rpi-v8
```

Anything that shells out to legacy `iptables` — a WireGuard container's `PostUp`, a Docker setup pinned to the legacy backend, Waydroid's install script — fails the moment it tries to write a NAT rule. Reproduced directly, with the same binary on both backends:

```bash
$ sudo iptables --version
iptables v1.8.11 (nf_tables)
$ sudo iptables -t nat -L -n
$ echo $?
0
```

Fine. Now switch the alternative, change nothing else, and run the identical command:

```bash
$ sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
$ sudo iptables --version
iptables v1.8.11 (legacy)
$ sudo iptables -t nat -L -n
modprobe: FATAL: Module ip_tables not found in directory /lib/modules/6.18.34+rpt-rpi-v8
iptables v1.8.11 (legacy): can't initialize iptables table `nat': Table does not exist (do you need to insmod?)
Perhaps iptables or your kernel needs to be upgraded.
```

Read that last line again. **The kernel is the newest one available, and upgrading to it is what caused this.** Doing what the error suggests moves you further from a working system, and it is the first thing anyone will try.

## Why it's easy to misdiagnose

The error offers two suggestions and both are dead ends. "Do you need to insmod?" points at a module that will never exist on this kernel; "your kernel needs to be upgraded" points backwards. Neither mentions the word `nftables`, which is the actual answer.

Then you go looking, and the evidence on disk agrees with the error rather than with reality.

**The module directory is not empty.** This is the part that really costs time:

```bash
$ ls -1 /lib/modules/$(uname -r)/kernel/net/ipv4/netfilter/
arpt_mangle.ko.xz
ipt_ah.ko.xz
ipt_ECN.ko.xz
ipt_REJECT.ko.xz
ipt_rpfilter.ko.xz
ipt_SYNPROXY.ko.xz
nf_defrag_ipv4.ko.xz
nf_dup_ipv4.ko.xz
nf_nat_h323.ko.xz
nf_nat_pptp.ko.xz
nf_nat_snmp_basic.ko.xz
nf_reject_ipv4.ko.xz
nf_socket_ipv4.ko.xz
nft_dup_ipv4.ko.xz
nft_fib_ipv4.ko.xz
nf_tproxy_ipv4.ko.xz
nft_reject_ipv4.ko.xz
```

Seventeen files, five of them named `ipt_*`. It looks like a healthy legacy-iptables install. The `ipt_*` entries are *matches and targets* — `REJECT`, `SYNPROXY`, `rpfilter` — and they still ship. What is missing is the three modules that provide the tables those targets would go into, and nothing about the listing draws your eye to an absence.

```bash
$ sudo modprobe -n -v ip_tables
modprobe: FATAL: Module ip_tables not found in directory /lib/modules/6.18.34+rpt-rpi-v8
$ sudo modprobe -n -v iptable_nat
modprobe: FATAL: Module iptable_nat not found in directory /lib/modules/6.18.34+rpt-rpi-v8
$ sudo modprobe -n -v iptable_filter
modprobe: FATAL: Module iptable_filter not found in directory /lib/modules/6.18.34+rpt-rpi-v8
```

**And the kernel config says the module is built.** This is where most people stop and conclude they have found a packaging bug:

```bash
$ grep CONFIG_IP_NF_IPTABLES /boot/config-$(uname -r)
CONFIG_IP_NF_IPTABLES=m
```

`=m` means "build as a loadable module." The module is not there. That looks exactly like a broken kernel build, it is a reasonable thing to file a bug about, and people have — against four separate projects, none of which own the problem.

## What's really going on

The config is not lying. It is answering about a different thing than the one you are asking about, because the meaning of that symbol changed underneath the name.

Two more lines from the same file settle it:

```bash
$ grep -E 'CONFIG_IP_NF_IPTABLES_LEGACY|CONFIG_NFT_COMPAT' /boot/config-$(uname -r)
CONFIG_NFT_COMPAT=m
```

`CONFIG_NFT_COMPAT=m` is present. `CONFIG_IP_NF_IPTABLES_LEGACY` produces no output at all — it is unset, and **that** is the symbol that builds `ip_tables.ko` today. `CONFIG_IP_NF_IPTABLES` kept the historic name and now selects the nftables-backed path instead.

A second machine settles that this is a per-build choice rather than something
inherent to current kernels. On a Proxmox VE 9 host — also Debian 13 underneath,
but x86_64 and running Proxmox's own kernel build:

```bash
$ uname -r
7.0.2-6-pve
$ grep -E '^CONFIG_IP_NF_IPTABLES(_LEGACY)?=' /boot/config-$(uname -r)
CONFIG_IP_NF_IPTABLES_LEGACY=m
CONFIG_IP_NF_IPTABLES=m
$ sudo modprobe -n -v ip_tables
$ echo $?
0
```

`CONFIG_IP_NF_IPTABLES_LEGACY=m` is set there, `ip_tables.ko` is on disk, and
`modprobe` resolves it. Same Debian release, same era, opposite decision. Both
distributions ship their own kernel rather than Debian's stock one, so this is
not "Debian does X and Raspberry Pi does Y" — it is that the symbol is a build
flag each kernel packager decides for themselves, and Raspberry Pi has stopped
setting it while others have not. Which means you cannot carry an assumption
about legacy iptables from one machine to another, even between two boxes
running the same Debian release.

Upstream said so plainly, over six months ago. [Phil Elwell answered this on `raspberrypi/linux#7220`](https://github.com/raspberrypi/linux/issues/7220) in February 2026:

> ip_tables has been deprecated in favour of nf_tables. CONFIG_IP_NF_IPTABLES enables an ip_tables-like shim over nf_tables.

That issue is closed as *completed*, which is worth pausing on: on GitHub, `closed as completed` normally means the bug was fixed. Here it means the question was answered and the behaviour is intended. If you check only the state and not the thread, you will conclude this was fixed and stop looking — and the modules will still be missing.

The nftables side of the same kernel is fully populated — 28 modules matching `nf_tables`/`nft_` under `kernel/net/netfilter/` — so this is not a kernel with its firewalling removed. It is a kernel with exactly one way to do firewalling, and a userspace shim (`iptables-nft`) that makes the old commands work against it.

## Who this actually hits

Not everyone, and the reports do not make that clear.

A stock Raspberry Pi OS Lite install [ships no `iptables` binary at all](https://homelabpostmortem.com/2026/08/22/docker-publishes-past-ufw/) — it arrives as a dependency of something else, usually `ufw`, and `update-alternatives` resolves it to `iptables-nft`. On that path nothing ever touches a legacy module and none of this happens. A default Docker install on a default image does not hit it either.

What hits it is anything that **deliberately selects the legacy backend**, which used to be sound advice:

- Container images whose startup scripts call legacy `iptables` for MASQUERADE/FORWARD rules — this is why WireGuard front-ends broke.
- Distributions and provisioning scripts that pin `update-alternatives` to `iptables-legacy`, a long-standing workaround for older Docker/nftables incompatibilities.

Every one of those was a reasonable decision when it was made. They break now because the thing they pinned to stopped existing, and the failure surfaces inside whichever tool made the call rather than at the pin.

That is also why the fix information is so hard to find. The canonical report is [`wg-easy#2614`](https://github.com/wg-easy/wg-easy/issues/2614), which the maintainers closed as **not planned** — correctly, since it is not their bug. So the thread with twenty comments of people rediscovering the same thing sits in a project that has, accurately, disclaimed it.

## The fix

If you control the alternative, point it at the shim. This is the whole fix for most cases:

```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-nft
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
```

Then restart whatever failed. Verify you are actually on the shim rather than trusting the command's exit code:

```bash
$ sudo iptables --version
iptables v1.8.11 (nf_tables)
```

The `(nf_tables)` in that output is the thing to check. `(legacy)` there means you are still pointed at a backend with no kernel behind it, whatever else looks right.

If the caller is inside a container image you do not control, the alternative is not yours to set — the container has its own userspace. There the answer is to replace the legacy calls with `nft` equivalents in whatever hook the image exposes, which is what the wg-easy threads eventually converged on, or to run the container with host networking so the host's own rules apply.

And before you rely on any of this on a Pi, the check costs nothing:

```bash
modprobe -n -v ip_tables 2>&1
```

`-n` is dry-run: it resolves the module without loading it. If that prints `FATAL: Module ip_tables not found`, then every legacy-iptables tool on that machine is going to fail, and you know it before you have installed one.

## The generalisable habit

The trap here is a config symbol that kept its name while changing what it produces. `CONFIG_IP_NF_IPTABLES=m` was true and useful for years, it is still present, and it now means something else. Nothing in the file marks the change — there is no deprecated flag, no comment, no warning at build time. The only way to see it is to know that a second symbol exists and to look for its absence, and you cannot grep for the absence of a name you have never heard of.

So the habit: **when a config says a thing exists and the thing does not exist, suspect the symbol before you suspect the build.** A missing artifact with a present config is much more often a renamed or re-scoped option than a broken toolchain — the toolchain failing loudly is the common case, and this failed quietly.

The wider one is about reading closed issues. `closed as completed` on an upstream tracker is a strong signal and it is genuinely useful — it correctly killed an investigation for me two days earlier, on this same tracker, where a `bcmgenet` regression really had been fixed and shipped to apt while the reports about it were still circulating. Here the same state on the same tracker meant "answered, working as intended." **The state field tells you the thread is over. It does not tell you which way it ended.** That is in the comments, usually the last few, and there is no way to skip reading them.
