---
title: "Since Docker 29, one failed start during network setup leaves a container that starts fine forever after, with only a loopback interface"
date: 2026-10-18
excerpt: "On Docker 29.9.1, a container whose start failed while binding a published port (the host address did not exist yet) lost its network from its configuration. When the address appeared, docker start returned 0 and the container ran with only lo: no eth0, no published ports, no error, and it stayed that way across daemon restarts. Docker 28.5.2 kept the network and recovered on the next start. docker network connect brings it back."
devto_title: "Docker 29: one failed start leaves a container running with only loopback"
devto_tags: docker, networking, linux, selfhosted
---

**TL;DR**: In Docker 29, when a container's start fails while its network is being set up, for example because a published port is bound to a host address that does not exist yet, Docker removes that network from the container's configuration. Every later start then succeeds with no network at all: exit 0, state `running`, only `lo` inside, no published ports, and nothing in the output says so. On Docker 29.9.1 this persisted across `systemctl restart docker`. Docker 28.5.2, same steps, kept the network and came up normally once the address existed. The change came with [moby#50945](https://github.com/moby/moby/pull/50945) ("Tidy up when endpoint join fails", in 29.0.0). `docker network connect <net> <container>` and a restart put it back. Upstream report: [moby/moby#53928](https://github.com/moby/moby/issues/53928).

## The symptom

A disposable Debian 13 VM, Docker CE 29.9.1 from download.docker.com. A container on a user-defined network, publishing a port on a specific host address that is not configured yet, which is what happens at boot when an address comes up after Docker:

{% raw %}
```
$ docker network create repro-net
$ docker create --name repro --network repro-net -p 192.0.2.10:6399:6379 valkey/valkey:9
$ docker start repro
Error response from daemon: failed to set up container networking: driver failed programming
external connectivity on endpoint repro (...): failed to bind host port 192.0.2.10:6399/tcp:
cannot assign requested address
rc1=1
$ docker inspect repro --format '{{json .NetworkSettings.Networks}}'
{}
```
{% endraw %}

The failure is fine and expected. The empty `Networks` is not: the container has forgotten it was ever on `repro-net`. Now the address appears and the container is started again:

{% raw %}
```
$ ip addr add 192.0.2.10/32 dev lo
$ docker start repro
repro
rc2=0
$ docker inspect repro --format '{{.State.Status}} {{json .NetworkSettings.Networks}}'
running {}
$ docker exec repro cat /proc/net/dev | awk 'NR>2{print $1}'
lo:
$ docker port repro
$
```
{% endraw %}

Running, exit 0, no `eth0`, no port. `systemctl restart docker` followed by another start gave the same `lo` only. A new container created on the same network with the same host address came up with `eth0` and its port, so the network and the address were fine. Only the container that had failed once was broken.

The same steps on Docker 28.5.2:

```
rc1=1      (same "cannot assign requested address")
networks={"repro-net":{...}}
rc2=0
lo:
eth0:
6379/tcp -> 192.0.2.10:6399
```

## Why it's easy to miss

The failed start is visible, but it looks transient: the address wasn't there yet, and once it is, `docker start` succeeds. With `--restart always` or a compose stack brought up at boot, nobody even sees the first failure; they see a container that is up.

Nothing afterwards hints at it. `docker ps` shows it running, the exit code is 0, there is no warning in the start output or in `docker inspect`'s state. The only signs are an empty `NetworkSettings.Networks`, a missing `eth0` inside, and `docker port` printing nothing, none of which people check on a container that "started fine". The service inside is healthy and listening; it just can't be reached and can't reach anything.

## What's really going on

`connectToNetwork` in `daemon/container_operations.go` (docker-v29.9.1) adds the network to the container's settings and arms a cleanup for failure:

```go
delete(ctr.NetworkSettings.Networks, n.ID())
ctr.NetworkSettings.Networks[nwName] = endpointConfig
defer func() {
    if retErr != nil {
        delete(ctr.NetworkSettings.Networks, nwName)
    }
}()
```

If the endpoint join fails, which is where the port binding is programmed, the network is deleted from the container's stored settings. That cleanup came in with [#50945](https://github.com/moby/moby/pull/50945), merged in September 2025 and first released in 29.0.0. It tidies up a half-joined endpoint, but the settings it deletes from are also the container's record of which networks it belongs to. With that record empty, the next start has nothing to connect, and a container with no networks starts happily with only the loopback interface.

## The fix

For a container already in this state, reconnect it and restart it:

```
$ docker network connect repro-net repro
$ docker restart repro
$ docker exec repro cat /proc/net/dev | awk 'NR>2{print $1}'
lo:
eth0:
$ docker port repro
6379/tcp -> 192.0.2.10:6399
```

Recreating the container (`docker compose up -d --force-recreate`, or `docker rm` and `docker run`) also works, because a new container gets its networks from its definition again.

To find affected containers, look for running containers whose network mode is a named network but which have no networks attached:

{% raw %}
```bash
docker ps -q | xargs docker inspect --format '{{.Name}} {{.HostConfig.NetworkMode}} {{len .NetworkSettings.Networks}}' \
  | awk '$2!="host" && $2!="none" && $2 !~ /^container:/ && $3==0'
```
{% endraw %}

On the broken container above it printed `/repro repro-net 0`; after the reconnect it printed nothing. Use `docker ps -aq` instead to include stopped containers, which will come up the same way the next time they start. The toolkit's `check-docker-lost-network.sh` does the same check (`--all` for stopped containers) and exits 1 when it finds one.

The trigger here was an address that didn't exist yet, so publishing on `0.0.0.0` instead of a specific address avoids that particular failure. Ordering Docker after the interface that carries the address should too, but that was not tested here. And it only removes one trigger: on 29.x, any failure while the network is being set up leaves the same state.

## The generalisable habit

Cleanup code that undoes a half-finished operation should only remove what the operation added. Here the network entry was the container's configuration, written before the operation started, and the cleanup treated it as part of the attempt. After that, every later success was built on a record that had quietly lost something.

The check that catches this kind of bug is to compare the object's configuration before and after a failure, not just whether the next attempt succeeds. Success on retry is what you'd expect to see whether or not something was lost.

The same Docker release line has another quiet failure-start trap on Swarm: [failed starts on a taken host port cut healthy containers off the overlay](https://homelabpostmortem.com/2026/10/03/docker-swarm-failed-starts-cut-healthy-containers-off-the-overlay/). Both times, a start that failed changed state that the next success didn't put back. And a container with a `type=image` mount can come back from a reboot [running, with the mount empty](https://homelabpostmortem.com/2026/10/18/docker-image-mount-comes-back-empty-after-a-reboot/).
