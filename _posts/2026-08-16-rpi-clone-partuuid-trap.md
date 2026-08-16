---
title: "The rpi-clone PARTUUID trap: why your Pi 4B silently refuses to boot from a cloned SSD"
date: 2026-08-16
excerpt: "rpi-clone copies your SD card to a USB SSD beautifully, but it does not update the root=PARTUUID reference in the destination's cmdline.txt. Flip the boot order before catching this and your Pi either boots the wrong disk or fails to boot at all."
---

**TL;DR**: `rpi-clone` copies your SD card to a USB SSD beautifully, but it does *not* update the `root=PARTUUID=...` reference in the destination's `cmdline.txt`. Flip the boot order to USB before catching this, and your Pi either boots the wrong disk or fails to boot at all. Five-minute fix once you know to look for it.

## The setup

Moving a Raspberry Pi's root filesystem off the SD card and onto a USB-attached SSD is one of the highest-value changes you can make to a Pi that's meant to run unattended for months: SD cards wear out under sustained write load, SSDs don't (practically speaking), and boot/IO latency drops noticeably as a bonus.

The standard playbook is:

1. Update the bootloader EEPROM (`sudo rpi-eeprom-update -a`), reboot.
2. Clone the running SD card to the SSD with [`rpi-clone`](https://github.com/billw2/rpi-clone).
3. Flip `raspi-config` → *Advanced Options* → *Boot Order* to prefer USB.
4. Reboot and confirm `findmnt /` shows the SSD.

Steps 1, 3, and 4 are exactly as advertised. Step 2 has a landmine in it.

## What actually happens

`rpi-clone` does a genuinely good job: it partitions the destination to match the source, `rsync`s the filesystem across, and rewrites the destination's `/etc/fstab` with the *destination's own* `PARTUUID`s. If you check `fstab` after cloning, it's correct.

What it does **not** do is touch `/boot/firmware/cmdline.txt` on the destination. That file still contains the **source disk's** `root=PARTUUID=...`, copied verbatim.

This is easy to miss because nothing in the clone process complains. The clone finishes, reports success, and looks done.

## Why it bites you specifically at the worst moment

You won't notice during the clone. You won't notice right after, either — you're still running from the SD card at that point, so everything looks fine. The mismatch only matters the moment the firmware actually tries to boot the kernel *from the SSD*, using the SSD's own `cmdline.txt` — which is exactly what happens right after you flip the boot order and reboot.

At that point the kernel is told "find your root filesystem at PARTUUID `10052bbd-02`" (the SD card's identifier), while the disk it's actually booting from carries an entirely different, freshly-generated PARTUUID (say, `b11c96d4-02`). Depending on whether the SD card is still physically present, you get either a boot that silently falls back to the SD card's root filesystem (confusing — your changes "don't stick"), or a kernel panic waiting for a root device that isn't there (worse).

## How to catch it before rebooting

Right after the clone finishes — **before** you touch the boot order — compare the source and destination PARTUUIDs directly:

```bash
# What the SD card's root partition is actually called
sudo blkid /dev/mmcblk0p2

# What the SSD's root partition is actually called
sudo blkid /dev/sda2

# What the SSD's own boot config *thinks* the root partition is called
sudo mount /dev/sda1 /mnt
grep -o 'root=PARTUUID=[a-f0-9-]*' /mnt/cmdline.txt
```

If the third value matches the first (the SD card's) instead of the second (the SSD's own), you have the bug.

## The fix

```bash
sudo sed -i "s/root=PARTUUID=<OLD_PARTUUID>/root=PARTUUID=<NEW_PARTUUID>/" /mnt/cmdline.txt
```

Then do one more sweep to make sure nothing else on the destination still references the stale identifier — it's a one-liner and costs nothing:

```bash
sudo grep -rl "<OLD_PARTUUID>" /mnt 2>/dev/null
```

If that returns nothing, unmount and reboot into the boot-order change with confidence.

A ready-to-run version of this check-and-fix — with a dry-run mode and an automatic backup of `cmdline.txt` before it touches anything — is in the [toolkit]({{ '/toolkit/' | relative_url }}) that comes with this post.

## The general lesson

Any tool that clones a running system to a new disk has to solve the "how does the new disk know it's the new disk" problem somewhere. Some tools solve it by rewriting every reference at clone time; `rpi-clone` solves *most* of it that way (fstab) but leaves one file (cmdline.txt) untouched. That's not a bug exactly — it's a scope boundary the tool doesn't advertise loudly. The general habit worth keeping: after any disk clone, before changing what your firmware boots from, grep the new disk for the old disk's identifiers. If anything comes back, you've found your landmine before it found you.
