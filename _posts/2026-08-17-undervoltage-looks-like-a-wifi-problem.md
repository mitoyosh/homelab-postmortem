---
title: "Undervoltage doesn't look like a power problem. It looks like bad Wi-Fi."
date: 2026-08-17
excerpt: "A Raspberry Pi 4B refused to hold a Wi-Fi connection, wouldn't finish a login, and behaved like it had a driver fault. The actual cause was a power supply that couldn't hold 5V — and the firmware had been saying so in one line nobody reads."
---

**TL;DR**: On a Raspberry Pi, an inadequate power supply rarely announces itself as "the power is bad". It shows up as flaky Wi-Fi, hung logins, and mysterious slowness. Check `vcgencmd get_throttled` (or `/sys/class/hwmon/hwmon*/in0_lcrit_alarm`) *before* you debug the symptom you can see.

## The symptom

A freshly imaged Pi 4B, running headless-ish off a monitor and keyboard for setup. Two things were wrong, and neither of them sounded electrical:

1. **Wi-Fi wouldn't come up.** `hostname -I` returned `127.0.1.1` and nothing else — no DHCP lease, no address, on a network every other device was using without complaint.
2. **The console was unusable.** Typing a username at the login prompt appeared to do nothing; after a delay the prompt would simply return. It read like a broken install or a corrupt filesystem.

The natural reading of those two symptoms together is "bad image" or "bad SD card". That is where I would have gone next.

## The line that changed the diagnosis

Buried in the console spam was this:

```
[ 899.552015] hwmon hwmon2: Undervoltage detected!
```

One line, printed once, ~15 minutes into uptime, surrounded by unrelated boot chatter. Easy to scroll past — and in fact it had scrolled past several times before it got read.

## What undervoltage actually does

The Pi's firmware monitors the 5V rail. When it drops below roughly 4.63V, it flags undervoltage and starts protecting itself: the CPU is throttled, clocks are capped. That much is documented and expected.

What's less obvious — and what makes this so hard to diagnose from symptoms — is the **second-order** effects:

- **The wireless chip is voltage-sensitive.** A rail that sags under load will produce exactly what I was seeing: a radio that scans but won't associate, or associates and drops. It presents as a networking fault, not a power fault.
- **Everything gets slower, unevenly.** A throttled CPU plus a stressed rail makes interactive work feel like the machine is hanging rather than running slowly.
- **It's the single most common cause of SD card corruption on Pis.** Losing the rail mid-write is how filesystems get damaged. So the "bad SD card" hypothesis isn't wrong, exactly — it's downstream. Undervoltage *creates* bad SD cards.

That last point is why this matters more than a performance footnote. If you chase the symptom and reflash the card, you will produce a machine that works briefly and then breaks again, and you will blame the card a second time.

## How to check it directly

Don't infer it from behaviour. Ask the firmware:

```bash
vcgencmd get_throttled
```

`throttled=0x0` means clean. Anything else is a bitfield:

| Bit | Meaning |
|---|---|
| 0 (`0x1`) | Under-voltage **right now** |
| 1 (`0x2`) | ARM frequency **currently** capped |
| 2 (`0x4`) | **Currently** throttled |
| 16 (`0x10000`) | Under-voltage **has occurred** since boot |
| 17 (`0x20000`) | Frequency capping **has occurred** |
| 18 (`0x40000`) | Throttling **has occurred** |

The split matters. Low bits mean it's happening as you look. High bits mean it happened earlier and has since recovered — which is exactly the fingerprint of an intermittent supply, and exactly what you'd otherwise dismiss as "it's fine now, must have been a fluke".

If `vcgencmd` isn't installed (it isn't always, on minimal Lite images), the kernel exposes the same alarm through hwmon and needs no packages:

```bash
cat /sys/class/hwmon/hwmon*/in0_lcrit_alarm
```

`0` is healthy, `1` means undervoltage is currently flagged.

Note that the "has occurred" bits only clear on reboot. So the correct test loop after changing anything is: reboot, use the machine, *then* re-check — not check, change, check again on the same boot.

## The actual fix

A Pi 4B wants **5.1V at 3A**. The usual culprits, in the order they actually bite:

1. **The cable, not the adapter.** This is the one people skip. A thin or long USB-C cable drops meaningful voltage under load even when the supply is genuinely rated 3A. Short and thick beats nominally-correct-at-the-plug.
2. **Phone chargers that don't negotiate.** A charger can be rated well above 15W and still hand a Pi 5V at low current, because the Pi doesn't perform the USB-PD negotiation the charger is waiting for.
3. **Whatever else is drawing from the Pi's rails.** USB peripherals, HATs, SPI displays and GPIO-powered fans all come out of the same budget. A setup that's stable bare can go unstable the moment you add a display.

Swapping to a supply that could actually hold the rail cleared both symptoms at once — Wi-Fi associated immediately, and the console stopped stalling. `throttled=0x0` from then on.

## The generalisable habit

The reason this costs people hours is that **the failure surfaces far from its cause**. Power is the substrate everything else runs on, so when it's marginal, the visible breakage appears in whichever subsystem is least tolerant — usually the radio. You end up debugging NetworkManager while the actual fault is a cable.

So it's worth making the power check reflexive rather than diagnostic: on any Pi that's misbehaving in more than one way at once, run `get_throttled` first. It takes two seconds, and it either eliminates an entire category of cause or hands you the answer.

Two unrelated subsystems failing simultaneously is rarely two bugs. It's usually one thing underneath both of them.

A ready-to-run version of this check — which works with or without `vcgencmd`, decodes the bitfield into plain English, and tells you which of the three causes above to look at — is in the [toolkit]({{ '/toolkit/' | relative_url }}).
