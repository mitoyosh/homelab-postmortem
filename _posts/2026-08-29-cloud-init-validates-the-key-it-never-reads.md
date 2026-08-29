---
title: "The same ssh_import_id works in one cloud-init file and does nothing in the next. The difference is one letter."
date: 2026-08-29
excerpt: "A top-level ssh_import_id is read only for a user marked default, and a nested one only for a user that is not. Raspberry Pi's documented users: example and Imager's generated user: block sit on opposite sides of that line, so the placement that works on one silently does nothing on the other."
devto_tags: raspberrypi, linux, devops, sysadmin
---

**Correction (2026-08-29, same day)**: the original version of this post said an
Imager-created user is never the default user, and told you to nest
`ssh_import_id` under the user. **That is wrong for a machine provisioned by
Raspberry Pi Imager, and following it will break a working setup.** Imager
2.0.11 writes `user:` (singular), which cloud-init *does* treat as the default
user — so on an Imager-provisioned Pi the top-level key is the one that works
and the nested one is silently dropped. The two forms are exactly opposite, and
the post below has been rewritten around that. The mechanism it described is
real; which side of it you are on is what the original got wrong. Verified on a
freshly imaged Pi 4B, cloud-init 25.2.

**TL;DR**: cloud-init reads a top-level `ssh_import_id:` **only** for a user marked `default`, and a nested one **only** for a user that is not. Each form therefore has exactly one placement that works, and they are opposite. Raspberry Pi Imager writes `user:` (singular) — that user is default, so the top-level key works and a nested one is dropped. Raspberry Pi's own documented example writes `users:` (a list) — that user is not default, so the nested key works and a top-level one is dropped. Either way the discarded key is logged at `debug`, `cloud-init schema` calls the file valid, and the `ssh_authorized_keys` beside it still works, so nothing tells you half your config was ignored.

## The symptom

