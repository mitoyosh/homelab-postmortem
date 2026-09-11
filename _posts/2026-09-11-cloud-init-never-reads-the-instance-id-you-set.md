---
title: "Raspberry Pi OS ships a meta-data file whose instance-id key cloud-init never reads. Every user-data you write after the first boot is parsed, merged, and then skipped."
date: 2026-09-11
excerpt: "The stock /boot/firmware/meta-data sets instance_id with an underscore. cloud-init reads instance-id with a hyphen, so the value is never seen and the id falls back to the constant nocloud. One boot with the stock all-comment user-data burns every once-per-instance module, and nothing you write afterwards can run — while cloud-init logs SUCCESS for each module it skipped."
devto_title: "cloud-init never reads the instance-id Raspberry Pi OS sets, so your second user-data is skipped"
devto_tags: raspberrypi, linux, devops, sysadmin
---

**TL;DR**: write a plain Raspberry Pi OS image to a disk, boot it once, then add a `user-data` with a `users:` block and boot again. The user is not created. The file is not the problem: cloud-init parses it, merges it, and writes the merged result to disk with your block in it. It is skipped because `users_groups` is a **once-per-instance** module and the first boot already ran it — against the stock `user-data`, which is 3,277 characters of comments and parses to nothing. The instance never changes, because the stock `meta-data` writes **`instance_id`** and cloud-init reads **`instance-id`**. The skipped modules are logged as `SUCCESS`.

## The symptom

A USB SSD, freshly written with Raspberry Pi OS Lite (Trixie, arm64) and booted once to confirm it came up. Then a `user-data` placed on the boot partition, by hand:

```yaml
#cloud-config
hostname: mitoyosh-pi4b-ssd
users:
  - name: mito
    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialHere
ssh_pwauth: false
```

Boot. No SSH. Mount the disk read-only from another machine and the reason is plain:

```
$ grep -E "^mito:" /mnt/ssdroot/etc/passwd
  mito は存在しない
$ ls -l /mnt/ssdroot/home/mito/.ssh/authorized_keys
  ls: cannot access: No such file or directory
```

The obvious next move is to suspect the file. It survives every check:

```
file        Unicode text, UTF-8 text      (no BOM)
CR count    0                             (no CRLF)
line 1      #cloud-config$                (cat -A — nothing before it)
yaml        type: dict
            keys: ['hostname', 'packages', 'ssh_pwauth', 'users']
```

And cloud-init agrees. This is the merged config it wrote to `/var/lib/cloud/instances/<id>/cloud-config.txt` on that boot:

```yaml
#cloud-config
# from 1 files
# part-001
---
hostname: mitoyosh-pi4b-ssd
users:
-   name: mito
    ssh_authorized_keys:
    - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterialHere
    sudo: ALL=(ALL) NOPASSWD:ALL
...
```

**The block is there.** It was read, parsed, merged, and written back out. And the user does not exist.

## Why this is easy to misdiagnose

Two things point you away from the answer.

**The hostname changes.** `/etc/hostname` really does become `mitoyosh-pi4b-ssd`. `update_hostname` runs with frequency `always`, so it applies on every boot regardless of instance. `users_groups` runs `once-per-instance`, so it does not. **Half your user-data takes effect**, which is a strong signal that the file is being read — and it is, just not acted on.

**The failure surfaces as a network problem.** No SSH looks like no network, and if the machine has no route out, you will find plenty of networking to be wrong. On this disk `/etc/netplan/` was empty and `NetworkManager.state` had `WirelessEnabled=false`, both true and both irrelevant to the missing user. I spent an hour building a cloud-init explanation for the *network* symptom before checking whether an ethernet cable was plugged in. It was not.

The log is no help either, because it reports success:

```
09:32:20  Attempting to load yaml from string of length 773
09:32:20  Merging by applying [('dict', ['replace']), ('list', []), ('str', [])]
09:32:20  config-users_groups already ran (freq=once-per-instance)
09:32:20  finish: init-local/config-users_groups: SUCCESS: config-users_groups previously ran
```

It loads your YAML. It merges your YAML. Then it declines to act on it and records `SUCCESS`.

## What is really going on

Every `once-per-instance` module leaves a semaphore. Theirs are all dated from the **first** boot:

```
$ ls -l /var/lib/cloud/instances/nocloud/sem/
config_locale          Jun 18 09:27
config_mounts          Jun 18 09:27
config_seed_random     Jun 18 09:27
config_set_hostname    Jun 18 09:27
config_set_passwords   Jun 18 09:27
config_ssh             Jun 18 09:27
config_ssh_import_id   Jun 18 09:27
config_users_groups    Jun 18 09:27
consume_data           Jun 18 09:27
```

