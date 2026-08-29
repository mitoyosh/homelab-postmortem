---
title: "tar backed up your Pi's WiFi config and exited 0. The archive holds one empty directory."
date: 2026-08-26
excerpt: "On a stock Raspberry Pi OS Trixie image, /etc/NetworkManager/system-connections is empty — and it is the directory every guide names. The connection you actually care about, WiFi password included, lives in /etc/netplan as a 600-mode YAML that NetworkManager.conf never mentions."
devto_tags: raspberrypi, linux, networking, sysadmin
---

**TL;DR**: On a stock Trixie Pi OS image, the WiFi credentials for the connection this Pi actually uses are stored in `/etc/netplan/90-NM-<uuid>.yaml`, not in `/etc/NetworkManager/system-connections/`. That second directory — the one every guide, every backup snippet and every "copy your config to the new card" workflow names — is **completely empty**. `tar` archives it happily, exits 0, and produces a 10 KB file containing a single directory entry and no credentials. You find out after you have already reimaged.

## The symptom

The machine is a Pi 4B on Raspberry Pi OS Lite, current image:

```bash
$ cat /etc/rpi-issue | head -1
Raspberry Pi reference 2026-06-18
$ nmcli --version
nmcli tool, version 1.52.1
```

WiFi works. NetworkManager is running and knows about the connection:

```bash
$ nmcli -t -f NAME,TYPE,DEVICE con show
netplan-wlan0-HOMEWIFI:802-11-wireless:wlan0
lo:loopback:lo
netplan-eth0:802-3-ethernet:
```

So you do the sensible thing before reimaging — save the network config:

```bash
$ sudo tar cf /tmp/wifi-backup.tar -C /etc/NetworkManager system-connections
$ echo $?
0
$ ls -l /tmp/wifi-backup.tar
-rw-r--r-- 1 root root 10240 Aug 26 11:06 /tmp/wifi-backup.tar
```

Ten kilobytes. Exit zero. No warning. Here is what is in it:

```bash
$ tar tvf /tmp/wifi-backup.tar
drwxr-xr-x root/root         0 2026-08-26 10:09 system-connections/
```

One directory entry. Nothing else. Because:

```bash
$ sudo ls -la /etc/NetworkManager/system-connections/
total 8
drwxr-xr-x 2 root root 4096 Aug 26 10:09 .
drwxr-xr-x 8 root root 4096 Aug 26 10:09 ..
```

The directory is empty, has always been empty on this image, and the connection that is currently carrying your SSH session is not in it.

## Why it's easy to miss

Three things line up to keep you from noticing.

**The archive isn't empty.** A 0-byte file would make you look. `tar` pads to a 10240-byte block, so an archive of one empty directory is the same size as an archive of a few small files. It looks exactly like a successful backup of a handful of `.nmconnection` files, which is what you expected to get.

**NetworkManager's own config points you at the wrong place.** If you go looking for where connections are stored, this is what you find:

```bash
$ grep -vE '^\s*#|^$' /etc/NetworkManager/NetworkManager.conf
[main]
plugins=ifupdown,keyfile
[ifupdown]
managed=false
```

`keyfile` is the plugin that reads and writes `.nmconnection` files. It is enabled, and `NetworkManager --print-config` — the effective configuration, drop-ins included — agrees:

```bash
$ sudo NetworkManager --print-config | grep -A1 '^\[main\]'
[main]
plugins=ifupdown,keyfile
```

None of that is wrong, which is what makes it unhelpful. The keyfile plugin reads *three* directories — `/etc/NetworkManager/system-connections`, `/run/NetworkManager/system-connections`, and `/usr/lib/...` — and only the first is writable and persistent. Netplan renders its YAML into the `/run` one at boot, so the keyfile plugin is genuinely doing all the work, on files it did not write, in a directory the config never names. There is a `netplan.conf` drop-in, but it lives in `/run/NetworkManager/conf.d/` and only assigns device management:

```ini
[device-netplan.wifis.wlan0]
match-device=type:wifi
managed=1
```

Nothing in any file under `/etc` tells you netplan is holding your PSK.

**There *are* `.nmconnection` files, and finding them makes you think you had the wrong path, not the wrong idea:**

```bash
$ sudo ls -l /run/NetworkManager/system-connections/
total 12
-rw------- 1 root root 314 Aug 25 00:56 lo.nmconnection
-rw------- 1 root root 174 Aug 26 10:09 netplan-eth0.nmconnection
-rw------- 1 root root 295 Aug 26 10:09 netplan-wlan0-HOMEWIFI.nmconnection
```

There they are, in the format you expected, with the names you expected. It is easy to conclude the directory just moved and get on with your day. It didn't:

```bash
$ findmnt -no FSTYPE /run
tmpfs
```

