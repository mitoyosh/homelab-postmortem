---
title: "Your Pi's 2 GB swap file isn't swap, and no swap command will tell you that"
date: 2026-08-19
excerpt: "Trixie replaced dphys-swapfile with rpi-swap, which defaults to a zram+file hybrid. /var/swap still exists and still costs you 2 GB of disk, but it is zram's writeback target, not a swap area — so swapon, free and /proc/swaps all show the same thing whether the file is there or not."
devto_tags: raspberrypi, linux, sysadmin, debugging
---

**TL;DR**: Raspberry Pi OS Trixie ships `rpi-swap` instead of `dphys-swapfile`, defaulting to a `zram+file` hybrid. `/var/swap` is still there and still costs 2 GB of real disk, but it is zram's *writeback target*, not a swap area — so it never appears in `swapon`, `free`, or `/proc/swaps`. On the reference Pi that file was 43% of all disk in use, and every swap tool reported the identical output with it present and with it gone. The only way to see the link is `/sys/block/zram0/backing_dev`. Config moved to `/etc/rpi/swap.conf`, and changes need a full reboot — `systemctl daemon-reload` applies nothing and reports no error.

## The symptom

There isn't a crash here. That's what makes it worth writing down: the numbers just quietly stop adding up.

A stock Trixie install on a Pi 4B with 3.7 GB of RAM, booting from a USB SSD:

```bash
$ free -h
               total        used        free      shared  buff/cache   available
Mem:           3.7Gi       220Mi       2.8Gi        35Mi       802Mi       3.5Gi
Swap:          2.0Gi          0B       2.0Gi
```

2 GB of swap. Fine. And there's a swap file where you'd expect one:

```bash
$ ls -lh /var/swap
-rw------- 1 root root 2.0G Aug 16 23:01 /var/swap
```

Also 2 GB. So that's the swap, sitting in a file, exactly as it's worked for the last decade.

Except it isn't, and those two 2 GB figures are not the same 2 GB.

```bash
$ swapon --show
NAME       TYPE      SIZE USED PRIO
/dev/zram0 partition   2G   0B  100

$ cat /proc/swaps
Filename        Type       Size      Used  Priority
/dev/zram0      partition  2097148   0     100
```

The only swap device on the machine is `/dev/zram0` — compressed RAM. The 2 GB file does not appear in the swap tables at all. But it is fully allocated on disk, not sparse:

```bash
$ du -h --apparent-size /var/swap && du -h /var/swap
2.0G	/var/swap
2.1G	/var/swap
```

On this machine, that's 43% of everything on the disk:

```bash
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2       219G  4.7G  203G   3% /
```

4.7 GB used, 2.1 GB of which is a file that no swap command acknowledges. On a 32 GB SD card the same file is 6.3% of the entire card.

## What's really going on

Trixie replaced `dphys-swapfile` with a new package. The old one is not installed, not deprecated-but-present — simply gone:

```bash
$ dpkg -l | grep -E 'dphys-swapfile|rpi-swap'
ii  rpi-swap  1.2.2  all  early-boot swap configuration

$ command -v dphys-swapfile
$ ls /etc/dphys-swapfile
ls: cannot access '/etc/dphys-swapfile': No such file or directory
```

`rpi-swap` defaults to a mechanism called `zram+file`, and `swap.conf(5)` is direct about what that means:

> **zram+file**: A compressed RAM-based swap device is created, with the file specified in File::Path used for writeback storage. The file is not used as a traditional swap device; instead, zram occasionally writes idle pages to it to free up RAM, reducing SD card wear through infrequent writes.

So the file's job is to be somewhere zram can evict cold pages to. You can watch the chain yourself:

```bash
$ cat /sys/block/zram0/backing_dev
/dev/loop0

$ losetup -a
/dev/loop0: []: (/var/swap)
```

`zram0` → `loop0` → `/var/swap`. That's the entire relationship, and `/sys` is the only place it's visible. It is a real mechanism doing a sensible thing — batching writes to spare the SD card — and the writeback timer is genuinely running on a 24-hour cycle:

```bash
$ systemctl list-timers rpi-zram-writeback.timer
NEXT                        LEFT LAST                        PASSED UNIT
Wed 2026-08-19 23:01:49 JST  15h Tue 2026-08-18 23:01:49 JST 8h ago rpi-zram-writeback.timer
```

The 2 GB zram size is also not arbitrary. With `RamMultiplier=1` on a 3794 MiB machine you'd expect ~3.7 GB, but `MaxSizeMiB` defaults to 2048 and caps it. Both defaults are visible, commented out, in `/etc/rpi/swap.conf`.

## Why it's easy to misread

Every tool that has ever answered "how much swap do I have and where does it live" answers this configuration wrongly, or at least uselessly.

