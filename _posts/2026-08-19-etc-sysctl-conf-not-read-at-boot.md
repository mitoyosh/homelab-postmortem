---
title: "sysctl -p says it worked. The next reboot disagrees."
date: 2026-08-19
excerpt: "On Raspberry Pi OS Trixie, /etc/sysctl.conf does not exist and is not read at boot — systemd-sysctl only reads the .d directories. The procps sysctl CLI still reads it, so sysctl -p applies your change and reports success, and the setting silently disappears on the next reboot with nothing logged."
devto_tags: raspberrypi, linux, systemd, sysadmin
---

**TL;DR**: `/etc/sysctl.conf` doesn't ship on Raspberry Pi OS Trixie, and if you create it, the thing that runs at boot — `systemd-sysctl` — never reads it. The `sysctl` CLI from procps still does, so `sudo sysctl -p` applies your setting and prints it back at you like it worked. It did work, until the next reboot. Verified both directions on hardware: identical content in `/etc/sysctl.conf` and `/etc/sysctl.d/99-local.conf`, one ignored at boot, one applied. `systemd-sysctl.service` exits `0/SUCCESS` either way.

## The symptom

You want a kernel parameter to stick. Every guide written in the last fifteen years says the same thing: put it in `/etc/sysctl.conf`, run `sysctl -p`. So:

```bash
$ sudo sh -c 'printf "vm.swappiness = 42\n" > /etc/sysctl.conf'
$ sudo sysctl -p
vm.swappiness = 42
$ cat /proc/sys/vm/swappiness
42
```

The tool echoes the setting back. The kernel confirms it. This is as clear a success signal as Linux gives you.

Reboot, and the file is still sitting there, unchanged:

```bash
$ cat /etc/sysctl.conf
vm.swappiness = 42
$ cat /proc/sys/vm/swappiness
60
```

Back to the default. Nothing removed the file. Nothing rewrote it. It was simply never read.

## Why it's easy to misdiagnose

The first thing you'd suspect is that something overrode you later in boot, so you'd go looking for a conflicting drop-in and find nothing relevant:

```bash
$ ls /etc/sysctl.d/
98-rpi.conf  README.sysctl
$ cat /etc/sysctl.d/98-rpi.conf
kernel.printk = 3 4 1 3
vm.min_free_kbytes = 16384
net.ipv4.ping_group_range = 0 2147483647
```

No `vm.swappiness` anywhere. Nothing competing with your setting.

The second thing you'd check is whether the service that applies sysctls failed. It didn't:

```bash
$ systemctl status systemd-sysctl.service
● systemd-sysctl.service - Apply Kernel Variables
     Loaded: loaded (/usr/lib/systemd/system/systemd-sysctl.service; static)
     Active: active (exited) since Wed 2026-08-19 12:11:49 JST
   Main PID: 323 (code=exited, status=0/SUCCESS)

$ journalctl -b -u systemd-sysctl.service
Aug 19 12:11:49 mitoyosh-pi4b systemd[1]: Finished systemd-sysctl.service - Apply Kernel Variables.
```

Exit status 0. One log line, and it says "Finished". There is no warning that a file was skipped, because from `systemd-sysctl`'s point of view no file was skipped — it read every file it knows about, and `/etc/sysctl.conf` is not one of them.

There's a third clue that isn't there either: on a stock Trixie image, **`/etc/sysctl.conf` doesn't exist in the first place**.

```bash
$ ls -la /etc/sysctl.conf
ls: cannot access '/etc/sysctl.conf': No such file or directory
```

`procps` ships `/etc/sysctl.d/` and a `README.sysctl`, but not the file itself. So you don't edit an existing file with existing content — you create a new one, from scratch, at a path the boot process ignores. Nothing about that act feels like it needs verifying.

## What's really going on

Two different programs are called "sysctl" here, and they disagree about which files matter.

**At boot**, systemd runs its own implementation:

```bash
$ systemctl cat systemd-sysctl.service | grep ExecStart
ExecStart=/usr/lib/systemd/systemd-sysctl
```

That binary contains exactly four config paths:

```bash
$ strings /usr/lib/systemd/systemd-sysctl | grep -E '^/(etc|run|usr)/.*sysctl'
/etc/sysctl.d
/run/sysctl.d
/usr/lib/sysctl.d
/usr/local/lib/sysctl.d
```

Four directories. `/etc/sysctl.conf` is not among them, and `sysctl.d(5)`'s SYNOPSIS lists the same four. The boot-time path has no concept of that file.

**From your shell**, `sysctl` is a different program entirely — `/usr/sbin/sysctl`, from procps. Its `--system` precedence list *does* include the file, last:

