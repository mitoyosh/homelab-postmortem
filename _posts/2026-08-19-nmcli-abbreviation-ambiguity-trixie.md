---
title: "A new NetworkManager property broke a decade of headless WiFi scripts"
date: 2026-08-19
excerpt: "nmcli 1.52 added autoconnect-ports, which made the long-standing abbreviation autoconnect-p ambiguous. Provisioning scripts using it now abort with exit 2, and because nmcli connection modify is all-or-nothing, the SSID and PSK in the same command are never applied — leaving a WiFi profile that exists, looks configured, and has no password."
devto_tags: raspberrypi, linux, networking, sysadmin
---

**TL;DR**: NetworkManager 1.52 (in Trixie) added an `autoconnect-ports` property. That makes `autoconnect-p` — an abbreviation that worked for years — ambiguous against `autoconnect-priority`, and `nmcli` rejects it with exit 2. `nmcli connection modify` is atomic, so every other property in that same command is discarded too, *including ones listed before it*. If your provisioning script created the profile in an earlier command, you're left with a WiFi profile that exists, shows the right SSID, and has no `key-mgmt` and no `psk`. It will never connect, and nothing about the profile looks broken.

## The symptom

A headless provisioning script that has worked for years stops working against a Trixie image. The Pi comes up, the WiFi profile is there, and it never associates.

Listing the profile shows nothing obviously wrong:

```bash
$ nmcli connection show pm-test | grep -E '^(connection.id|connection.type|802-11-wireless.ssid)'
connection.id:                          pm-test
connection.type:                        802-11-wireless
802-11-wireless.ssid:                   PM-TEST-SSID
```

Right name, right type, right SSID. But:

```bash
$ nmcli -g 802-11-wireless-security.key-mgmt connection show pm-test
$ nmcli -g 802-11-wireless-security.psk connection show pm-test
$
```

Both empty. The profile has no security configuration at all — no key management, no pre-shared key. On a WPA2 network that profile cannot work, and the profile itself gives no hint that it's incomplete unless you go looking for the specific fields that are missing.

## What's really going on

`nmcli` accepts abbreviated property names as long as they're unambiguous. On this machine:

```bash
$ nmcli --version
nmcli tool, version 1.52.1
```

1.52 introduced `autoconnect-ports`. There was already `autoconnect-priority`. Both exist in `nm-settings-nmcli(5)` now, and both start with `autoconnect-p`:

```bash
$ nmcli connection modify pm-test conn.autoconnect-p 10
Error: invalid property 'autoconnect-p': 'autoconnect-p' is ambiguous: autoconnect-priority, autoconnect-ports.
$ echo $?
2
```

So the abbreviation that scripts have used since long before either property collided now resolves to nothing. That part is loud — it's an error on stderr with a non-zero exit.

The damaging part is what it does to the rest of the command.

## The command is all-or-nothing, in both directions

The obvious assumption is that `nmcli` processes properties left to right and stops when it hits a bad one, so anything before the failure got applied. It doesn't work that way. Putting a perfectly valid property *first*:

```bash
$ nmcli connection modify pm-test wifi-sec.key-mgmt wpa-psk conn.autoconnect-p 10
Error: invalid property 'autoconnect-p': 'autoconnect-p' is ambiguous: autoconnect-priority, autoconnect-ports.
$ echo $?
2
$ nmcli -g 802-11-wireless-security.key-mgmt connection show pm-test
$
```

`key-mgmt` was listed before the ambiguous property and was still not applied. `nmcli connection modify` validates the whole argument list before committing anything, so one bad name discards all of it.

That's a reasonable design — a half-applied network config would be worse. But combined with the usual scripting pattern, it produces the failure above. Headless WiFi setup scripts overwhelmingly look like:

