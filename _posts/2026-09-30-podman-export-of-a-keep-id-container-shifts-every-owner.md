---
title: "Rootless `podman export` of a `--userns=keep-id` container shifts every file owner in the tarball, and exits 0"
date: 2026-09-30
excerpt: "A rootless container created with --userns=keep-id stores its files under the intermediate namespace's IDs, and podman export tars that storage without mapping them back. On a Pi with podman 5.4.2, the user's home came out as 0/0, 3257 root-owned files as 1/1, and su and passwd as setuid to UID 1, with exit status 0. Imported, the user could not write its own home. podman cp showed the same shift. Committing the container and exporting a plain container from the commit gave correct owners."
devto_title: "Rootless podman export of a keep-id container shifts every file owner, exit 0"
devto_tags: podman, containers, linux, backup
---

**TL;DR**: `podman export` of a rootless container that was created with `--userns=keep-id` writes a tarball in which every file owner is shifted by the container's ID mapping. Inside the container the user's home is `1000/1000` and system files are `0/0`. In the export, the home is `0/0`, the 3257 root-owned files are `1/1`, and `su`, `passwd` and the other setuid binaries are setuid to UID 1. The export exits 0 and prints nothing. Import that tarball and the user can't write to its own home directory. `podman cp ctr:/ -` produced the same shift. `podman commit` maps the owners back: commit the container, create a plain container from the image, and export that. The export code passes no ID mapping to its tar writer, in 5.4.2 and in current main. Reproduced on a Raspberry Pi with Debian's podman 5.4.2. The toolkit's `check-podman-export-idmap.sh` lists the containers at risk and checks an export without writing it. Upstream report: [podman-container-tools/podman#29856](https://github.com/podman-container-tools/podman/issues/29856).

## The symptom

Raspberry Pi 4B, Raspberry Pi OS (Debian 13, arm64), `podman 5.4.2` from Debian, rootless as the login user (UID 1000, subuids `100000:65536`). An image with one ordinary user:

```
FROM docker.io/library/debian:13-slim
RUN useradd -m user && echo hello > /home/user/note.txt && chown user:user /home/user/note.txt
```

Both ways of running it agree about who owns what:

```
podman run --rm exporttest ls -lan /home/user
podman run --rm --userns=keep-id exporttest ls -lan /home/user
  drwx------ 1000 1000 .
  -rw-r--r-- 1000 1000 .bashrc
  -rw-r--r-- 1000 1000 note.txt
```

Then one container of each kind, exported:

```
c1=$(podman create exporttest);                    podman export "$c1" > e1.tar   # rc=0
c2=$(podman create --userns=keep-id exporttest);   podman export "$c2" > e2.tar   # rc=0

tar tvf e1.tar home                          tar tvf e2.tar home
drwxr-xr-x 0/0       home/                   drwxr-xr-x 1/1       home/
drwx------ 1000/1000 home/user/              drwx------ 0/0       home/user/
-rw-r--r-- 1000/1000 home/user/.bashrc       -rw-r--r-- 0/0       home/user/.bashrc
-rw-r--r-- 1000/1000 home/user/note.txt      -rw-r--r-- 0/0       home/user/note.txt
```

The report upstream showed the `home/` lines, and the shift doesn't stop there. The owner counts across the whole archive:

```
e1 (plain):   3257 0/0      7 0/42     5 1000/1000   3 0/43   1 0/8
e2 (keep-id): 3257 1/1      7 1/43     5 0/0         3 1/44   1 1/9
```

Every owner and every group is off by the same mapping. The setuid binaries go with them:

```
e1: -rwsr-xr-x 0/0 usr/bin/su     e2: -rwsr-xr-x 1/1 usr/bin/su
    -rwsr-xr-x 0/0 usr/bin/passwd     -rwsr-xr-x 1/1 usr/bin/passwd
    ... (8 setuid files, all 0/0)     ... (all 1/1)
```

`podman import e2.tar e2img` succeeds, and the damage shows up only when the image is used:

```
podman run --rm e2img stat -c "%u:%g %A %n" /etc/passwd /etc/shadow /usr/bin/su
  1:1 -rw-r--r-- /etc/passwd
  1:43 -rw-r----- /etc/shadow
  1:1 -rwsr-xr-x /usr/bin/su

podman run --rm --user user e2img touch /home/user/x
  touch: cannot touch '/home/user/x': Permission denied
podman run --rm --user user exporttest touch /home/user/x      # original image: works
```

`su` and `passwd` are now setuid to UID 1, which is `daemon`, so they no longer do what they are for.

## Why it's easy to miss