Those are runtime copies on a tmpfs. They are regenerated at every boot from something else, and if you back those up instead you have captured a derived artifact rather than the source.

## What's really going on

The source is in `/etc/netplan`:

```bash
$ sudo ls -l /etc/netplan/
total 8
-rw------- 1 root root 275 Aug 26 10:09 90-NM-75a1216a-9d1a-30cd-8aca-ace5526ec021.yaml
-rw------- 1 root root 590 Aug 26 10:09 90-NM-be1282f3-d98b-3db6-9c1f-0cd80398f4f5.yaml
```

Two files, mode 600, named after connection UUIDs rather than after anything a human would search for. The second one is the WiFi:

```yaml
network:
  version: 2
  wifis:
    wlan0:
      renderer: NetworkManager
      match: {}
      dhcp4: true
      access-points:
        "HOMEWIFI":
          auth:
            key-management: "psk"
            password: "<REDACTED>"
          networkmanager:
            uuid: "be1282f3-d98b-3db6-9c1f-0cd80398f4f5"
            name: "netplan-wlan0-HOMEWIFI"
```

The pre-shared key is right there in plaintext, which is why the file is 600. This is the file that matters, and it is the one your backup missed.

### Both stores are live, and you cannot predict which one a connection is in

This is the part that makes the situation genuinely confusing rather than merely surprising: **both stores are live at once, and nothing on the machine announces which connection is in which.**

The `wlan0` and `eth0` profiles on this machine are netplan YAML. A connection created with `nmcli` is not — it lands in the keyfile directory, and that holds for real device types, not just a synthetic one:

```bash
$ sudo nmcli con add type wifi con-name pm-grill-wifi ifname wlan0 \
    ssid PM-GRILL-TEST autoconnect no wifi-sec.key-mgmt wpa-psk wifi-sec.psk ...
Connection 'pm-grill-wifi' (82da931e-...) successfully added.

$ sudo nmcli con add type ethernet con-name pm-grill-eth ifname eth0 \
    autoconnect no ipv4.method manual ipv4.addresses 10.98.98.2/24
Connection 'pm-grill-eth' (ce3c1462-...) successfully added.

$ sudo ls -1 /etc/NetworkManager/system-connections/
pm-grill-eth.nmconnection
pm-grill-wifi.nmconnection
$ sudo ls -1 /etc/netplan/
90-NM-75a1216a-9d1a-30cd-8aca-ace5526ec021.yaml
90-NM-be1282f3-d98b-3db6-9c1f-0cd80398f4f5.yaml
```

A WiFi connection and an ethernet connection — the same two types the netplan-backed profiles use — both went to the keyfile directory. The netplan files were untouched.

I am deliberately not going to tell you which tool put the `wlan0` profile into netplan, because I could not establish it and I would rather say so. `raspi-config` sets WiFi by shelling out to `nmcli` — there is not one reference to netplan in it — and `nmtui` is part of `network-manager` and goes through the same library. Both of those should therefore land in the keyfile directory, exactly as my test connections did. They did not, for this machine's WiFi profile.