That first boot had the stock `user-data`, which ships as pure comments:

```
09:27:16  Attempting to load yaml from string of length 3277
09:27:16  loaded blob returned None, returning default.
09:27:16  WARNING: Failed at merging in cloud config part from part-001: empty cloud config
```

**Nine modules ran against an empty configuration and marked themselves done.** The seats were taken before you sat down.

Normally that is fine, because a new instance gets a new id and a fresh set of semaphores. Here the id never changes. This is the stock `meta-data`, verbatim:

```
# Specifies the "unique" identifier of the instance. Typically in cloud-init
# this is generated by the owning cloud and is actually unique (to some
# degree). Here our data-source is local, so this is just a fixed string.
# Warning: changing this will cause cloud-init to assume it is running on a
# "new" instance, and to go through first time setup again (the value is
# compared to a cached copy).
instance_id: rpios-image
```

**The comment is correct. The key below it is not.** cloud-init reads `instance-id`, with a hyphen. From `cloudinit/sources/DataSourceNoCloud.py`:

```python
# line 65 — the default when nothing supplies one
    "instance-id": "nocloud",

# line 284
    iid_key = "instance-id"
```

So `instance_id: rpios-image` is never seen, the id becomes the literal string `nocloud`, and the instance directory is `/var/lib/cloud/instances/nocloud` on every such disk. Change the value the comment tells you to change and nothing happens, because the line it is attached to was never read in the first place.

The control is the same OS on a card written by Raspberry Pi Imager:

```
$ cat /boot/firmware/meta-data
instance-id: rpi-imager-1787993916805
```

Hyphen, and unique. Imager also passes it on the kernel command line, which is a second route to the same field:

```
$ cat /boot/firmware/cmdline.txt
... rootwait ds=nocloud;i=rpi-imager-1787993916805 cfg80211.ieee80211_regdom=JP
```

That `i=` maps to `instance-id` too — `s2l = {"h": "local-hostname", "i": "instance-id", "s": "seedfrom"}`, line 360 of the same file. **A customised image has two ways to set the id. A plain image write has none.**

## The fix

Change the key, and give it a value that has not been used before:

```yaml
# /boot/firmware/meta-data
dsmode: local
instance-id: ssd-boot-test-20260909
```

That is the whole fix. `/var/lib/cloud` was deliberately **not** deleted, so that the result attributes cleanly to the one character:

```
before                          after
instances/nocloud               instances/nocloud
                                instances/ssd-boot-test-20260909
sem: 9 files                    sem: 18 files
no mito                         mito:x:1000:1000::/home/mito:/bin/bash
no authorized_keys              /home/mito/.ssh/authorized_keys  0600 mito:mito
no boot-finished                boot-finished
                                cloud-init status: done
```

Nine semaphores became eighteen, the user was created, the key was installed, and cloud-init ran through `modules-final` to completion. The old instance directory is still sitting next to the new one.

**Check before you boot, not after.** Both of these are cheap:

```bash
# 1. Is the key name one cloud-init will read?
grep -E '^instance[-_]id:' /boot/firmware/meta-data
# instance_id: rpios-image   <- underscore. Never read.

# 2. Has this disk already burned its once-per-instance modules?
#    (mount the rootfs read-only somewhere first)
ls /mnt/root/var/lib/cloud/instances/
# nocloud   <- the generic id, so yes, and a new user-data will not run
```

If the second one lists anything, a fresh `user-data` will be read and ignored unless you change the instance id.

## The generalisable habit

The narrow lesson is to check the key name. The wider one is about which artifact you are trusting.

This file documents its own mechanism correctly, in a comment written by someone who understood it, and then names the key wrong on the next line. **Following the instructions in a file is not the same as the file working.** The prose and the code in a config template are maintained by the same hand but validated by different things — the prose by nobody, the key name by whatever reads it, silently, at boot.

That is the same shape as [a cloud-init key whose valid placement is exactly opposite between two documented forms](https://homelabpostmortem.com/2026/08/29/cloud-init-validates-the-key-it-never-reads/), where `cloud-init schema` calls the file valid either way. Both cases pass every check that looks at the file, because the thing that is wrong is the relationship between the file and the reader, and no validator holds both.

And the operational habit, which cost the most time here: **when a tool reports `SUCCESS` for work it skipped, the word is describing the module's control flow, not your intent.** `config-users_groups previously ran` is a true statement. It is also the only notice you will get that the configuration you just wrote is never going to execute.
