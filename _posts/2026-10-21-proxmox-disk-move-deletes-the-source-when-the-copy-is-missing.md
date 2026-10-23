---
title: "Proxmox's disk move with Delete source deletes the source even when the copy isn't there, and the task ends TASK OK"
date: 2026-10-21
excerpt: "On Proxmox VE 9.2, qm disk move --delete 1 finished with exit 0 and TASK OK after the target file had disappeared during the copy. The log said failed to stat for the target, then removing source volume after successful copy, and the source LV was gone. The VM config pointed at a file that did not exist, with its size still shown. Without --delete the source was kept as unused0. Moving without Delete source and checking the copy before removing the original avoids it."
devto_title: "Proxmox disk move with Delete source deletes the source even when the copy is missing"
devto_tags: proxmox, homelab, linux, backup
---

**Update 2026-10-23.** Proxmox has a fix in review. The report is now [Bugzilla #8209](https://bugzilla.proxmox.com/show_bug.cgi?id=8209) (status PATCH AVAILABLE), and Fiona Ebner posted a four-patch series for qemu-server to pve-devel, ["fix #8209: clone disk: do not ignore failure to query size of target"](https://lore.proxmox.com/pve-devel/20261022093901.52732-1-f.ebner@proxmox.com/). As the patch describes it, a failed size query of the target is now logged as a warning and reported to the caller so it can avoid the destructive step, and because the file-based storage plugins return nothing instead of failing, the size is checked explicitly. The series isn't applied or in a package yet, so qemu-server 9.1.15 behaves as described below. Why the reporter's target disappeared on the NFS share is, in the Bugzilla thread's words, still unclear.

**TL;DR**: In Proxmox VE 9.2, moving a VM disk with "Delete source" (`qm disk move ... --delete 1`) deletes the original as soon as the copy step returns, without checking that the copy exists. On a test VM, the target file was removed while the copy was running. The move finished with exit 0 and `TASK OK`. The task log had one line, `failed to stat '<target>'`, followed by `removing source volume ... after successful copy`, and the source volume was gone. The VM's config pointed at the missing file, still showing `size=2G`, so nothing in the config looked wrong. With "Delete source" off, the same failure kept the original as `unused0`. Until this changes: move without "Delete source", check the copy against the original, then remove the original yourself. The toolkit has a script that searches past task logs for this and one that does the checked move. Report: [forum.proxmox.com thread 187166](https://forum.proxmox.com/threads/qm-disk-move-offline-delete-removes-source-although-target-file-is-missing-failed-to-stat-%E2%80%93-task-ok-data-loss.187166/), from someone who lost a disk this way moving to an NFS share.

## The symptom

The Proxmox host behind this site's lab, pve-manager 9.2.2, qemu-server 9.1.15, libpve-storage-perl 9.1.5. A throwaway directory storage `hpmtest` and a stopped test VM with a 2 GiB disk on `local-lvm`, 1 GiB of it filled with random data so the copy takes a few seconds at `--bwlimit 51200`. A second shell deleted the target file 3 seconds after it appeared, which is a stand-in for whatever made the reporter's target disappear:

```
# qm disk move 9901 scsi0 hpmtest --format qcow2 --delete 1 --bwlimit 51200
...
transferred 2.0 GiB of 2.0 GiB (100.00%)
failed to stat '/var/lib/hpmtest/images/9901/vm-9901-disk-0.qcow2'
removing source volume 'local-lvm:vm-9901-disk-0' after successful copy
  Logical volume "vm-9901-disk-0" successfully removed.
rc=0
```

The task log ends `TASK OK`. Afterwards:

```
config: scsi0: hpmtest:9901/vm-9901-disk-0.qcow2,size=2G
source LV: 0 volume(s) for vm 9901
target dir: (empty)
```

The source is deleted, the target doesn't exist, and the config still looks complete. The same run with `--delete 0`:

```
failed to stat '/var/lib/hpmtest/images/9901/vm-9901-disk-0.qcow2'
adding source volume 'local-lvm:vm-9901-disk-0' as 'unused0' to config
rc=0
config: scsi0: hpmtest:9901/vm-9901-disk-0.qcow2,size=2G unused0: local-lvm:vm-9901-disk-0
```

Also `TASK OK`, also pointing at a missing file, but the original is still there as `unused0`, and the VM can be pointed back at it.

## Why it's easy to miss

The task succeeds. In the GUI it shows `OK`, the CLI exits 0, and the only sign is one `failed to stat` line in a log of progress lines, immediately followed by a line that says "after successful copy". Nobody reads a long move log that ended OK.

The config doesn't help either. The disk line keeps its `size=2G`, because that comes from the old disk's entry; only a missing size would hint at a problem, and there isn't one. The problem only shows when something needs the disk, most likely the next start of the VM (not tried here), which after an offline move of a stopped VM may be days later, when the space on the old storage has been reused.

And the trigger is not something you'd test for. Here the file was removed by hand. In the forum report it was a move to an NFS share on a Synology, where the copy ran for about nine hours and the target was not there at the end. Why it vanished there is a separate question, but anything that can make a target disappear or become unreadable, a network share, a full or remounted filesystem, a cleanup job, turns "Delete source" into data loss.

## What's really going on

The installed code on this host, read directly:

In `PVE/API2/Qemu.pm`, the disk move runs the clone inside an `eval`, and if that `eval` didn't die, the delete block runs:

```perl
if ($param->{delete}) {
    print("removing source volume '$old_volid' after successful copy\n");
    eval {
        PVE::Storage::deactivate_volumes($storecfg, [$old_volid]);
        PVE::Storage::vdisk_free($storecfg, $old_volid);
    };
```

"Successful" means only that nothing died. The one place the target is looked at after the copy is in `PVE/QemuServer.pm`, where the clone asks for its size:

```perl
my $size = eval { PVE::Storage::volume_size_info($storecfg, $newvolid, 10) };
```

For a file-based target, that ends up in the storage plugin's `file_size_info`, which, when `stat` fails, prints `failed to stat '...'` as a warning and returns nothing, rather than dying. The `eval` would catch a death anyway. So a missing target produces a warning and an undefined size, the clone returns normally, and the delete goes ahead. The `size=2G` in the config is the old disk's size, kept because the new one came back undefined.

The copy itself (`qemu-img convert`) didn't fail either: it keeps writing to the file it has open, even after the name has been removed, and finishes normally.

## The fix

There's no fix in Proxmox yet; the forum thread had no reply as of 21 October and there's no Bugzilla entry for it.

**Don't use "Delete source"** for moves you can't watch. Move with it off, so the original stays as `unusedN`.

**Check the copy before removing the original.** For a stopped VM, `qemu-img compare` reads both and checks the guest-visible contents match, across formats:

```
qemu-img compare -f raw -F qcow2 /dev/pve/vm-101-disk-0 /mnt/pve/nas/images/101/vm-101-disk-0.qcow2
```

Exit 0 means identical. Then remove the original with `qm disk unlink <vmid> --idlist unused0`, which deletes the volume. If the target is missing or differs, point the VM back at the original with `qm set <vmid> --scsi0 <old volume>`.

The toolkit's `pve-move-disk-verified.sh` does exactly that for a stopped VM: moves without delete, checks the target exists, compares, and removes the source only if they match and you passed `--delete-source`. With the target removed mid-copy it printed:

```
TARGET MISSING: hpmtest:9901/vm-9901-disk-0.qcow2 does not exist after the move. The source is kept as unused0 (local-lvm:vm-9901-disk-0).
```

and exited 1, with the original intact. A normal move compared `identical` and removed the source.

**Check whether it has already happened to you.** `check-pve-move-delete.sh` reads every disk-move task log on the node and lists the ones with `failed to stat`, as LOST if the source was then removed, and checks every VM disk in the current configs for a volume that doesn't exist:

```
  LOST  vm 9901  2026-10-21 09:06:26  source local-lvm:vm-9901-disk-0 was deleted; target /var/lib/hpmtest/images/9901/vm-9901-disk-0.qcow2 could not be stat'ed (TASK OK)
  KEPT  vm 9901  2026-10-21 09:07:25  target /var/lib/hpmtest/images/9901/vm-9901-disk-0.qcow2 could not be stat'ed; source kept: as 'unused0'
...
  MISSING  vm 9901  scsi0  hpmtest:9901/vm-9901-disk-0.qcow2
```

A LOST source can't be recovered from Proxmox; that's what backups are for.

## The generalisable habit

Never let a tool delete the original on the strength of its own success message. "After successful copy" is a claim made by the same code that did the copy, and here it meant only that nothing threw an error. Before deleting a source, verify the destination independently: it exists, it has the right size, and its contents match. That's one command, and it's the one step the tool skipped.

More generally, a warning followed by success is a pattern worth searching your logs for. A warning means some check failed and the program decided to carry on; when the next step is destructive, that decision deserves a look.

Another case of a status that said everything was fine while the data was gone: [a Docker container that came back running after a reboot with its image mount empty](https://homelabpostmortem.com/2026/10/18/docker-image-mount-comes-back-empty-after-a-reboot/).