`podman export` is the documented way to get a container's filesystem out as a tarball, and `--userns=keep-id` is the standard answer to "my rootless container writes files my host user can't read". Both are common, and nothing in their output hints at a problem when they're combined. The export exits 0 and prints nothing to stderr. The man page doesn't mention owners, user namespaces or ID mappings at all. The tarball has the right files, the right sizes and the right permission bits. Only the numbers in the owner column are wrong, and hardly anyone lists a backup tarball with `tar tv` to read that column.

The problem only surfaces when the archive is restored, in a different container or on a different day, as a permission error that looks like something the image itself got wrong.

The upstream report came from podman running inside another container on an EL8 kernel, with an ID mapping unlike an ordinary host's. That made it easy to read as an edge case of nested containers. On an ordinary host, with podman as a normal user and the stock subuid range, it happens the same way.

## What's really going on

`podman inspect` shows the difference between the two containers:

```
plain:   IDMappings null
keep-id: UsernsMode private
         UidMap ["0:1:1000", "1000:0:1", "1001:1001:64536"]
```

A keep-id container gets its own user namespace inside rootless podman's namespace. Container UID 0 maps to 1 there, container UID 1000 maps to 0 there (which is the host user), and the rest follows. Its files are stored on disk under those intermediate IDs. You can see it by mounting the container's storage from inside `podman unshare`:

```
podman unshare sh -c 'm=$(podman mount hpmkid); ls -ln $m/home/user/made-at-runtime.txt $m/root/made-by-root.txt'
  -rw-r--r-- 1 0 0 ... home/user/made-at-runtime.txt     <- written by UID 1000 in the container
  -rw-r--r-- 1 1 1 ... root/made-by-root.txt             <- written by root in the container
```

The export code (`libpod/container_internal.go`) mounts that storage and tars it:

```go
input, err := chrootarchive.Tar(mountPoint, nil, mountPoint)
```

The `nil` is the tar options, which is where an ID mapping would go. None is given, so the archive gets the on-disk IDs, which are the container's IDs pushed through its mapping. For a container with no mapping of its own, on-disk and in-container IDs are the same and nothing is visible. The line is identical in 5.4.2, in 5.8.7 (the version in the report) and in current main.

`podman cp ctr:/ - | tar tv` on the keep-id container showed the same shift: files the container's user owns came out as `root/root`, and root's files as `daemon/daemon`. That makes `podman cp` no workaround here.

## The fix

`podman commit` does apply the container's mapping. Committing the keep-id container, creating a plain container from the resulting image and exporting that gave correct owners, including for files written while the container ran:

```bash
podman commit mycontainer tmp-export
c=$(podman create tmp-export)
podman export "$c" > mycontainer.tar
podman rm "$c"; podman rmi tmp-export
```

```
(0) podman export hpmkid                      (a) commit -> create -> export
  0/0       home/user/made-at-runtime.txt       1000/1000 home/user/made-at-runtime.txt
  1/1       root/made-by-root.txt               0/0       root/made-by-root.txt
  1/1       usr/bin/su                          0/0       usr/bin/su
```

Check any export before trusting it. In a normal Linux image `etc/passwd` belongs to root, so one line is enough:

```bash
podman export mycontainer | tar tvf - etc/passwd
```

If that shows anything other than `0/0`, the archive is shifted. An archive already made this way can't be repaired by adding a fixed offset to every owner, because the mapping isn't a single offset: 0 became 1, 1000 became 0, and IDs above 1000 stayed where they were. Re-export it through a commit instead.

This was measured with `--userns=keep-id`. Other options that give a container its own mapping (`--userns=auto`, `--uidmap`) go through the same export line, but they weren't tested here.

## The generalisable habit

A tarball has two layers, the data and the metadata, and most checks only look at the first. The files are there, the sizes match and the restore succeeds, so it looks like a backup. Check the metadata that matters for a restore — owners, groups, setuid bits — against the source before you rely on the archive. `tar tv` on one file whose owner you know is cheap. Finding out from `Permission denied` after the original is gone is not.

The same program already had one case of a copy command that reads the wrong layer of storage without saying so: [`podman cp` on a stopped container ignores a volume's `subpath=`](https://homelabpostmortem.com/2026/09/26/podman-cp-ignores-volume-subpath-when-the-container-is-stopped/). In both cases the copy succeeds, and it copies the storage as it sits on disk, not the view the container has.

The toolkit's `check-podman-export-idmap.sh` lists the current user's containers that have their own ID mapping, and with `--verify <container>` streams an export straight into `tar tv` and checks that `etc/passwd` and `usr/bin/su` are root's, writing nothing to disk. It prints the commit-based export for any container that fails.
