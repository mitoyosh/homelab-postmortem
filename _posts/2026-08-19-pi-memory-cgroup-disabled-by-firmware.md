---
title: "Your Pi accepts every memory limit you set and enforces none of them"
date: 2026-08-19
excerpt: "The memory cgroup controller is off by default on Raspberry Pi OS, so docker --memory, systemd MemoryMax and k3s limits are all accepted and silently ignored. The firmware injects cgroup_disable=memory ahead of your cmdline.txt, and the check most guides give you reports the same thing before and after you fix it."
devto_tags: raspberrypi, docker, linux, containers
---

**TL;DR**: On stock Raspberry Pi OS the memory cgroup controller is disabled, so `docker run --memory=512m`, systemd's `MemoryMax=`, and k3s pod limits are all accepted without complaint and enforced not at all — the kernel has nowhere to write the limit. The disable comes from `cgroup_disable=memory`, which **the firmware injects ahead of your `cmdline.txt`** and which never appears in that file. Adding `cgroup_enable=memory cgroup_memory=1` fixes it, costs no measurable RAM, and needs a reboot. And `/proc/cgroups` — the file a lot of guides tell you to check — prints byte-identical output before and after the fix.

## The symptom

Nothing errors. That's the entire problem.

On a Pi 4B running Trixie (`6.18.34+rpt-rpi-v8`), ask systemd to cap a process at 100 MB:

```bash
$ systemd-run --user --scope -p MemoryMax=100M sleep 30
Running as unit: run-p1753-i1754.scope; invocation ID: f8ecc5cb8b884fd68fd9eb2cccbdb72d
```

No warning. Ask systemd whether the limit is in place, and it says yes:

```bash
$ systemctl --user show run-p1753-i1754.scope -p MemoryMax -p MemoryAccounting
MemoryAccounting=yes
MemoryMax=104857600
```

104857600 bytes. Exactly the 100 MB requested. Except the limit does not exist, because there is nowhere to put it:

```bash
$ ls /sys/fs/cgroup/user.slice/user-1000.slice/session-22.scope/
cgroup.controllers   cgroup.max.depth        cgroup.stat.local
cgroup.events        cgroup.max.descendants  cgroup.subtree_control
cgroup.freeze        cgroup.procs            cgroup.threads
cgroup.kill          cgroup.stat             cgroup.type
```

There is no `memory.max` file in that directory. There is no `memory.` anything. systemd reported a limit it had no way to apply, and reported it as successfully set.

The same applies to `docker run --memory=512m` and to k3s pod memory limits. This is not a Docker bug — it's one layer below Docker, which is why it hits every container runtime on the platform.

## What's really going on

The memory controller isn't in the active set:

```bash
$ cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io pids
```

`cpuset`, `cpu`, `io`, `pids` — no `memory`. So the natural next step is to look at the kernel command line, and this is where it gets interesting:

```bash
$ cat /boot/firmware/cmdline.txt
console=serial0,115200 console=tty1 root=PARTUUID=b11c96d4-02 rootfstype=ext4 fsck.repair=yes rootwait ds=nocloud;i=rpi-imager-1786770245730 cfg80211.ieee80211_regdom=JP
```

Nothing about cgroups at all. No `cgroup_disable`, no `cgroup_enable`. If `cmdline.txt` is your model of the kernel command line, there is nothing here to explain the missing controller.

`cmdline.txt` is not the kernel command line. It's a fragment the firmware appends to its own. Here is what the kernel actually received:

```bash
$ cat /proc/cmdline
coherent_pool=1M 8250.nr_uarts=0 snd_bcm2835.enable_headphones=0 cgroup_disable=memory numa_policy=interleave nvme.max_host_mem_size_mb=32 ... console=ttyS0,115200 console=tty1 root=PARTUUID=b11c96d4-02 ... cfg80211.ieee80211_regdom=JP
```

`cgroup_disable=memory`, fourth parameter in, put there by the firmware. It is not in any file on the boot partition. You cannot grep for it in `/boot/firmware/` and find it. The only place it is visible is `/proc/cmdline`, after boot.