```bash
nmcli connection add type wifi con-name "$NAME" ifname wlan0 ssid "$SSID"
nmcli connection modify "$NAME" \
  conn.autoconnect-p 10 \
  wifi-sec.key-mgmt wpa-psk \
  wifi-sec.psk "$PASSWORD"
```

The `add` succeeds — that's a separate command and it doesn't mention `autoconnect-p`. The `modify` fails in its entirety. The result is a profile that exists with an SSID and no credentials, which is exactly the state above.

If the script checks exit codes it fails loudly, and you find this in a minute. Plenty of provisioning scripts don't — they run under `set +e`, or pipe output away, or run each step under a supervisor that only cares that the script finished. Those report success and hand you a Pi that won't join the network.

## Why it's easy to misattribute

Everything about the symptom points somewhere else. The machine is headless, so the first evidence you get is "it didn't come up on the network," and the natural suspects are the password, the SSID, 2.4 vs 5 GHz, the regulatory domain, the router. All of those are more common than a CLI abbreviation collision.

The profile actively supports the wrong theory. It exists. It has the SSID you expect. `nmcli connection show` on it prints dozens of populated fields. Two empty ones in the middle of that output do not stand out, and if you don't already know that `key-mgmt` and `psk` are the two that matter, there is nothing to draw your eye to them.

And the change is invisible from the Pi side of things. This isn't in any Raspberry Pi changelog — it's an upstream NetworkManager property addition. The behaviour of abbreviations is documented (they must be unambiguous), but no documentation says "this specific abbreviation stopped working," because from NetworkManager's perspective nothing broke: a new property was added, and abbreviation resolution worked as specified.

## The fix

Use full property names in anything non-interactive:

```bash
$ nmcli connection modify pm-test \
    connection.autoconnect-priority 10 \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk testpassword123
$ echo $?
0
$ nmcli -f connection.autoconnect-priority,802-11-wireless-security.key-mgmt connection show pm-test
connection.autoconnect-priority:        10
802-11-wireless-security.key-mgmt:      wpa-psk
```

Abbreviations aren't broken in general — only ones that became ambiguous. A longer abbreviation still resolves:

```bash
$ nmcli connection modify pm-test conn.autoconnect-pri 20
$ echo $?
0
$ nmcli -g connection.autoconnect-priority connection show pm-test
20
```

`autoconnect-pri` is unique again, so it works. But that's the trap in miniature: `autoconnect-pri` is fine *today*, and it is fine for exactly as long as nobody adds `autoconnect-primary`. Every abbreviation in a committed script is a bet on a namespace you don't control.

The section prefixes (`conn.`, `wifi-sec.`) are a different thing and are fine — those are documented setting-name aliases, not prefix matches.

If you maintain provisioning scripts, this greps them:

```bash
grep -rn "nmcli.*\b\(conn\|connection\)\.autoconnect-p\b" .
```

And after any scripted profile creation, verify the fields that actually matter rather than trusting the exit code alone:

```bash
nmcli -g 802-11-wireless-security.key-mgmt,802-11-wireless-security.psk \
  connection show "$NAME"
```

Empty output there means the profile will never associate, regardless of what the script reported.

## The generalisable habit

Abbreviations are a convenience for humans at a prompt. They're a liability in a file, because the thing that makes an abbreviation valid isn't your input — it's the set of every other name that exists, and that set grows without your involvement. A script using `autoconnect-p` didn't change. Its meaning did, when someone upstream added a property that happened to share a prefix.

The narrower habit worth taking from this: **when a tool validates a batch, find out whether it's atomic before you rely on ordering.** The intuition that "the stuff before the error went through" is wrong here, and it's wrong in the safer direction — but if it had been right, this same bug would have produced a profile with a password and no key management, which is a stranger thing to debug than a profile with neither.

And the one that generalises furthest: a resource that *exists* is not a resource that is *configured*. The provisioning script's job wasn't to create a profile, it was to create a working connection. Checking for the former and reporting success is how you end up with a headless box on the bench and no idea why it's silent.
