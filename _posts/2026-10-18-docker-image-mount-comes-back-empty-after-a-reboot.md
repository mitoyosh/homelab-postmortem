---
title: "A Docker type=image mount comes back empty after a reboot, and to a non-root container it looks like a permissions error"
date: 2026-10-18
excerpt: "On Docker 29.9.1, a container with --mount type=image and a restart policy came back running after a host reboot with the mount an empty, root-only directory: Permission denied as uid 1000, nothing at all as root. On the containerd image store a daemon restart was harmless and a reboot was not; on overlay2 both broke it, and live-restore only covered the daemon restart. docker restart does not refill it. Recreating the container does."
devto_title: "Docker type=image mounts come back empty after a reboot"
devto_tags: docker, linux, selfhosted, devops
---

**TL;DR**: A container with a `type=image` mount (an image's filesystem mounted read-only into another container) and `--restart always` came back `running` after a host reboot with the mount target empty. As uid 1000 every read failed with `Permission denied`, because the leftover directory is root-only (`710` or `700`, owned by root); as root it just listed nothing. On Docker 29.9.1 with the containerd image store, `systemctl restart docker` left the mount intact but a reboot emptied it. With the overlay2 graph driver both did, and `live-restore` only protected the daemon restart. `docker restart` does not fix it. Recreating the container does. Upstream: [moby/moby#50999](https://github.com/moby/moby/issues/50999) and [#53931](https://github.com/moby/moby/issues/53931).

## The symptom

A disposable Debian 13 VM, Docker CE 29.9.1 with containerd 2.4.2, default containerd image store. One container that mounts the `alpine` image at `/data` and runs as uid 1000:

```
$ docker run -d --name im --user 1000:1000 --restart always \
    --mount type=image,source=alpine:latest,target=/data alpine:latest sleep infinity
$ docker exec im cat /data/etc/alpine-release
3.24.2
```

After `systemctl reboot`:

{% raw %}
```
$ docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' im
running restarts=0
$ docker exec im cat /data/etc/alpine-release
cat: can't open '/data/etc/alpine-release': Permission denied
$ docker exec -u 0 im sh -c 'stat -c "%a %u:%g" /data; ls -A /data | wc -l'
710 0:0
0
```
{% endraw %}

The container is up, its restart count is 0, and the mount is an empty directory that only root can enter. `docker restart im` left it at 0 entries, and so did another daemon restart. Removing the container and running it again with the same command brought back `3.24.2`.

A daemon restart alone did not do this on this store. In an earlier run, after `systemctl restart docker` the uid 1000 container still read `3.24.2` and a root container with the same mount still saw 17 entries.

On the overlay2 graph driver (`"features": {"containerd-snapshotter": false}`), the daemon restart was enough. The container came back `running`, `restarts=0`, uid 1000 got `Permission denied`, root saw `/data` as `700 0:0` with 0 entries, `docker restart` did not help and recreating did. With `"live-restore": true` the daemon restart left the mount intact, because the container never stopped. A reboot afterwards emptied it the same way.

## Why it's easy to miss

Nothing reports a problem. The container is running, the restart policy did its job, there is no error in `docker ps`, `docker inspect` or the daemon log. `docker inspect` still lists the mount with its source path, so the configuration looks right too.

What the application sees depends on its user. A container running as root sees an empty directory, which looks like a bad image or a wrong path. A container running as a normal user sees `Permission denied` on every file, which sends you looking at ownership, user namespaces or SELinux, not at whether the files are there at all. The #53931 reporter ran their containers as uid 1000 and said exactly that: it looked like a permissions bug until they added group 0 and found the directory empty.

And the trigger is a reboot or a daemon restart, which is usually a kernel or Docker update. The breakage gets attributed to whatever was updated.

## What's really going on

An image mount is a mount on the host that Docker bind-mounts into the container. In the healthy container, the mount's `Source` is an overlay mount of the image:

{% raw %}
```
$ S=$(docker inspect -f '{{(index .Mounts 0).Source}}' im)
$ findmnt -n -o FSTYPE,TARGET $S
overlay /var/lib/docker/rootfs/overlayfs/26a6d376cea3...
```
{% endraw %}

That host-side mount is created when the container is set up, and a reboot removes it: mounts don't survive one. With overlay2, according to the open fix below, stopping the daemon also unmounts the layer's `merged` directory. After the reboot the broken container's `Source` was still a path of the same form (`/var/lib/docker/rootfs/overlayfs/4743bce542ca...`), and inside the container that path was an empty root-owned directory, so the image had not been mounted there again when the restart policy started it. A recreated container sets the mount up from scratch, which is why that works and `docker restart` does not.

For overlay2 this matches the explanation in the open fix, [moby#52734](https://github.com/moby/moby/pull/52734), which re-mounts the layer when a stopped container is restored. That PR says the containerd store is not affected, and it was not here for a daemon restart, but a reboot is a different event: it also clears the containerd store's mount. #50999 is about the `subpath` case, where the start fails loudly because the subdirectory is missing; without a subpath there is nothing to fail on, and the container just starts with the empty directory.

## The fix

Recreate the container:

```
$ docker rm -f im
$ docker run -d --name im --user 1000:1000 --restart always \
    --mount type=image,source=alpine:latest,target=/data alpine:latest sleep infinity
$ docker exec im cat /data/etc/alpine-release
3.24.2
```

With compose, `docker compose up -d --force-recreate <service>`. A plain `docker compose up -d` will not do it, because nothing in the definition changed.

Until there is a fixed release, anything that uses image mounts needs a recreate after every reboot, and on overlay2 after every daemon restart too (live-restore helps with the second). A unit that runs the recreate after `docker.service` at boot would do it, but that was not tested here.

The toolkit's `check-docker-image-mounts.sh` lists every running container's image mounts and counts the entries in each, as root inside the container. On the rebooted VM it printed:

```
  EMPTY    im  /data  (image /var/lib/docker/rootfs/overlayfs/4743bce542ca...)

1 image mount(s) are empty (containerd image store). Recreate the container; restarting it does not refill the mount.
```

and exited 1. After the recreate it reported `ok ... (17 entries ...)` and exited 0.

## The generalisable habit

A restart policy promises that the process comes back, not that its environment does. Anything a container depends on that lives outside it, a mount, a network attachment, a device, can fail to come back while the process itself starts fine. "Running" after a reboot is evidence about the process only.

So test reboots, not just restarts, and check the thing the service needs rather than its status: read a file through the mount, as the user the service runs as. This test only found the containerd store's behaviour on the second try, because the first one stopped at a daemon restart, which was fine.

This is the second Docker 29.9.1 container this month that starts cleanly without something it was created with: [a container that failed one start lost its network](https://homelabpostmortem.com/2026/10/18/docker-29-container-loses-its-network-after-one-failed-start/) the same quiet way.
