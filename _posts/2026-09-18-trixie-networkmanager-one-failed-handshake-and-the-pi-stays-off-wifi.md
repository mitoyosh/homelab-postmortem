---
title: "One failed WPA handshake and a headless Pi on Trixie stays off WiFi until someone types a command — its NetworkManager has no retry for PSK, asks for a key nobody can give, and blocks the profile."
date: 2026-09-18
excerpt: "NetworkManager 1.52.1 on Raspberry Pi OS Trixie: fail one 4-way handshake on a profile that has worked for weeks, and 3.6 seconds later NM is 'asking for new key' — the only retry setting is documented as 802.1X-only on this version. There is no secret agent on a headless box, so the profile is blocked from autoconnect. Put the correct key back and reload: 120 seconds later, still disconnected. Upstream added PSK retries in 1.58 and named the trigger — briefly leaving the AP's range. A 30-second systemd timer that runs nmcli connection up brought it back in 40 seconds."
devto_title: "One failed WPA handshake and a headless Raspberry Pi on Trixie stays off WiFi until someone types a command"
devto_tags: raspberrypi, linux, networking, debugging
---

**TL;DR**: Raspberry Pi OS Trixie ships NetworkManager 1.52.1. On that version a WPA-PSK connection gets exactly one 4-way handshake: if it fails, NM asks for a new key — on a profile that has connected successfully many times, and regardless of `connection.auth-retries`, which 1.52's own documentation scopes to 802.1X. On a headless Pi there is no secret agent to answer, so the request fails with `no-secrets`, and NetworkManager then **blocks the profile from autoconnect**. That block survives restoring the key and reloading the profile: two minutes later the device was still `disconnected`. Only `nmcli connection up` (or a reboot) clears it. Upstream extended the retry budget to PSK in NetworkManager 1.58 ([746a5902](https://github.com/NetworkManager/NetworkManager/commit/746a5902ad85ec0611a3e6ebfd7b68b45621a40b)) and the commit message names the real-world trigger: a device "can leave the range of an access point and therefore fail a 4-way handshake". Trixie does not have it ([raspberrypi/trixie-feedback#102](https://github.com/raspberrypi/trixie-feedback/issues/102) is the open backport request). A systemd timer that re-activates the profile when the device is disconnected recovered the same failure in 40 seconds; the toolkit's `check-wifi-autoconnect-block.sh` reports whether you are exposed and installs it.

## The symptom

Raspberry Pi 4B, Raspberry Pi OS Lite Trixie (arm64), `network-manager 1.52.1-1+rpt4`, one WiFi profile that has been the machine's only network for weeks (the ethernet port is empty). The test: set `connection.auth-retries 0`, replace the PSK with a wrong one, and reconnect — from a script detached with `systemd-run`, because the SSH session is on that WiFi and is about to die. NetworkManager's log at debug level:

```
01:08:48.5  device (wlan0): supplicant interface state: scanning -> associating
01:08:48.8  device (wlan0): supplicant interface state: associating -> 4way_handshake
01:08:52.4  device (wlan0): supplicant interface state: 4way_handshake -> disconnected
01:08:52.4  device (wlan0): Activation: (wifi) disconnected during association, asking for new key
01:08:52.4  device (wlan0): state change: config -> need-auth (reason 'supplicant-disconnect')
01:08:52.4  device (wlan0): no secrets: No agents were available for this request.
01:08:52.4  device (wlan0): state change: need-auth -> failed (reason 'no-secrets')
01:08:52.4  policy: block-autoconnect: connection '<wifi profile>' now blocked from autoconnect due to no secrets
01:08:52.4  device (wlan0): Activation: failed for connection '<wifi profile>'
```

One handshake. 3.6 seconds. No retry. `auth-retries` had been set to 0 for the test, which is documented as "try indefinitely" — but read the whole comment in 1.52's `libnm-core-impl/nm-setting-connection.c`:

```
The number of retries for the authentication. Zero means to try indefinitely; -1 means
to use a global default. If the global default is not set, the authentication
retries for 3 times before failing the connection.

Currently, this only applies to 802-1x authentication.
```