Provisioning on this image has more than one way to look configured and not be. cloud-init arrived with Imager 2.0, and [a top-level `ssh_import_id` in your user-data is silently never read](https://homelabpostmortem.com/2026/08/29/cloud-init-validates-the-key-it-never-reads/) for the kind of user Raspberry Pi's own example creates.

Take that as the practical finding rather than a loose end: **a Pi that has been configured over time can have some of its network state in each store, and which is which is not something you can reason out from the tool you remember using.** You have to look. Backing up either directory alone silently captures part of the picture, and the part it misses is not predictable.

Modifying an existing netplan-backed connection, on the other hand, edits the YAML in place rather than migrating it to a keyfile. Setting a static IP on the (unused, disconnected) `eth0` profile:

```bash
$ sudo nmcli con modify netplan-eth0 ipv4.method manual \
    ipv4.addresses 10.99.99.5/24 ipv4.gateway 10.99.99.1
$ echo $?
0
```

rewrites the `ethernets:` block in `90-NM-75a1216a-....yaml` and leaves `system-connections/` empty. Worth stating plainly, because it is the thing people expect to be broken and it isn't: **`nmcli` works.** Setting a static IP on Trixie behaves exactly as documented, and `nmcli -g ipv4.addresses con show` reads the value back. The failure here is not in configuring the network. It is in *finding* the configuration afterwards.

### The received answer is the wrong one

The standard answer to "where does Raspberry Pi OS keep my WiFi password" has been `/etc/NetworkManager/system-connections/` since Bookworm moved off `dhcpcd` in 2023, and write-ups as recent as July 2026 still give that answer without qualification. On this image it is wrong, and nothing on the machine contradicts it loudly enough to notice — the directory exists, the plugin that owns it is enabled, and `.nmconnection` files really do exist a few paths away.

## The fix

The obvious move is to stop guessing at paths and ask NetworkManager where the connection lives. It has a field for exactly that, and on this machine it does not help:

```bash
$ nmcli -f NAME,FILENAME con show
NAME                    FILENAME
netplan-wlan0-HOMEWIFI  /run/NetworkManager/system-connections/netplan-wlan0-HOMEWIFI.nmconnection
lo                      /run/NetworkManager/system-connections/lo.nmconnection
netplan-eth0            /run/NetworkManager/system-connections/netplan-eth0.nmconnection
```

`FILENAME` reports the file NetworkManager actually loaded the profile from, which is the truth — and for a netplan-sourced connection the truth is the tmpfs copy. Back up what that column names and you have backed up the derived artifact that disappears at the next boot.

What makes this genuinely treacherous rather than merely wrong is that the column is *correct* for connections you created yourself. Add one with `nmcli con add` and it reports the real, persistent path:

```
pm-grill-wifi  /etc/NetworkManager/system-connections/pm-grill-wifi.nmconnection
```

So `FILENAME` is reliable exactly for the connections you already know where to find, and misleading for the one that came with the image and holds your WiFi password.

There is no single field that names the persistent source. What works is mapping by UUID, which is stable across both stores:

```bash
nmcli -t -f NAME,UUID con show | while IFS=: read -r name uuid; do
  src=$(grep -rl "$uuid" /etc/netplan/ 2>/dev/null | head -1)
  [ -z "$src" ] && src=$(grep -rl "$uuid" /etc/NetworkManager/system-connections/ 2>/dev/null | head -1)
  printf '%-26s %s\n' "$name" "${src:-<runtime-generated, no persistent source>}"
done
```

On this box:

```
netplan-wlan0-HOMEWIFI     /etc/netplan/90-NM-be1282f3-d98b-3db6-9c1f-0cd80398f4f5.yaml
lo                         <runtime-generated, no persistent source>
netplan-eth0               /etc/netplan/90-NM-75a1216a-9d1a-30cd-8aca-ace5526ec021.yaml
```

It finds keyfile-backed connections too — adding one with `nmcli con add` makes it show up under `/etc/NetworkManager/system-connections/` on the next run — and it correctly reports `lo` as having no persistent source, because it doesn't.

Run that *before* you reimage rather than after. To capture everything regardless of origin:

```bash
sudo tar czf wifi-backup.tar.gz \
  /etc/netplan \
  /etc/NetworkManager/system-connections
```

Then verify the archive contains files and not just directories — the whole point of this post is that the command succeeding proves nothing:

```bash
tar tzvf wifi-backup.tar.gz | grep -v '/$'
```

If that prints nothing, you have backed up nothing.

Size is not the signal either, and on this machine it points the wrong way. The correct archive — both netplan YAMLs, PSK included, gzipped — is **566 bytes**. The one that captured nothing is **10,240 bytes**, because `tar` pads to a 10 KB block whether or not it found anything to put in it. The bigger file is the empty one.

Two cautions on the archive itself. It contains your PSK in plaintext, so it inherits the 600 that the source files carry for a reason — don't leave it in `/tmp` or commit it anywhere. And when restoring onto a new image, put each file back where it came from: a netplan YAML dropped into `system-connections/` is not read, and vice versa.

## The generalisable habit

The failure here is a specific instance of a general one: **an operation that has nothing to do can't tell you apart from an operation that succeeded.** `tar` was asked to archive a directory. It did. Zero files matched, and zero matched is indistinguishable from "there was nothing that needed archiving" — the same shape as [a clone tool whose search-and-replace matches nothing and reports success](https://homelabpostmortem.com/2026/08/16/rpi-clone-partuuid-trap/), and the same shape as [a journal directory that exists to reassure you persistence is on when it isn't](https://homelabpostmortem.com/2026/08/18/trixie-journald-volatile-logs/).

So the narrow habit, which costs one command: **after any backup, list the archive.** Not the exit code, not the file size — the contents. Both of those were fine here.

And the wider one, which is the part I got wrong on the first pass: **asking the tool is better than asking the internet, but "the tool told me" is not the same as "this is the file I need."** `nmcli`'s `FILENAME` is accurate — it answers "where did I load this from?" precisely. My question was "what do I have to copy so this survives a reimage?", and those turn out to be different files. Every layer here answers its own question correctly. The gap is between the question the tool answers and the one you meant, and nothing in the output marks where that gap is.

That is the same failure as trusting `tar`'s exit code, one level up. Both times the machine was right and the inference was wrong.

A ready-to-run version of this check — which finds every connection's real backing file across both stores, warns when `/etc/NetworkManager/system-connections/` is empty, and verifies that a backup archive actually contains files — is in the [toolkit](https://homelabpostmortem.com/toolkit/) that comes with this post.
