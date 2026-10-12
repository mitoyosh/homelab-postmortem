---
title: "On the Pi's 6.18 kernel, pwm-ir-tx sends every edge of an IR code within microseconds, and ir-ctl takes the right amount of time to report success"
date: 2026-10-12
excerpt: "With dtoverlay=pwm-ir-tx on Raspberry Pi OS's 6.18 kernel, a 100 ms pulse, 100 ms space, 100 ms pulse came out as four PWM state changes within 7 microseconds, while ir-ctl exited 0 after about 350 ms, the length of the signal. A 6.18 cleanup inverted the loop condition in the driver's timer callback. The exit code and the timing both look right, so only a trace or a camera shows it. gpio-ir-tx on the same pin sent correctly timed bursts."
devto_title: "Pi pwm-ir-tx on kernel 6.18 sends nothing, and ir-ctl still reports success"
devto_tags: raspberrypi, linux, kernel, homeautomation
---

**TL;DR**: On Raspberry Pi OS's 6.18 kernel, an IR transmitter on `dtoverlay=pwm-ir-tx` sends nothing usable. A test code of 100 ms pulse, 100 ms space, 100 ms pulse was applied to the PWM as four state changes within 7 microseconds, all from one timer interrupt, so the LED was on for a few microseconds in total. `ir-ctl --send` still exited 0, and it still took about 350 ms, because the LIRC core waits for the length of the signal before returning. So neither the exit code nor the timing gives it away. The cause is a 6.18 cleanup, described as switching to "an equivalent higher-level helper", that inverted the loop condition in the driver's timer callback. Switching to `dtoverlay=gpio-ir-tx` on the same pin sent correctly timed 100 ms bursts. The toolkit's `check-ir-tx.sh` finds the affected transmitters and can measure one. Upstream report: [raspberrypi/linux#7678](https://github.com/raspberrypi/linux/issues/7678).

## The symptom

Raspberry Pi 4B, Raspberry Pi OS (Debian 13, arm64), kernel `6.18.34+rpt-rpi-v8`. One line added to `/boot/firmware/config.txt`:

```
dtoverlay=pwm-ir-tx
```

After a reboot everything looks right:

```
rc rc0: PWM IR Transmitter as /devices/platform/pwm-ir-transmitter/rc/rc0
rc rc0: lirc_dev: driver pwm-ir-tx registered at minor = 0, no receiver, raw IR transmitter

$ pinctrl get 18
18: a5    pd | lo // GPIO18 = PWM0_0

$ ir-ctl -d /dev/lirc0 -f
Send features /dev/lirc0:
 - Device can send raw IR
 - IR scancode encoder
 - Set carrier
 - Set duty cycle
```

A test signal of 100 ms on, 100 ms off, 100 ms on, at 38 kHz:

```
$ printf 'pulse 100000\nspace 100000\npulse 100000\n' > ir300.txt
$ ir-ctl -d /dev/lirc0 --carrier=38000 --send=ir300.txt
send 1: rc=0 elapsed_ms=359
send 2: rc=0 elapsed_ms=345
send 3: rc=0 elapsed_ms=349
```

Exit 0, about the length of the signal, nothing in `dmesg`. The kernel's `pwm_apply` trace event shows what the PWM was actually told to do:

```
ir-ctl-1230 [002] d.h1.  42.847753: pwm_apply: pwmchip0.0: period=26316 duty_cycle=13158 polarity=0 enabled=1 err=0
ir-ctl-1230 [002] d.h1.  42.847758: pwm_apply: pwmchip0.0: period=26316 duty_cycle=13158 polarity=0 enabled=0 err=0
ir-ctl-1230 [002] d.h1.  42.847759: pwm_apply: pwmchip0.0: period=26316 duty_cycle=13158 polarity=0 enabled=1 err=0
ir-ctl-1230 [002] d.h1.  42.847760: pwm_apply: pwmchip0.0: period=26316 duty_cycle=13158 polarity=0 enabled=0 err=0
```

The carrier settings are right (a 26,316 ns period is 38 kHz, at 50% duty). The timing is not: the two 100 ms pulses were on for 5 µs and 1 µs, and the whole code was over in 7 µs. The `h` in `d.h1.` means all four were applied in hard interrupt context, from the same callback. After a reboot the same test gave the same four edges within 6 µs.

The report upstream is from a Pi 3B+ on the 32-bit kernel (`6.18.50+rpt-rpi-v7`), with an LED that stayed dark. Here it is a Pi 4B on the 64-bit kernel, so it isn't limited to one model or architecture.

