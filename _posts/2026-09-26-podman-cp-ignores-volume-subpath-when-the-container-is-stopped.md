---
title: "podman cp on a stopped container ignores the volume's subpath: it reads a different file, writes outside the container's view, and overwrote another container's config. Exit 0 every time."
date: 2026-09-26
excerpt: "A named volume mounted with subpath= shows the container one directory of the volume. While the container runs, podman cp respects that. When it is created or stopped, podman resolves the path against the volume's root instead. On Debian 13's podman 5.4.2: copying out returned the root's file of the same name; copying in wrote to the root, where the container never saw it, and replaced the config.json of another container that mounts the whole volume. All with exit 0. Docker 26.1.5 with volume-subpath got every state right."
devto_title: "podman cp on a stopped container ignores the volume subpath and writes to the volume root"
devto_tags: podman, docker, linux, devops
---

**TL;DR**: Podman's `--mount type=volume,source=VOL,target=/data,subpath=dir` gives a container only `VOL/dir` at `/data`. `podman cp` honours that while the container is running. When the container is **created or stopped**, podman resolves the path itself and joins it onto the **volume's root**, ignoring the subpath. On Debian 13's own podman (5.4.2, rootful): copying `/data/probe` *out* returned the root's `probe`, a different file, with exit 0; copying a file *in* wrote it to the volume root, where the container never saw it after starting; and in a volume shared with a second container that mounts it whole, a copy into the stopped one **replaced the other container's `config.json`**, exit 0. Docker 26.1.5 with `volume-subpath=` returned the right file in all three states. The upstream report ([containers/podman#29840](https://github.com/containers/podman/issues/29840), on 6.1.2) covers the read side; the write side is not in it. Start the container before `podman cp`, or go through the volume's host path and add the subpath yourself. The toolkit's `check-podman-subpath-cp.sh` lists the containers this affects and can confirm the behaviour on your podman.

## The symptom

A disposable Debian 13 container on Proxmox, `apt install podman` (5.4.2+ds1-2+b2), rootful. One named volume with two files of the same name, one at the root and one in a subdirectory, and a container that mounts only the subdirectory:

{% raw %}
```bash
podman volume create spvol
MP=$(podman volume inspect spvol --format '{{.Mountpoint}}')
mkdir -p "$MP/sub"; echo ROOT_MARKER > "$MP/probe"; echo SUBPATH_MARKER > "$MP/sub/probe"
podman create --name spctr --mount type=volume,source=spvol,target=/data,subpath=sub alpine:3.20 sleep 300
```
{% endraw %}

`podman inspect` agrees about what the container sees: `volume spvol dst=/data subpath=sub`. Then `podman cp` out of `/data/probe`, and a new file in to `/data`, in each state, with the exit code taken on its own line rather than through a pipe:

```
## created
  cp OUT rc=0  content=ROOT_MARKER
  cp IN  rc=0  lands at: new-created           <- volume root
## running
  cp OUT rc=0  content=SUBPATH_MARKER
  cp IN  rc=0  lands at: sub/new-running
  container itself sees: SUBPATH_MARKER ; ls /data: new-running probe
## stopped
  cp OUT rc=0  content=ROOT_MARKER
  cp IN  rc=0  lands at: new-stopped           <- volume root
```

The container's own view never changes: `SUBPATH_MARKER`, and only the files under `sub/`. `podman cp` agrees with it only while it is running. Delete the root's `probe` and the stopped-state copy fails instead — `Error: "/data/probe" could not be found on container spctr: no such file or directory`, exit 125 — although the file the container actually has at `/data/probe` is right there.

The write side is the one that does damage. A volume used by two containers: `app` mounts `subpath=app` and is created but not started; `whole` mounts the entire volume and is running. Each has a `config.json` — `app`'s at `VOL/app/config.json`, `whole`'s at `VOL/config.json`:

```
before: whole sees /data/config.json = ROOT config.json (belongs to whole)
podman cp /tmp/config.json app:/data/config.json  (A stopped/created)  rc=0
after:  whole sees /data/config.json = new app config
after:  app (now running) sees /data/config.json = app's own config.json
```

The copy meant for `app` replaced `whole`'s configuration, and `app` itself never received it.

## Why this is easy to miss

The command succeeds, and in the common case the answer looks plausible. A file of the same name at the volume root is exactly what you get if the volume holds several services' data side by side, which is the reason to use `subpath=` in the first place.

