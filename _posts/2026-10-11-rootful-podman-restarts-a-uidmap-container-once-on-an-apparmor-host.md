---
title: "On an AppArmor host, rootful Podman restarts a --uidmap container once and then leaves it stopped, logging that AppArmor is disabled"
date: 2026-10-11
excerpt: "On Debian 13 with Debian's podman 5.4.2 and AppArmor enabled, a rootful container with --uidmap/--gidmap and --restart always came back once and then stayed exited, while the same container without the mapping, or with apparmor=unconfined, kept restarting. podman events shows died, restart, then nothing. The cleanup process that should restart it fails with 'specified but AppArmor is disabled on the host', which is logged only for containers created with podman --syslog. Letting systemd restart it through Quadlet worked."
devto_title: "Rootful Podman restarts a --uidmap container once on an AppArmor host, then gives up"
devto_tags: podman, containers, linux, debian
---

**TL;DR**: On a host with AppArmor enabled, a rootful Podman container that has its own ID mapping (`--uidmap`/`--gidmap`) and a restart policy is restarted once at most. When it exits the second time it stays `exited`. `podman events` shows `died`, `restart`, and then nothing, and `RestartCount` stops at 1. The process that should restart it, `podman container cleanup`, fails with `profile "containers-default-0.62.2" specified but AppArmor is disabled on the host`. AppArmor is enabled, and the error is logged only if the container was created with `podman --syslog`. Reproduced on Debian 13 with Debian's podman 5.4.2. The upstream report is on Ubuntu 26.04 with 5.7.0 and 6.1.3, so it isn't Ubuntu-specific or new. The same container without the mapping, or with `--security-opt apparmor=unconfined`, kept restarting. A Quadlet unit with `UIDMap=` and `Restart=always` was restarted by systemd every time. The toolkit's `check-podman-restart-userns.sh` lists containers that are stuck or will get stuck. Upstream report: [podman-container-tools/podman#29925](https://github.com/podman-container-tools/podman/issues/29925).

## The symptom

A disposable Debian 13.7 VM (kernel 6.12.111, AppArmor enabled: `/sys/module/apparmor/parameters/enabled` is `Y`), `apt install podman`: podman 5.4.2, crun 1.21, conmon 2.1.12, containers-common 0.62.2. All as root. Three containers that exit after four seconds, each with `--restart always`:

```bash
podman run -d --name rtest-userns --restart always \
  --uidmap 0:200000:65536 --gidmap 0:200000:65536 alpine:3.22 sleep 4
podman run -d --name rtest-unconfined --restart always \
  --uidmap 0:200000:65536 --gidmap 0:200000:65536 \
  --security-opt apparmor=unconfined alpine:3.22 sleep 4
podman run -d --name rtest-plain --restart always alpine:3.22 sleep 4
```

Twenty-five seconds later:

```
rtest-userns:     exited  restarts=1  apparmor=containers-default-0.62.2
rtest-unconfined: running restarts=5  apparmor=unconfined
rtest-plain:      running restarts=5  apparmor=containers-default-0.62.2
```

The events for the mapped container:

```
create init start died restart
```

and nothing after that. `podman start rtest-userns` from a shell started it without complaint. `--restart on-failure:3` on a mapped container whose command exits 1 stopped the same way, at `restarts=1`.

Created with `podman --syslog run ...` instead, the same container left this in the journal when it stopped:

```
/usr/bin/podman[5105]: level=error msg="Cleaning up container: failed to clean up container 75c416f9...:
  profile \"containers-default-0.62.2\" specified but AppArmor is disabled on the host"
```

from the process `podman ... --syslog container cleanup --stopped-only <id>`, which conmon runs when the container exits.

## Why it's easy to miss

Everything you'd look at says the restart policy is working. The event stream has a `restart` event. `podman inspect` shows the policy as `always`. The first crash is handled, so a quick test that kills the container once and watches it come back passes.

The error itself goes nowhere by default. Without `--syslog` on the command that created the container, the cleanup process has no place to report it, so it isn't in the journal, in `podman logs`, or in the events. When you do find it, it says AppArmor is disabled on a host where it plainly isn't, which points at the host configuration rather than at Podman.

And the combination is narrow enough that most setups don't have it. Rootless Podman doesn't use AppArmor profiles. Fedora and RHEL use SELinux. Containers without their own mapping restart fine. It takes rootful Podman, an AppArmor distribution, and `--uidmap`/`--gidmap`, which is exactly what people reach for when they want rootful containers to run as unprivileged host IDs. Other ways of giving a container its own mapping, such as `--userns=auto`, weren't tested here.

## What's really going on

The message comes from `containers/common`'s AppArmor package. `IsEnabled()` there returns whether `IsSupported()` succeeds, and `IsSupported()` (v0.62.2, the version in Debian) checks three things in order: that the process isn't rootless, that the kernel reports AppArmor as enabled, and that the `apparmor_parser` binary can be found.

The upstream report doesn't explain the failure. The obvious guess is that the cleanup process thinks it is rootless. Here it isn't. Traced with `strace -f` on conmon as the container exited, the cleanup process ran as root, in the host's user namespace, with no Podman user-namespace variable in its environment, and it didn't re-execute itself or call `unshare`. conmon's capabilities were the same for the mapped and the plain container (`CapEff: 000001ffffffffff`, host user namespace). So whichever check fails, it fails for a process that looks the same as the one that successfully restarts the plain container. Which of the other two checks fails in that path wasn't pinned down here.

What is clear is the shape: the restart decision happens in the cleanup process, the cleanup process fails before it restarts the container, and the failure is reported only to syslog when asked for.

## The fix

Until Podman fixes it:

- **Let systemd do the restarting.** A Quadlet unit with the same mapping:

  ```ini
  [Container]
  Image=docker.io/library/alpine:3.22
  Exec=sleep 4
  UIDMap=0:200000:65536
  GIDMap=0:200000:65536

  [Service]
  Restart=always
  RestartSec=1
  ```

  restarted 4 times in 25 seconds, with no AppArmor error in its journal. Quadlet runs the container with `--rm` and no `--restart`, so each restart is a new `podman run` from systemd, and Podman's own restart path isn't used.
- **`--security-opt apparmor=unconfined`** also avoids it, as the table shows. That removes the container's AppArmor confinement, so it is a trade, not a fix.
- **Create containers with `podman --syslog`** if you depend on Podman's restart policy. It doesn't fix anything, but the failure is then in the journal instead of nowhere.

To find containers already in this state, `check-podman-restart-userns.sh` lists every container with a restart policy that is `exited` without having been stopped by the user (STUCK), and every running one that is rootful, mapped, confined and set to restart on an AppArmor host (AT RISK, because it will stop the same way next time). On the test VM it reported the stuck and the at-risk containers, and passed one stopped by the user, one that exited 0 under `on-failure`, and the `unconfined` one.

## The generalisable habit

A restart policy is only tested when the thing has stopped more than once. The common test, kill it and see it come back, exercises the first restart, which here worked. The question to ask is "what does the second exit look like", and the place to look is the restart count after a few cycles, not whether the container is up right now.

The same goes for a supervisor's error reporting. When the component that does the restarting is a short-lived helper process, find out where its errors go before you need them. Here they went to syslog only on request. [Podman's compat API resetting the restart policy to `no`](https://homelabpostmortem.com/2026/09/18/podman-compat-api-update-resets-the-restart-policy-to-no/) was the same kind of failure: the container looks configured to come back, and after the next crash it doesn't.