## Why it's easy to miss

Every check you'd normally do passes. The overlay loads, `/dev/lirc0` appears with the right features, the pin is in PWM mode, and `ir-ctl` returns 0.

Timing doesn't help either. It is tempting to think a transmission that collapses into microseconds would make `ir-ctl` return instantly, and that measuring it would catch the problem. It doesn't: the LIRC core (`lirc_transmit()` in `lirc_dev.c`) sleeps until the full duration of the signal has passed before the `write` returns, whatever the driver did. `ir-ctl` took 345 to 359 ms for a 300 ms signal, which looks perfectly healthy.

And IR is invisible. Unless you point a phone camera at the LED, the only symptom is that the TV or amplifier doesn't react, which looks like a wrong code, a weak LED, or a bad angle. People who have had a working IR blaster for years will update the kernel and start debugging their codes.

One more trap if you test with long signals: a 600 ms test code (three 200 ms segments) was refused outright with `failed to send: Invalid argument` (exit 74), because LIRC limits one transmission to 500 ms in total (`IR_MAX_DURATION`). That's an honest error, but it sends you looking in the wrong place.

## What's really going on

`pwm-ir-tx` has two ways of sending. If the PWM driver can be called from atomic context, it programs each edge from an hrtimer callback; otherwise it sleeps between edges. The Pi's PWM driver is atomic, and `dmesg` shows no "TX will not be accurate as PWM device might sleep" line, so the Pi uses the timer path.

The timer callback applies one edge, schedules the next expiry, and loops if it has fallen behind, to catch up after a latency spike. Up to 6.17 the loop condition was:

```c
		now = timer->base->get_time();
	} while (hrtimer_get_expires_tv64(timer) < now);
```

that is, keep going while the next expiry is already in the past. Commit [`44d7fb8acdf8`](https://github.com/torvalds/linux/commit/44d7fb8acdf8) ("media: pwm-ir-tx: Avoid direct access to hrtimer clockbase", first in v6.18) replaced it with what its message calls "an equivalent higher-level helper":

```c
	} while (hrtimer_expires_remaining(timer) > 0);
```

`hrtimer_expires_remaining()` is the expiry time minus now. It is positive when the next expiry is in the future, which is always the case right after adding the next edge's duration. So the loop that used to run only when behind now runs whenever it is on time: the first callback applies every edge, one after another, completes the transmission and stops the timer. That is exactly the trace above. The same line is in `rpi-6.18.y` and in mainline today.

## The fix

Until the condition is put back, use the bit-banged driver on the same pin:

```
dtoverlay=gpio-ir-tx,gpio_pin=18
```

instead of `dtoverlay=pwm-ir-tx`, and reboot. Same test signal, traced through the `gpio_value` event:

```
rc=0 elapsed_ms=331
burst length_ms=105.98 toggles=7604
burst length_ms=99.99  toggles=7600
gap between bursts ms=100.01
```

Two bursts of about 100 ms, 100 ms apart, each with 7,600 toggles, which is 38 kHz for 100 ms. `gpio-ir-tx` generates the carrier by busy-waiting on the CPU, so it costs CPU time while a code is being sent and its timing can be disturbed by other load. For an IR blaster that sends a code now and then, that is a fair trade against sending nothing.

To check a machine, `check-ir-tx.sh` lists the IR transmitters, flags `pwm-ir-tx` on a 6.18 or later kernel, and with `--probe` (as root) sends a 30 ms test code and measures the spread of its PWM edges in the trace. On this Pi with `pwm-ir-tx` it reported 4 edges in 7 µs. With `gpio-ir-tx` it passed.

## The generalisable habit

When a change is described as equivalent, check the one thing that would make it not equivalent. Here it was the direction of a comparison: "expiry is before now" and "time remaining is positive" sound like the same question and are opposites. A refactor that only swaps how a value is obtained can still flip what the condition means, and the commit message and the review both read it as a no-op.

The other habit is about what counts as a test. An exit code and a duration are both claims the software makes about itself. For anything that leaves the machine, an IR code, a packet, a write to a disk, measure what actually happened: a trace event, a camera, a capture on the other end.

This is the second time the Pi's 6.18 kernel has quietly taken away something that worked on 6.12: [legacy iptables modules stopped being built](https://homelabpostmortem.com/2026/08/27/iptables-legacy-modules-gone-from-pi-kernel/) while the config still said they were enabled.