For a PSK network on this version there is no retry setting at all, and no retry. The upstream report and the research that led here both framed this as "auth-retries is ignored"; the last line of the comment says it more plainly — it was never meant to apply. That does not change what the machine does, which is the rest of this post.

Then the second half, which is the one that matters on a headless box. The correct key was put back by copying the original `/etc/netplan/90-NM-*.yaml` over the modified one and running `nmcli connection reload`, with nothing else touched, and the device was polled every five seconds:

```
01:15:43  restoring profile files + reload only
          connection.auth-retries: -1        ← original setting is back
01:15:54  t+5s     wlan0:disconnected
01:16:19  t+30s    wlan0:disconnected
01:16:50  t+60s    wlan0:disconnected
01:17:21  t+90s    wlan0:disconnected
01:17:52  t+120s   wlan0:disconnected
01:17:52  explicit `nmcli connection up`
          Connection successfully activated
```

The profile had the right key for two minutes and NetworkManager did not try it once. `nmcli connection up` connected on the first attempt.

## Why this is easy to miss

`nmcli connection modify … connection.auth-retries 0` returns 0 and the value reads back, and the property's one-line description in `nmcli`'s help is "Number of retries for authentication" with no qualifier. Only the full comment in the source, or the 1.58 changelog, says PSK is excluded. Someone who sets it to protect a headless Pi has done nothing, and nothing tells them.

On a desktop, the whole thing is a password prompt: the handshake fails, NM asks the agent, the user sees "enter password for network X", types the same password, and is back online with a shrug. The bug reads as "Ubuntu keeps asking for my WiFi password" — and that is exactly how it appears in the threads that exist about it, none of which mention `auth-retries`.

On a headless Pi there is no prompt and no shrug. The `no-secrets` failure blocks the profile, `nmcli device status` says `disconnected`, and nothing on the machine will change that. From outside, the Pi has dropped off the network and stays off; the natural diagnosis is power, the SD card, or the radio. A reboot would clear it — the block is not persisted — which confirms the wrong diagnosis. The upstream commit that fixed the retry path describes the trigger as ordinary — a device that "can leave the range of an access point" — which for a Pi in a cupboard means the access point rebooting, changing channel, or a microwave running.

The block is the part that turns a nuisance into an outage, and it is invisible: there is no `nmcli` field for it. It shows up only as one journal line, `block-autoconnect … due to no secrets`, and as the absence of any retry afterwards.

## What is really going on

Two mechanisms in sequence.

**The retry that does not exist.** In NetworkManager 1.52, a 4-way handshake failure on a WPA-PSK connection lands in the device's auth-failure handler, which requests new secrets directly. The authentication retry budget — `nm_device_auth_retries_has_next()`, driven by `connection.auth-retries` — is consulted on the 802.1X path only, as the documentation says. The upstream change, +78/−12 in `src/core/devices/wifi/nm-device-wifi.c`, makes a previously-connected PSK profile exhaust that budget before asking, and rewrites the documentation to match ("Connections using a pre-shared key to authenticate will only prompt for a new key during the last authentication attempt"). The reasoning in the commit message:

> While NetworkManager tries its best to determine whether a new PSK is needed, it can still run into edge cases. One of these edge cases is that a device can leave the range of an access point and therefore fail a 4-way handshake. Because these cases can't be confidently detected, a device which was previously connected should try to exhaust its authentication retries before requesting new secrets.

That landed in 1.58.0 (July 2026). Trixie's 1.52.1 predates it by three stable releases, and the Pi OS package has not backported it. Before it, "one attempt, then prompt" was the designed behaviour for PSK — designed for a laptop with a person in front of it.

**The block that never lifts.** When NM asks for secrets and no agent answers, the activation fails with reason `no-secrets`, and policy marks the connection as blocked from autoconnect for that reason. The intent is sensible — do not retry a connection whose password the user has declined to provide. But on 1.52 the request was never justified, and on a headless machine the "user" is nobody. The block is cleared by an explicit activation of the connection — observed three times here. It was not cleared by rewriting the profile with the correct key and reloading it, which is what the two-minute poll above shows. (A reboot should clear it too, since the block is not persisted; that was not tested, and on a headless box it is not much of a remedy.)