The running case is right, and running is where people try things. A quick check against a live container passes, and the stopped case — the one backup scripts, migrations and "copy the config in before first start" steps use — never gets checked.

When the copy goes in, the container shows nothing wrong: it has its old file, because the new one went somewhere it cannot see. The only symptom is on some other consumer of the volume, possibly one nobody associates with the copy.

## What is really going on

For a container that is not running, libpod works out the host path of the destination itself, in `libpod/container_path_resolution.go` (`resolvePath`). It asks `findVolume` which named volume is mounted at the destination, and joins the path onto the volume's mount point:

```go
func findVolume(c *Container, containerPath string) (*Volume, error) {
	…
	for _, vol := range c.config.NamedVolumes {
		if cleanedContainerPath == filepath.Clean(vol.Dest) {
			return runtime.GetVolume(vol.Name)
	…
mountPoint, err := volume.MountPoint()
…
absolutePathOnTheVolumeMount, err := securejoin.SecureJoin(mountPoint, pathRelativeToVolume)
```

`c.config.NamedVolumes` entries carry the `SubPath`; `findVolume` returns only the volume, so the subpath is gone by the time the path is joined. The code is the same at the `v5.4.2` tag and on `main` as of 2026-09-26. With the container running, the same copies came out right, so the running case evidently resolves the path some other way; I did not trace which.

Docker resolves the same request correctly in every state. A second disposable container with Debian 13's `docker.io` 26.1.5 and `--mount type=volume,source=spvol,target=/data,volume-subpath=sub`:

```
## created   cp OUT rc=0 content=SUBPATH_MARKER    cp IN rc=0 lands at: sub/new-created
## running   cp OUT rc=0 content=SUBPATH_MARKER    cp IN rc=0 lands at: sub/new-running
## stopped   cp OUT rc=0 content=SUBPATH_MARKER    cp IN rc=0 lands at: sub/new-stopped
```

This was tested rootful. The upstream report is rootless on 6.1.2 and shows the same read-side results, which fits: the resolution path does not depend on who runs it.

## The fix

Upstream has none yet; #29840 is open and someone has asked to take it. Until then:

**Start the container before copying.** Running is the one state where `podman cp` resolved the subpath correctly here.

**Or go through the host path and add the subpath yourself** — the volume's mount point is the volume *root*, so the subpath is not optional:

{% raw %}
```bash
MP=$(podman volume inspect VOL --format '{{.Mountpoint}}')
cp ./config.json "$MP/app/config.json"      # "app" = the container's subpath=
```
{% endraw %}

(This was run rootful. For rootless podman the mount point belongs to the user namespace, so the copy would need `podman unshare`; not tested here.)

**Find out which containers this applies to.** The toolkit's `check-podman-subpath-cp.sh` lists every container that mounts a named volume with `subpath=`, marks the ones that are not running, and with `--probe` creates a throwaway volume and container to confirm what this podman does:

```
podman             5.4.2  (rootful)
!! stopped-sub [created]  v1:a -> /data
   running-sub [running]  v1:b -> /data
subpath mounts     2 container(s); 1 not running (marked !!)
probe              created container, cp OUT /data/probe -> rc=0 content=ROOT (SUB is correct)

EXPOSED: for a container that is not running, podman cp reads and writes the volume ROOT instead of
         the subpath it mounts, with exit 0 (containers/podman#29840). …
```

The probe removes its volume and container on every exit path; without `--probe` the script only reads `podman inspect`.

## The generalisable habit

**When a tool has two code paths for the same request, test both.** `podman cp` has one for running containers (ask the kernel) and one for stopped ones (work it out in userspace), and only the second forgot the subpath. Nothing in the command's output tells you which path you took. The state you try it in by hand — running — is the state that works, and the state a script uses — stopped — is the one that does not. This is the same shape as [Podman's Docker-compatible API resetting the restart policy](https://homelabpostmortem.com/2026/09/18/podman-compat-api-update-resets-the-restart-policy-to-no/): one handler of a pair made a different decision about a field the other one honoured.

**For a copy, check where it went, not whether it succeeded.** `rc=0` was true of every copy here, including the one that overwrote another service's configuration. A copy-in test that reads the file back through the container it was copied into would have caught it; one that only checks the exit code never will. The same goes for owners: four days later, [`podman export` of a keep-id container wrote every owner in the archive shifted](https://homelabpostmortem.com/2026/09/30/podman-export-of-a-keep-id-container-shifts-every-owner/), also with `rc=0`, and so did `podman cp` of the same container.
