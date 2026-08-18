---
title: "Raspberry Pi OS Trixie throws away your logs on reboot, and /var/log/journal exists anyway to reassure you it doesn't"
date: 2026-08-18
excerpt: "Stock Trixie ships a vendor drop-in setting Storage=volatile, so the journal lives in RAM and dies on reboot. The empty /var/log/journal directory sitting there makes it look like persistence is already on. And the fix everyone posts is incomplete."
---

**TL;DR**: Raspberry Pi OS Trixie ships `/usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf` with `Storage=volatile`. Your journal lives in RAM and is gone after a reboot — exactly when you need it. `/var/log/journal/` exists but stays empty, which makes it look like persistence is already working. Fixing it takes a drop-in **and** a flush; the drop-in alone silently does nothing until the next boot.

## The symptom

Your Pi does something bad — crash-loops, drops off the network, wedges. You reboot it to get back in, then go looking for what happened:

```bash
journalctl -b -1
```

```
Specifying boot ID or boot offset has no effect, no persistent journal was found.
```

The logs from the boot you actually care about do not exist. They never made it to disk.

## Why it's easy to convince yourself this is already fine

Two things conspire here.

**First, the directory exists.** `/var/log/journal/` is present on a stock Trixie install:

```bash
$ ls -la /var/log/journal/
total 8
drwxr-sr-x+ 2 root systemd-journal 4096 Jun 18 09:19 .
drwxr-xr-x  6 root root            4096 Aug 16 18:31 ..
```

For years, the canonical way to enable persistent journald has been "create `/var/log/journal` and it starts persisting". The directory's presence is normally *the* signal that persistence is on. Here it's present and empty, and the emptiness reads as "nothing has been logged yet" rather than "nothing will ever be written here".

**Second, the default config file agrees with you.** `/etc/systemd/journald.conf` — the file you'd naturally open to check — says:

```
#Storage=auto
```

Commented out, default `auto`. And `auto` means "persist if `/var/log/journal` exists", which it does. So the config file you inspected and the directory you found both say persistence should be working.

Neither of them is where the decision is being made.

## Where the decision actually is

```bash
$ ls /usr/lib/systemd/journald.conf.d/
40-rpi-volatile-storage.conf
syslog.conf

$ cat /usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf
[Journal]
Storage=volatile
```

A vendor drop-in, shipped by the distro, overriding the default you read in the main config file. Drop-ins in `/usr/lib/systemd/journald.conf.d/` take precedence over `/etc/systemd/journald.conf`, so `volatile` wins and the journal is written to `/run/log/journal/` — a tmpfs — instead.

The reasoning behind the default is defensible: it protects SD cards from log write wear, which is a real failure mode on Pis. The problem isn't the choice, it's that the choice is invisible from every place you'd normally look.

Don't guess at precedence. Ask systemd what it actually resolved:

```bash
systemd-analyze cat-config systemd/journald.conf
```

That prints every file in load order with its contents, so you can see exactly which line won.

## The fix everyone posts, and why it isn't enough

The advice you'll find in forum threads is: add a higher-priority drop-in under `/etc`. That part is right:

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\n' | sudo tee /etc/systemd/journald.conf.d/99-persistent-storage.conf
sudo systemctl restart systemd-journald
```

Then check:

```bash
$ journalctl --header | grep 'File path'
File path: /run/log/journal/<machine-id>/system.journal
```

Still `/run`. The setting is correct — `systemd-analyze cat-config` confirms `Storage=persistent` is winning — and the journal is *still in RAM*. Restarting the service was not enough.

What's missing is the flush. Moving the journal from the runtime location to the persistent one is a distinct operation, normally performed at boot by `systemd-journal-flush.service`. Change the setting mid-session and nothing triggers it:

```bash
sudo journalctl --flush
```

```
$ journalctl --header | grep 'File path'
File path: /var/log/journal/<machine-id>/system.journal
File path: /var/log/journal/<machine-id>/user-1000.journal
```

Now it's real.

This is the part that makes the bug expensive. Without the flush, the drop-in *does* take effect — at the next reboot. So if you apply the incomplete fix, verify it by checking `journalctl --header`, and see `/run`, you'll reasonably conclude your drop-in didn't work and start debugging precedence rules that are already correct.

## On the filename everyone tells you to use

Forum threads specify the override must be named `99-something.conf`, on the grounds that it has to sort after the vendor file to win.

The sorting rule is real. The number isn't. On the image checked here (2026-06-18 Trixie arm64 Lite) the vendor file is **`40-`**, not the `70-` those threads describe. Anything above `40-` wins, so `50-` would do.

`99-` is still the right choice — not because `40-` demands it, but because it survives the vendor renaming the file, which apparently already happened once. Just don't take the specific number in a forum post as fact about your system. Check:

```bash
ls /usr/lib/systemd/journald.conf.d/
```

## The trade-off you're accepting

Turning this on means writing logs to your boot media continuously. The vendor default exists for a reason: on a Pi running from an SD card, that's real wear on a device that's already the most common hardware failure point.

Worth turning on if you boot from an SSD or NVMe, or if you're debugging something that survives reboots. Worth thinking twice about on a plain SD card — and if you do enable it there, cap the size so it can't grow without bound:

```
[Journal]
Storage=persistent
SystemMaxUse=200M
```

## The generalisable habit

Three separate things pointed at "persistence is on": the directory existed, the main config said `auto`, and after the first fix attempt the config resolution confirmed `persistent`. All three were true. None of them described where log bytes were actually being written.

`journalctl --header` was the only thing that reported the live state — the actual open file — and it's the check worth building the habit around. Config tells you intent. Headers tell you reality. When they disagree, something in between hasn't run yet.