Raspberry Pi Imager 2.0 generates cloud-init configuration by default. If you write the file by hand instead, [Raspberry Pi's own announcement](https://www.raspberrypi.com/news/cloud-init-on-raspberry-pi-os/) shows this shape for creating your user — note `users:`, the list form, which is **not** what Imager itself writes:

```yaml
users:
  - name: pi
    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: mysecretpassword123
    ssh_authorized_keys:
      - ssh-ed25519 mykeystuff
    sudo: ALL=(ALL) NOPASSWD:ALL
```

That page does not mention `ssh_import_id`, so if you want your keys pulled from GitHub rather than pasted in, you go to cloud-init's documentation and add it — at the top level, which is where the schema defines it:

```yaml
#cloud-config
users:
  - name: pi
    groups: users,adm,sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialHere
    sudo: ALL=(ALL) NOPASSWD:ALL
ssh_import_id:
  - gh:mitoyosh
```

Check it before you flash, because that is the responsible thing to do:

```bash
$ cloud-init schema --config-file user-data
Valid schema user-data
$ echo $?
0
```

Boot the Pi. The static key in `ssh_authorized_keys` is in `~/.ssh/authorized_keys` exactly as promised. The keys from `gh:mitoyosh` are not, and never will be. Nothing raises an error to change that: the skip is a `LOG.debug` and a `continue`, with no exception and nothing recorded as a failure, so there is no reason for the run's status to be anything but `done` — which is what `cloud-init status` reports on this machine.

## Why it's easy to misdiagnose

Three separate things tell you the configuration is fine.

**The schema says so.** This is not a typo being tolerated — the shipped schema explicitly defines `ssh_import_id` as a top-level key:

```bash
$ python3 -c "import json;d=json.load(open('/usr/lib/python3/dist-packages/cloudinit/config/schemas/schema-cloud-config-v1.json'));print(json.dumps(d['\$defs']['cc_ssh_import_id']))"
{"type": "object", "properties": {"ssh_import_id": {"type": "array", "items": {"type": "string", "description": "The SSH public key to import."}}}}
```

So `cloud-init schema` is correct to pass it. The key is valid cloud-config. It is simply not read on this path.

**The other key in the same block works.** `ssh_authorized_keys` is nested under the user, and nested keys are read. So you get a machine where one of the two SSH directives you wrote took effect. That is much more confusing than neither working, because it rules out the whole category of "my user-data wasn't applied."

**Nothing is logged above debug level.** The module runs — it is not skipped — and then declines to do anything, quietly:

```python
for user, user_cfg in users.items():
    import_ids = []
    if user_cfg["default"]:
        import_ids = util.get_cfg_option_list(cfg, "ssh_import_id", [])
    else:
        try:
            import_ids = user_cfg["ssh_import_id"]
        except Exception:
            LOG.debug("User %s is not configured for ssh_import_id", user)
            continue
```

`LOG.debug`, not `LOG.warning`. It does not appear in the default log level, and `cloud-init status` has no opinion about it.

## What's really going on

The top-level `ssh_import_id` is read inside exactly one branch: `if user_cfg["default"]`. Every other user falls to the `else`, which looks **only** at a key nested under that user.

A user created through the `users:` list is not the default user. Reproducing that on the machine, with the shipped cloud-init and the config shape above:

```bash
$ python3 -c "import cloudinit; print(cloudinit.version.version_string())"
25.2
```

Running all four combinations against the shipped cloud-init on a freshly imaged Pi:

```
config form               default   branch taken                import_ids
user:  + top-level        True      default (reads top-level)   ['gh:mitoyosh']
user:  + nested           True      default (reads top-level)   []
users: + top-level        False     else (nested only)          None
users: + nested           False     else (nested only)          ['gh:mitoyosh']
```

**Each form has exactly one placement that works, and they are opposite.** The
`default` column is the whole story: `user:` (singular) declares the default
user, so the module takes the branch that reads the *top-level* key and never
looks at a nested one. `users:` (a list) creates ordinary users, so the module
takes the branch that reads only the *nested* key.

That matters because the two shapes come from two different places. **Raspberry
Pi Imager 2.0.11 writes `user:`**, verified on the `user-data` it generated for
this machine. **Raspberry Pi's own documentation shows `users:`.** Follow the
docs by hand and you need the nested form; let Imager write it and you need the
top-level form. Nothing anywhere tells you which one you have.

Note the version: Raspberry Pi OS ships **25.2** here, from their own build (`25.2-1~bpo13+1+rpt20`), not the `25.1.4` that Debian Trixie carries. Check the box rather than the distro's package page — the behaviour above is what is actually installed.

### It is known upstream, and the fix in flight is for a different case

Two trackers are open and neither is fixed:

- [`raspberrypi/trixie-feedback#98`](https://github.com/raspberrypi/trixie-feedback/issues/98) — opened 2026-08-13, no comments.
- [`canonical/cloud-init#4306`](https://github.com/canonical/cloud-init/issues/4306) — open, labelled `bug`, eight comments, reported by a cloud-init contributor.

There is an open PR, [#7050](https://github.com/canonical/cloud-init/pull/7050), and it is easy to assume it covers this. It does not. Its own commit message says what it changes:

> Merge both sources for the default user. A top-level `ssh_import_id` keeps working on its own, and **non-default users are unchanged**.

That fixes the `user:` + nested combination — a nested `ssh_import_id` dropped for the default user, which is exactly
what an Imager-provisioned machine hits if you move the key under the user. It leaves the other half alone: a top-level
key with a non-default user, the `users:` case, is explicitly unchanged. So the PR closes one of the two holes and not
the other, and which one matters to you depends on which form your `user-data` uses.

There is also [a Raspberry Pi forum thread](https://forums.raspberrypi.com/viewtopic.php?p=2385229) asking exactly this question. It has no replies.

## The fix

**Look at your `user-data` first, because the correct answer is the opposite of
itself depending on what you find.** One line settles it:

```bash
grep -E '^users?:' /var/lib/cloud/instance/user-data.txt
```

**If it says `user:`** — which is what Raspberry Pi Imager writes — that user is
the default user, and the key belongs at the top level, outside the user block:

```yaml
#cloud-config
user:
  name: pi
  ssh_authorized_keys:
    - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialHere
ssh_import_id:
  - gh:mitoyosh
```

**If it says `users:`** — the list form the documentation shows — that user is
not the default, and the key belongs nested under it:

```yaml
#cloud-config
users:
  - name: pi
    groups: users,adm,sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialHere
    ssh_import_id:
      - gh:mitoyosh
```

Moving the key the wrong way is not a no-op: on an Imager-provisioned machine,
nesting a `ssh_import_id` that currently works will stop it working, and
nothing will tell you.

Two things worth knowing before you rely on it. `ssh-import-id` must be installed or the module warns and stops — that one *is* at warning level, so it will show up. And the import needs working networking and reachable GitHub/Launchpad at first boot; if the machine comes up on WiFi that takes a moment, the keys can be a boot behind.

Verify on the machine rather than by asking cloud-init how the run went. The skip records no error, so a successful-looking status is exactly what you would expect in both cases — it is not evidence either way:

```bash
wc -l ~/.ssh/authorized_keys
grep -c 'ssh_import_id' /var/log/cloud-init.log
```

If the first number only accounts for the keys you pasted literally, the import did not happen — regardless of what anything else reported.

## The generalisable habit

Schema validation answers "is this a well-formed document?" It cannot answer "will anything read this?", and the two feel like the same question when the validator is shipped by the same project as the code. Here they diverge completely: the key is in the schema, the schema is right, and the code that consumes it has a condition the schema knows nothing about.

So the habit is narrow: **a validator passing tells you the file parsed, not that the field is live on your path.** When a config option quietly does nothing, do not re-read the file looking for a typo — go find the code that consumes the key and check what it requires. Here it was one `if`.

The wider one is about partial success. One SSH directive worked and one did not, and that is the shape that costs the most time, because working evidence is louder than absent evidence. You look at `authorized_keys`, see a key, and conclude the mechanism works — when what you have confirmed is that a *different* mechanism works. The same trap as [a WiFi profile that exists with the right SSID and no credentials](https://homelabpostmortem.com/2026/08/19/nmcli-abbreviation-ambiguity-trixie/): the thing you can see being right is not evidence about the thing you cannot.

I fell into a version of that writing this. The mechanism was read correctly
from the source, the failing case was reproduced, and the fix was tested — on
the `users:` form, which is what the documentation shows. It never occurred to
me to check what Imager actually writes, because I had verified so much else.
Provisioning a machine with Imager hours later is what surfaced it, and the
advice I had published would have broken that machine. **Reading the code tells
you what the branches are. It does not tell you which branch your machine is
on.**