`free` reports 2.0Gi of swap. True — that's zram's decompressed capacity. It says nothing about the 2 GB on disk. `swapon` and `/proc/swaps` list `/dev/zram0` and stop. `ls /var/swap` shows a 2 GB file that looks exactly like the swap file that has been on Pis for years. Put those together and the obvious reading is "2 GB of swap, stored in /var/swap" — which is wrong in a way that no single command contradicts.

The strongest demonstration of this: I switched the machine to `Mechanism=zram`, rebooted, and compared. The file was removed and 2 GB of disk came back:

```
                    before      after
/var/swap           2.0G        (deleted)
df / used           4.7G        2.7G
backing_dev         /dev/loop0  none
```

And `swapon --show`:

```
NAME       TYPE      SIZE USED PRIO
/dev/zram0 partition   2G   0B  100
```

Byte-for-byte identical output, before and after. The swap subsystem was reconfigured, 2 GB of disk changed hands, and the tool you'd use to check swap could not tell the two states apart.

None of this is undocumented — `swap.conf(5)` is clear and thorough. But nothing routes you to the man page for a package you didn't know was installed, replacing a package you assumed still existed.

## The other half: nothing applies until you reboot

`swap.conf(5)` warns about this, and it's worth confirming because it is the part that will bite a provisioning script rather than a person:

> **WARNING**: After modifying any swap configuration, you must reboot the system for changes to take effect.
>
> While running `systemctl daemon-reload` after configuration changes will generate new swap units, existing swap units are not typically stopped by systemd, and new units will not be started automatically as they are pulled in by `swap.target` which has already been reached during boot.

Observed exactly as described. With a drop-in in place selecting `Mechanism=zram`, after `systemctl daemon-reload`:

```bash
$ cat /etc/rpi/swap.conf.d/90-test-zram-only.conf
[Main]
Mechanism=zram

$ sudo systemctl daemon-reload
$ ls -lh /var/swap
-rw------- 1 root root 2.0G Aug 16 23:01 /var/swap
$ cat /sys/block/zram0/backing_dev
/dev/loop0
$ df -h --output=used / | tail -1
 4.7G
```

Nothing changed. No error, no warning, no non-zero exit. The config was valid and correctly placed; it simply does not take effect until `rpi-swap`'s generator runs during early boot. A script that writes a drop-in, reloads, checks the exit code and reports success will report success — and be wrong until something reboots the box, possibly weeks later.

This is the same shape as the [journald volatile-storage problem](https://homelabpostmortem.com/2026/08/18/trixie-journald-volatile-logs/) on the same OS: a correct config change that produces no visible effect and no error until a second, separate step happens.

## The fix

First, find out what's actually managing swap before trusting any tutorial:

```bash
dpkg -l | grep -E 'dphys-swapfile|rpi-swap'
swapon --show
cat /sys/block/zram0/backing_dev 2>/dev/null   # a path here means zram+file
losetup -a                                      # resolves that path to the real file
```

If `backing_dev` names a loop device, you have a writeback file consuming disk that won't show up in any swap listing.

To change it, write a drop-in rather than editing the main file — `/etc/rpi/swap.conf.d/` is read after `/etc/rpi/swap.conf`, sorted lexicographically across all the config directories, last-one-wins:

```bash
sudo mkdir -p /etc/rpi/swap.conf.d/
sudo tee /etc/rpi/swap.conf.d/90-local-swap.conf > /dev/null <<'EOF'
[Main]
Mechanism=zram
EOF
sudo reboot
```

`Mechanism=` takes `auto`, `swapfile`, `zram`, `zram+file`, or `none`. `zram` keeps compressed-RAM swap and drops the writeback file. `swapfile` gives you the traditional pre-Trixie behaviour back. `none` removes swap entirely and deletes the file.

To resize rather than switch mechanism, `FixedSizeMiB` under `[File]` or `[Zram]` sets an exact size and overrides the `RamMultiplier` calculation. Undo is just deleting the drop-in and rebooting — that restored this machine to stock, `/var/swap` and all, in one boot.

The reboot is not optional and not a formality. Verify after it, not before.

## The generalisable habit

The failure mode worth extracting isn't "Trixie changed swap." It's that **a tool's output can stay identical across a change it doesn't model.** `swapon` isn't broken or lying; it reports swap areas, and a writeback device isn't one. It answers its own question correctly while the question you actually had — "where did my disk go" — goes unanswered by every tool you'd naturally reach for.

That's the class of thing worth a reflex: when a number doesn't reconcile, don't re-run the tool that already gave you an answer you don't believe. Go to the layer underneath it. Here that's `/sys/block/zram0/backing_dev` and `losetup -a` — two commands nobody thinks of as swap commands, which is precisely why the link stays invisible.

The related habit: when a package you rely on is missing, check what replaced it before concluding your install is broken. `dphys-swapfile: command not found` reads like damage. It's a deliberate migration with a man page.
