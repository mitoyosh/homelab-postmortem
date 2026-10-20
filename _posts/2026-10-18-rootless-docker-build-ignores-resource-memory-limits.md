---
title: "Rootless Docker builds ignore --resource memory limits without a warning, while docker run on the same daemon enforces them"
date: 2026-10-18
excerpt: "On rootless Docker 29.9.1 with buildx v0.38.0, a build step given --resource memory=256m used 600 MB and the build succeeded with no warning. docker run --memory 256m on the same daemon was killed with 137, so the cgroup delegation was there. The same build on rootful Docker failed with 137 as it should. Rootless BuildKit drops the step's resource settings before running it."
devto_title: "Rootless Docker builds silently ignore --resource memory limits"
devto_tags: docker, linux, security, devops
---

**TL;DR**: Per-step resource limits in BuildKit (`docker buildx build --resource memory=...`, Bake `resources`) are silently ignored when the builder is rootless, including the builder inside rootless Docker. On rootless Docker 29.9.1 with buildx v0.38.0, a `RUN` step limited to 256 MB allocated 600 MB and printed "not killed"; the build exited 0 and said nothing about the limit. On the same rootless daemon, `docker run --memory 256m` with the same allocation was killed (exit 137), so the cgroup controllers were delegated and limits were possible. On rootful Docker the build failed with 137, as intended. The upstream report ([moby/buildkit#7287](https://github.com/moby/buildkit/issues/7287)) points at BuildKit's rootless spec conversion, which removes the resource settings. The toolkit's `check-rootless-build-limits.sh` tells you which kind of builder you have and can measure it.

## The symptom

A disposable Debian 13 VM, Docker CE 29.9.1 installed rootless for a normal user with `dockerd-rootless-setuptool.sh install`. cgroup v2 with the systemd driver, and the user's service cgroup has the controllers delegated:

```
$ cat /sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/cgroup.subtree_control
cpu memory pids
```

A Dockerfile whose only step pushes 600 MB through a pipe buffer:

```
FROM alpine
RUN head -c 600m /dev/zero | tail > /dev/null && echo "not killed"
```

Built with a 256 MB limit on its steps:

```
$ docker buildx build --no-cache --progress=plain \
    --resource memory=256m --resource memory-swap=256m .
...
#5 11.79 not killed
...
rootless build rc=0
```

No warning about the limit anywhere in the output. The same allocation with `docker run` on the same rootless daemon:

```
$ docker run --rm --memory 256m --memory-swap 256m alpine sh -c 'head -c 600m /dev/zero | tail > /dev/null'
Killed
rc=137
```

And the same build on rootful Docker on the same VM:

```
rootful build rc=1      (the RUN step failed with "exit code: 137")
rootful build without --resource rc=0
```

## Why it's easy to miss

A limit that works shows up as a failure, and a limit that is ignored shows up as nothing. A build that stays within its limit looks the same either way, so the only way to see whether the limit exists is to exceed it on purpose. Most people set a limit to protect a small machine from one runaway step and never see it trigger.

The rootless daemon also behaves correctly in every other place you'd check. `docker run --memory` is enforced, `docker info` shows cgroup v2 with the systemd driver, and the limits are delegated. Nothing suggests the build path is different.

## What's really going on

Before BuildKit runs a step in rootless mode, it converts the container spec for rootless use. According to the issue, and in BuildKit's v0.34.0 source, that conversion (`ToRootless()`) sets the spec's Linux `Resources` to nil and clears its cgroup path, with a comment about cgroup v1, where an unprivileged user can't set limits. On cgroup v2 with delegation an unprivileged user can, which is how rootless `docker run --memory` works. The build path never gets to use it. The step runs with whatever cgroup the builder has, and the request is dropped before it reaches the runtime, so there is nothing to warn about at that point.

Which code path Docker's embedded builder takes was not traced here. What was measured is the effect: the limit is gone in rootless mode and present in rootful mode, with everything else equal.

The reporter has opened two fixes, [buildkit#7288](https://github.com/moby/buildkit/pull/7288) (warn when limits are dropped) and [#7289](https://github.com/moby/buildkit/pull/7289) (apply them on delegated cgroup v2). A maintainer approved #7288 on 19 October; neither is merged yet.

## The fix

There's no setting that makes rootless BuildKit apply them yet. The options:

- **Build on a rootful builder** where the limits matter. On this VM the rootful build was killed at the limit as intended.
- **Limit the builder as a whole.** In rootless Docker the builder runs inside the user's systemd service, so a `MemoryMax=` on that service (for example `systemctl --user edit docker` or a limit on `user@<uid>.service`) caps every build and container together. This was not tested here, and it is a ceiling for everything rather than a limit per step.
- **Know which one you have.** `check-rootless-build-limits.sh` reports whether the current Docker endpoint is rootless (exit 1 if it is). With `--probe` it builds a one-step image that allocates 300 MB under a 128 MB limit and reports what happened. On the rootless daemon:

```
Docker 29.9.1 (rootless): a step limited to 128 MB used 300 MB and the build succeeded.
--resource limits are not applied here.
```

exit 1. On the rootful daemon: `the step was killed at its 128 MB limit (137). Limits apply.`, exit 0.

## The generalisable habit

Test a limit by breaking it. "The flag was accepted" and "the build passed" say nothing about whether a limit exists; only a step that exceeds it and gets stopped does. Keep a tiny over-the-limit probe next to any limit you rely on, and run it whenever the environment changes, here from rootful to rootless.

And when one path enforces a limit, don't assume the neighbouring path does. `docker run` and `docker build` on the same daemon took the same `256m` and did different things with it.

This is the same shape as [a Pi that accepted every Docker memory limit and enforced none](https://homelabpostmortem.com/2026/08/19/pi-memory-cgroup-disabled-by-firmware/). There it was the memory controller that was missing, so `docker run` lied as well. Here the controller works and one code path throws the request away.
