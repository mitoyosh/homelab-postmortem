---
title: "Since Docker 29.6, docker exec creates world-writable files in docker-in-docker and rootless Docker, and not on a normal install"
date: 2026-10-20
excerpt: "Docker 29.6 set dockerd's umask to 0000. On the standard docker-ce packages nothing visible changed, because containerd runs as its own service with 0022. In docker:29.9.1-dind and in rootless Docker, where dockerd starts containerd itself, every process started with docker exec ran with umask 0000 and created files as 0666 and directories as 0777. docker:29.5.3-dind did not. --umask 0022 on the container fixes exec too."
devto_title: "Docker 29.6+: docker exec creates world-writable files in dind and rootless Docker"
devto_tags: docker, security, linux, devops
---

**TL;DR**: Since Docker 29.6.0, dockerd runs with umask `0000`, so that modes you ask for explicitly (such as `COPY --chmod=777`) are not filtered. A process started with `docker exec` inherits its umask from the container's shim, which inherits it from containerd. On the standard docker-ce packages containerd is a separate systemd service with umask `0022`, and exec'd processes still got `0022`. But in docker-in-docker (`docker:29.9.1-dind`) and in rootless Docker, dockerd starts containerd itself, and there every `docker exec` ran with umask `0000`: `touch` made `-rw-rw-rw-` files and `mkdir` made `drwxrwxrwx` directories, with no warning. `docker run`'s main process still got `0022`. `docker:29.5.3-dind` was fine; `docker:29.6.0-dind` was not. Creating the container with `--umask 0022` fixes exec too. Upstream: [moby/moby#53985](https://github.com/moby/moby/issues/53985), filed from OrbStack on macOS, which has the same structure.

## The symptom

A disposable Debian 13 VM with Docker CE 29.9.1 from download.docker.com. The test is the one from the upstream report: start a container, exec `umask` in it, create a file and a directory.

On the plain install, nothing looks wrong:

```
dockerd: Umask:	0000
containerd: Umask:	0022
shim (after run): Umask:	0022
exec umask: 0022
  exec created: drwxr-xr-x /tmp/d
  exec created: -rw-r--r-- /tmp/f
```

dockerd itself is at `0000`, but containerd isn't, and the shim and the exec'd shell follow containerd.

Inside `docker:29.9.1-dind`, which runs its own dockerd and lets it start containerd, the same steps:

```
dockerd: Umask:	0000
shim: Umask:	0000
inner exec umask: 0000
  inner exec created: drwxrwxrwx /tmp/d
  inner exec created: -rw-rw-rw- /tmp/f
inner run umask: 0022
```

And with rootless Docker, set up with `dockerd-rootless-setuptool.sh install` on the same VM:

```
dockerd: Umask:	0000
containerd: Umask:	0000
exec umask: 0000
  exec created: -rw-rw-rw-
run umask: 0022
```

The version boundary, in dind:

```
=== docker:29.5.3-dind
server: 29.5.3  dockerd Umask:	0022
inner exec umask: 0022
=== docker:29.6.0-dind
server: 29.6.0  dockerd Umask:	0000
inner exec umask: 0000
```

## Why it's easy to miss

On the setup most people test with, the docker-ce packages on a Linux host, it doesn't happen. That is probably why the change, merged in June, was only reported in October.

Where it does happen, nothing fails at the time. The files are created, the command exits 0, and everything works, because world-writable is more permissive, not less. The trouble shows up later and somewhere else. In the upstream report, files written by a `docker exec` hook were `0666`, and OpenSSH refused to use them (`Bad owner or permissions`). Other tools that check permissions refuse such files the same way; SSH private keys are the usual example. And anything written to a volume shared with other containers or users is writable by all of them.

The places it does happen are common in homelabs and CI: Docker-in-Docker CI runners, rootless Docker on a shared machine, Docker Desktop alternatives on a laptop. `docker run` behaves normally in all of them, so a quick test that starts a container and creates a file looks fine. Only `exec` is affected, and setup scripts, CI steps and maintenance commands are exactly what people run with `exec`.

## What's really going on

[moby#52892](https://github.com/moby/moby/pull/52892), "daemon: Set umask to 0000", merged in June for 29.6.0, clears the daemon's umask so that "explicitly requested file modes are preserved instead of being filtered by the previous `0022` umask". That fixes things like `COPY --chmod=777` producing `0755`.

A process's umask is inherited by its children. The container's main process doesn't care: runc sets `0022` for it explicitly. An exec'd process gets no such default when the container spec has no umask, so it keeps whatever its parent, the shim, has. The shim is started by containerd and inherits containerd's umask.

So the outcome depends on who started containerd. With the docker-ce packages, containerd is `containerd.service`, started by systemd with the usual `0022`, and dockerd's `0000` never reaches it. In dind and rootless Docker, dockerd starts containerd as its own child, containerd inherits `0000`, and so does every shim and every exec. The upstream reporter, on OrbStack, saw dockerd, containerd and every shim at `0000` as well.

The open fix, [moby#53986](https://github.com/moby/moby/pull/53986), sets `0022` for exec processes when the container spec has no umask.

## The fix

Until that lands, either give the container its own umask or set one in each exec.

**Create the container with `--umask 0022`** (the flag came with [moby#53463](https://github.com/moby/moby/pull/53463) in Docker 29.8.0). Exec'd processes then use it too:

```
inner --umask 0022: exec umask 0022              (dind 29.9.1)
rootless --umask 0022: exec umask 0022           (rootless 29.9.1)
```

It needs a recreate, and it applies per container.

**Or set the umask in the exec'd command:**

```
docker exec <container> sh -c 'umask 022; <command>'
```

That gave `0022` in rootless Docker and works on any version, but every caller has to remember it.

A plain install of the docker-ce packages doesn't need either. Check rather than assume, since a distribution package or a custom setup may start containerd differently.

The toolkit's `check-docker-exec-umask.sh` reads the shim's umask for every running container from `/proc`, notes which containers were created with their own `--umask`, and with `--probe` runs `umask` in a throwaway container with `docker exec`. In rootless Docker on the VM:

```
  ok       r2: created with --umask 0022; exec uses it
  AFFECTED r1: shim umask 0000, so docker exec processes create 0666 files and 0777 directories
  probe    docker exec in a new container without --umask: umask 0000
```

It exits 1 there and inside `docker:29.9.1-dind`, and 0 on the plain install and on 29.5.3.

## The generalisable habit

When a change sets something process-wide, ask what inherits it. A umask, an environment variable, a resource limit or an open file descriptor is passed down to every child, and the change's author tested the processes they had in mind. Here that was the daemon's own file creation; the exec'd process three generations down was not.

And reproduce on the reporter's setup, not just on the usual one. On a standard install this looked like a bug that didn't exist. The process tree is what differs, so the first thing to check was who starts containerd.

Rootless Docker has another quiet difference from rootful on this same release: [`docker buildx build --resource` limits are ignored there](https://homelabpostmortem.com/2026/10/18/rootless-docker-build-ignores-resource-memory-limits/).
