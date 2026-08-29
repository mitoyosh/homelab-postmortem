---
title: "cloud-init calls your user-data valid. It will never read the ssh_import_id in it."
date: 2026-08-29
excerpt: "Raspberry Pi Imager 2.0 provisions with cloud-init, and Raspberry Pi's own example creates a named user. A top-level ssh_import_id next to it passes schema validation, runs, and does nothing — because that key is only read for a user marked default, and an Imager-created user never is."
devto_tags: raspberrypi, linux, devops, sysadmin
---

**TL;DR**: On Raspberry Pi OS with cloud-init, a top-level `ssh_import_id:` in your `user-data` is only ever read for a user marked `default`. Raspberry Pi's own documented example creates a named user, which is not default, so the key is silently skipped — logged at `debug`, never at warning. `cloud-init schema` validates the file as correct, the `ssh_authorized_keys` you put next to it works fine, and the imported keys never arrive. On a headless box the first symptom is that you cannot log in with the key you expected.

## The symptom

Raspberry Pi Imager 2.0 generates cloud-init configuration by default, and [Raspberry Pi's own announcement](https://www.raspberrypi.com/news/cloud-init-on-raspberry-pi-os/) shows this shape for creating your user:

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

```
config placement   user   default   branch taken          import_ids
top-level          pi     False     else (nested only)    None
nested under user  pi     False     else (nested only)    ['gh:mitoyosh']
```

Same user, same `default=False`, same cloud-init. The only difference is where the key sits. In the top-level case the module reaches `LOG.debug(...)` and `continue`s, and there is no other user for the top-level value to apply to.

Note the version: Raspberry Pi OS ships **25.2** here, from their own build (`25.2-1~bpo13+1+rpt20`), not the `25.1.4` that Debian Trixie carries. Check the box rather than the distro's package page — the behaviour above is what is actually installed.

### It is known upstream, and the fix in flight is for a different case

Two trackers are open and neither is fixed:

- [`raspberrypi/trixie-feedback#98`](https://github.com/raspberrypi/trixie-feedback/issues/98) — opened 2026-08-13, no comments.
- [`canonical/cloud-init#4306`](https://github.com/canonical/cloud-init/issues/4306) — open, labelled `bug`, eight comments, reported by a cloud-init contributor.

There is an open PR, [#7050](https://github.com/canonical/cloud-init/pull/7050), and it is easy to assume it covers this. It does not. Its own commit message says what it changes:

> Merge both sources for the default user. A top-level `ssh_import_id` keeps working on its own, and **non-default users are unchanged**.

That fixes a nested `ssh_import_id` being dropped *for the default user*. The case above — a top-level key with a non-default user — is explicitly left as it is. So merging that PR will not fix a Raspberry Pi Imager setup.

There is also [a Raspberry Pi forum thread](https://forums.raspberrypi.com/viewtopic.php?p=2385229) asking exactly this question. It has no replies.

## The fix

Nest it under the user, alongside `ssh_authorized_keys`:

```yaml
#cloud-config
users:
  - name: pi
    groups: users,adm,sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialHere
    ssh_import_id:
      - gh:mitoyosh
```

Both keys are then in the branch that gets read, and both apply.

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