So the chain, on a headless Pi on Trixie, is: any single handshake failure → new-secrets request (no PSK retry exists on 1.52) → `no-secrets` → autoconnect blocked → offline until a human runs `nmcli connection up`.

## The fix

Upstream's fix is the right one and it is not available on Trixie today; #102 is the request. Until it lands, the thing that clears the block is the thing to automate.

**A watchdog timer.** Every 30 seconds: if the WiFi device is `disconnected` and the profile is not active, run `nmcli connection up` for it. The same failure was induced a third time with this installed, the correct key restored by file copy and reload as before, and no manual command:

```
01:20:28  wifi-autoconnect-watchdog: wlan0 disconnected and '<wifi profile>' inactive — running nmcli connection up
01:20:34  wifi-autoconnect-watchdog: up failed              ← key still wrong at this point; correct
01:20:29  restoring profile files + reload only
01:21:03  wifi-autoconnect-watchdog: wlan0 disconnected and '<wifi profile>' inactive — running nmcli connection up
01:21:15  wifi-autoconnect-watchdog: recovered
01:21:15  t+40s    wlan0:connected
```

Forty seconds, against two minutes and counting without it. The first attempt failing is the watchdog doing the right thing — the key really was wrong then — and it costs nothing but a log line.

The toolkit's `check-wifi-autoconnect-block.sh` does the reporting and the install:

```
$ ./check-wifi-autoconnect-block.sh
NetworkManager     1.52.1-1+rpt4
WiFi profile       <wifi profile>  (device wlan0)
auth-retries       -1   (802.1X-only before NM 1.58; makes no difference to PSK here)
fix in this NM     no  (< 1.58: one handshake failure -> new-secrets request)
blocked this boot  2 time(s)  (journal: 'blocked from autoconnect due to no secrets')
watchdog timer     inactive

EXPOSED: NM 1.52.1-1+rpt4 asks for a new key after one failed PSK handshake (no retry on this version),
         and with no secret agent the profile is then blocked from autoconnect until
         'nmcli connection up' runs. A headless box stays off WiFi.
         Install the watchdog:  sudo ./check-wifi-autoconnect-block.sh --install-watchdog
```

`--install-watchdog` writes a 12-line script to `/usr/local/sbin`, a oneshot service, and a timer, and enables the timer; `--remove-watchdog` takes all three away. Report mode is read-only and never touches secrets. `blocked this boot` counts the journal line, so it also tells you whether this has already happened to the machine you are looking at.

Things that do not fix it, for the record: setting `auth-retries` to anything (on 1.52 it applies to 802.1X only); `nmcli connection reload` (tested, two minutes); `connection.autoconnect-retries` (a different budget for a different failure — not tested here, and not the reason the profile is blocked).

## The generalisable habit

**A setting that is accepted and stored is not a setting that is consulted — and the qualifier is usually in the last line of the comment.** `auth-retries` has a validator, a documented range, a documented meaning, a code path that reads it, and one sentence at the bottom saying it applies to a different authentication type. The research that surfaced this candidate, the upstream report, and the first draft of this post all missed that sentence. The only way to know a setting does nothing on your box is to make it matter and watch the log. That is a five-minute test on any machine that can afford to lose its network for two of them, and it is the same test that found [`instance-id` being ignored by cloud-init](https://homelabpostmortem.com/2026/09/11/cloud-init-never-reads-the-instance-id-you-set/) and [`response_format` being ignored by llama-server](https://homelabpostmortem.com/2026/09/12/llama-server-ignores-the-response-format-its-readme-shows/): change the value to something that must change the outcome, and see whether the outcome changes.

**Test the recovery, not just the failure.** The retry bug is the upstream report. The block is what a headless machine actually experiences, and it only became visible by restoring the correct key and *not* running the obvious command — waiting to see whether the system would come back on its own. It would not. A reproduction that ends at "yes, it fails" would have shipped a post about a missing retry; the post that matters is about a Pi that stays offline, and the difference was two minutes of watching a `disconnected` line not change.