This is a deliberate platform default, not an accident — the memory controller has a small per-page overhead, and Pi images have historically optimised for the machine having as much usable RAM as possible. The request to flip it for 64-bit Lite builds was filed as [RPi-Distro/pi-gen#917](https://github.com/RPi-Distro/pi-gen/issues/917) and closed **not planned** in April 2026. It isn't going to change upstream, so every Pi that runs containers has to fix it locally.

## The check that lies to you

A lot of guides tell you to inspect `/proc/cgroups`. On this machine, before the fix:

```
#subsys_name	hierarchy	num_cgroups	enabled
cpuset	0	44	1
cpu	0	44	1
cpuacct	0	44	1
blkio	0	44	1
devices	0	44	1
freezer	0	44	1
net_cls	0	44	1
perf_event	0	44	1
net_prio	0	44	1
pids	0	44	1
```

No `memory` row — consistent with the problem, so far so good. After the fix, rebooted, with the controller confirmed working:

```
#subsys_name	hierarchy	num_cgroups	enabled
cpuset	0	75	1
cpu	0	75	1
cpuacct	0	75	1
blkio	0	75	1
devices	0	75	1
freezer	0	75	1
net_cls	0	75	1
perf_event	0	75	1
net_prio	0	75	1
pids	0	75	1
```

Still no `memory` row. Same ten subsystems, same order. The only thing that changed is a counter.

`/proc/cgroups` reports cgroup **v1** subsystems, and this system runs a pure v2 unified hierarchy:

```bash
$ stat -fc %T /sys/fs/cgroup
cgroup2fs
$ mount | grep ' /sys/fs/cgroup '
cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot)
```

So `/proc/cgroups` is answering a question about a hierarchy this machine doesn't use. It is not wrong, it's irrelevant — and it is irrelevant in a way that looks exactly like a failed fix. Check `/sys/fs/cgroup/cgroup.controllers` instead. That one changes.

## The fix

Append two parameters to `cmdline.txt`. It must stay a **single line** — a stray newline here is a machine that doesn't boot, so back it up first and read it back before rebooting:

```bash
sudo cp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak-$(date +%Y%m%d%H%M%S)
sudo sed -i 's/$/ cgroup_enable=memory cgroup_memory=1/' /boot/firmware/cmdline.txt
cat /boot/firmware/cmdline.txt          # one line, params at the end
awk 'END{print NR}' /boot/firmware/cmdline.txt   # must print 1
```

While you're in there, confirm `root=PARTUUID=` still matches the disk you actually boot from — `blkid -s PARTUUID -o value /dev/sda2` — because if that's ever been wrong you'll find out at the same reboot and misattribute it to this change.

Then reboot, and verify against the right file:

```bash
$ cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io memory pids
```

`memory` is now present. The end-to-end check is that a limit lands somewhere real:

```bash
$ systemd-run --user --scope -q -p MemoryMax=100M bash -c \
    'CG=$(cut -d: -f3 /proc/self/cgroup); echo memory.max=$(cat /sys/fs/cgroup$CG/memory.max)'
memory.max=104857600
```

Before the fix that file did not exist. Now it holds the number.

Note what the fix is actually doing. `cgroup_disable=memory` is still on the kernel command line — the firmware still injects it:

```bash
$ cat /proc/cmdline | tr ' ' '\n' | grep cgroup
cgroup_disable=memory
cgroup_enable=memory
cgroup_memory=1
```

You are not removing the disable. You are overriding it by landing later on the command line, which works precisely because `cmdline.txt` is appended after the firmware's own parameters. That ordering is the whole reason a two-word edit is sufficient.

The RAM cost people worry about did not materialise here — `free -m` reported a total of 3794 MB both before and after.

## The generalisable habit

The reflex worth building: **the config file you edit is not always the config the system reads.** `cmdline.txt` reads like the kernel command line — it has the right shape, the right contents, the right name. It is a fragment. The authoritative version lived at `/proc/cmdline` the whole time, and one look at it turns an unexplained missing controller into an obvious `cgroup_disable=memory`.

The narrower lesson is about verification. Two different files here will tell you about cgroups, and only one of them is about the hierarchy your machine actually runs. Picking the wrong one gives you a confident, stable, identical answer before and after a fix that worked. When a check shows no change after a change you believe in, consider that the check may be measuring the wrong thing before concluding the fix failed — the previous [journald](https://homelabpostmortem.com/2026/08/18/trixie-journald-volatile-logs/) and [swap](https://homelabpostmortem.com/2026/08/19/trixie-rpi-swap-writeback-file/) posts on this site are the same shape, and that's three for three on this platform.

And the one that costs real money in production: a limit that is accepted is not a limit that is enforced. If you rely on `--memory` to stop one container taking down a box, verify once that the enforcement path exists. `systemd-run` will tell you in a single command, without installing anything.