```
/etc/sysctl.d/*.conf
/run/sysctl.d/*.conf
/usr/local/lib/sysctl.d/*.conf
/usr/lib/sysctl.d/*.conf
/lib/sysctl.d/*.conf
/etc/sysctl.conf
```

And plain `sysctl -p` with no argument defaults to reading `/etc/sysctl.conf` specifically. So the interactive tool honours the file, the boot process doesn't, and the gap between them is exactly one reboot wide.

On many Debian systems this is papered over by a compatibility symlink at `/etc/sysctl.d/99-sysctl.conf` pointing back to `/etc/sysctl.conf`, which drags the file into a directory systemd does read. This image doesn't have one:

```bash
$ ls -la /etc/sysctl.d/99-sysctl.conf
ls: cannot access '/etc/sysctl.d/99-sysctl.conf': No such file or directory
```

Worth checking on your own machine before assuming either way — its presence or absence is the whole difference.

## The demonstration

Run the boot-time binary by hand and you can watch it ignore the file, without waiting for a reboot. Start from the file in place and the value at its default:

```bash
$ cat /etc/sysctl.conf
vm.swappiness = 42
$ cat /proc/sys/vm/swappiness
60
$ sudo /usr/lib/systemd/systemd-sysctl
$ cat /proc/sys/vm/swappiness
60
```

No output, no error, no change. Now put byte-identical content in the directory it does read:

```bash
$ sudo sh -c 'printf "vm.swappiness = 42\n" > /etc/sysctl.d/99-local-test.conf'
$ sudo /usr/lib/systemd/systemd-sysctl
$ cat /proc/sys/vm/swappiness
42
```

Same setting, same syntax, same nineteen bytes. The only variable is which path it sits at.

And the end-to-end version — drop-in removed, `/etc/sysctl.conf` left in place, real reboot:

```bash
$ ls /etc/sysctl.d/
98-rpi.conf  README.sysctl
$ cat /etc/sysctl.conf
vm.swappiness = 42
$ cat /proc/sys/vm/swappiness
60
```

## The fix

Put it in `/etc/sysctl.d/` and give it a numeric prefix:

```bash
sudo sh -c 'printf "vm.swappiness = 42\n" > /etc/sysctl.d/99-local.conf'
sudo /usr/lib/systemd/systemd-sysctl        # apply now, same as boot will
cat /proc/sys/vm/swappiness                 # verify it took
```

Files across all the sysctl directories are sorted lexicographically by filename regardless of which directory they're in, and the last one to set a given key wins. `99-` puts you after the vendor's `98-rpi.conf`, which is what you want if you ever need to override one of its three settings.

Two things worth doing differently from the old habit:

- **Apply with `systemd-sysctl`, not `sysctl -p`.** Not because `sysctl -p` is broken, but because running the boot-time binary tests the boot-time path. If it applies now, it will apply at boot. `sysctl -p` proves less than it appears to.
- **Verify by reading `/proc/sys/...`, not by trusting the command's output.** `sysctl -p` echoing your setting back means it parsed your file, not that the value survives.

If you have an existing `/etc/sysctl.conf` from an older install or a config-management tool, the minimal migration is to make the file visible to systemd rather than move its contents:

```bash
sudo ln -s /etc/sysctl.conf /etc/sysctl.d/99-sysctl.conf
```

That's the same compatibility symlink other Debian systems ship, and it's the smallest change that makes both tools agree.

## The generalisable habit

The trap here isn't the missing file. It's that **the tool you use to apply a config and the code that applies it at boot were two different programs with two different opinions**, and only one of them ever spoke to you.

`sysctl -p` isn't lying. It read the file you gave it and set the value, and it said so. It just has no authority over what happens at boot, and no reason to mention that. The success message is scoped to the current kernel, and you read it as scoped to the machine.

So the reflex: when you make a setting persistent, verify persistence specifically, not application. Those are different claims. The cheapest version is to run whatever the boot path actually runs — here `systemd-sysctl`, one command, no reboot — and confirm the value moves. If you can't identify what runs at boot, that's worth five minutes with `systemctl cat`, because it also tells you which files it reads, which is the question you actually had.

This is the third instance of the same shape on this platform in a week, after [journald keeping logs in RAM](https://homelabpostmortem.com/2026/08/18/trixie-journald-volatile-logs/) and [swap config needing a reboot](https://homelabpostmortem.com/2026/08/19/trixie-rpi-swap-writeback-file/). Correct config, no error, no effect. The common thread is a config file whose reader isn't the program you were talking to.
