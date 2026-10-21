---
title: "Since Docker 29.8, a Swarm container can't reach a port published on its own node when ufw is on, and the host itself still can"
date: 2026-10-18
excerpt: "On a single-node Swarm with Docker 29.9.1 and ufw's default deny, a container on an overlay network timed out connecting to a service's ingress-published port on the node, while curl from the host got HTTP 200. ufw logged the drop on docker_gwbridge. A Swarm created on 29.7.2 passed. Allowing just the published port in on docker_gwbridge fixes it without opening the whole interface."
devto_title: "Docker 29.8+: Swarm containers can't reach their own node's ports under ufw"
devto_tags: docker, networking, linux, security
---

**Update 2026-10-21.** It isn't only Swarm. A Docker maintainer explained in [#53962](https://github.com/moby/moby/issues/53962#issuecomment-6296732678) that since 29.8.0 Swarm ports are published through the same machinery as ordinary bridge-published ports, and that ufw's default policy also blocks a container from reaching a bridge-published port when the client is on the same bridge, an existing bug that Swarm inherited. Tested on a fresh Debian 13 VM with ufw as below and no Swarm: a container on a user-defined network `appnet` calling `<host-ip>:8080`, published by another container on `appnet`, timed out, as did a container on the default bridge calling a port published from the default bridge. A container on a different network, and the host itself, got through. The same per-port rule fixed it, on the bridge the client comes from (`ufw allow in on br-<network id> to any port 8080 proto tcp`, or `on docker0` for the default bridge), and so did `"userland-proxy": false`. Docker 29.9.2 and 29.7.2 behaved the same; on 28.5.2 a container on a different network was blocked too. `check-swarm-ufw-ingress.sh` now checks bridge-published ports as well and names the bridge each rule needs.

**TL;DR**: On Docker 29.9.1 with Swarm and ufw (default deny incoming), a container on an overlay network that connects to an ingress-published port on the same node times out. The host itself, connecting to the same address and port, gets HTTP 200. The kernel log shows ufw dropping the SYN as it arrives from `docker_gwbridge`. A Swarm and service created on 29.7.2 passed the same test. The upstream report ([moby/moby#53962](https://github.com/moby/moby/issues/53962)) traces it to 29.8.0, which hands this connection to `docker-proxy` through the host's INPUT chain instead of DNATing it. The workaround in that thread, `ufw allow in on docker_gwbridge`, works but opens every host port to every container on the node. A per-port rule works too: `ufw allow in on docker_gwbridge to any port 8080 proto tcp`.

## The symptom

A disposable Debian 13 VM, Docker CE 29.9.1, ufw with nothing but SSH allowed:

```
$ ufw default deny incoming && ufw allow 22/tcp && ufw enable
$ docker swarm init --advertise-addr 192.168.128.179
$ docker network create -d overlay --attachable appnet
$ docker service create --name web -p 8080:80 --network appnet nginx:alpine
```

A single node, so the service's task always runs on the node being connected to. From a container on the overlay network, through the published port:

```
$ docker run --rm --network appnet alpine wget -T 5 -qO- http://192.168.128.179:8080/; echo rc=$?
rc=1                  (nothing back within the 5 s timeout)
```

The kernel log at the same moment:

```
[UFW BLOCK] IN=docker_gwbridge OUT= ... SRC=172.18.0.4 DST=192.168.128.179 ... DPT=8080
```

From the host, same address and port:

```
$ curl -s -o /dev/null -w '%{http_code}\n' http://192.168.128.179:8080/
200
```

`ss -tlnp` showed `docker-proxy` listening on `0.0.0.0:8080` and `[::]:8080`. `ufw disable` made the container's request succeed, and so did `"userland-proxy": false` in `daemon.json` with ufw left on.

On 29.7.2 with a Swarm created on that version, the same probe succeeded with ufw on and nothing allowed. No `UFW BLOCK` line, no `docker-proxy` on 8080, and a DNAT rule for the port in the nat table's `DOCKER-INGRESS` chain instead. One detail from getting there: downgrading the packages to 29.7.2 and keeping the Swarm and service created on 29.9.1 still failed the same way. Only after `docker swarm leave --force` and re-creating them on 29.7.2 did it pass.

## Why it's easy to miss

Every check from outside the container passes. The service is up with 1/1 replicas, the port answers from the host and, according to the report, from other nodes.

What fails is one container calling another service by the node's address and published port, which is common in homelab setups: a reverse proxy pointing at `host:port`, or an app configured with the host's IP because that's what the documentation showed. It shows up as a timeout, not a refusal, so it looks like a routing or overlay MTU problem. Those are what search results are full of.

And the trigger was a minor Docker upgrade on a machine where ufw had been configured long before. Nothing about the firewall changed.

## What's really going on

Up to 29.7, a connection to an ingress-published port from a container on the same node was DNATed by Docker's rules in the nat table and never reached the host's INPUT chain. ufw's rules live in INPUT and never saw it.

According to the reporter's analysis in #53962, since 29.8.0 the per-port DNAT rule excludes traffic arriving from `docker_gwbridge`, which is where a container's connection to the node address comes from. With the userland proxy on (the default), that connection is delivered to the host and accepted by `docker-proxy` instead. Being addressed to the host, it goes through INPUT, where ufw's default deny drops it. The test here matches every part of that: the drop logged with `IN=docker_gwbridge`, `docker-proxy` listening on 29.9.1 and not on 29.7.2, the DNAT rule on 29.7.2, and both `ufw disable` and `userland-proxy: false` fixing it. The connection from the host itself never crosses `docker_gwbridge`, which is why it still works.

[moby#53723](https://github.com/moby/moby/pull/53723), merged in September, fixed the same kind of path with the userland proxy disabled. A maintainer asked in the issue whether 29.9.1 still shows the problem. On this single-node test, it does.

## The fix

The workaround in the issue is to let everything in from `docker_gwbridge`:

```
$ ufw allow in on docker_gwbridge
```

It works (the probe passed), but `docker_gwbridge` is where every container on the node reaches the host from, so it exposes every port the host listens on, including SSH and anything bound to `0.0.0.0`, to every container on that node.

Allowing only the published ports is enough. With two services, `web` on 8080 and `web2` on 9090:

```
$ ufw allow in on docker_gwbridge to any port 8080 proto tcp
  probe 8080: rc=0   probe 9090: rc=1
$ ufw allow in on docker_gwbridge to any port 9000:9100 proto tcp
  probe 8080: rc=0   probe 9090: rc=0
```

Each published port needs its own rule (or a range), and a new service needs a new one. Two alternatives, both observed to work: connect to the service by name on the overlay network (`http://web/`, which never leaves the overlay), or set `"userland-proxy": false`, which has wider effects on how Docker publishes ports and is worth reading up on before changing.

The toolkit's `check-swarm-ufw-ingress.sh` lists the node's ingress-published ports and says which ones have no matching ufw rule on `docker_gwbridge`. With no rules:

```
  DROPPED  web  8080/tcp
  DROPPED  web2  9090/tcp

UFW BLOCK lines from docker_gwbridge in the last day: 21
Docker 29.9.1, swarm + ufw: containers on this node cannot reach 2 of 2 ingress-published port(s) on this node.
```

It exits 1 until every port is covered, and 0 with the per-port rules or the interface-wide one. The ports come from `docker service inspect`, so it needs to run on a manager.

## The generalisable habit

Test from where the client actually is. "The port answers" checked from the host and "the port answers" checked from a container are different claims, and here only the first one was true. When something works from the host and times out from a container on the same machine, look at the firewall's log for the bridge the container comes from before looking at routing.

The other habit is about workarounds. The first one that works is often the widest one, and an interface-wide allow on a bridge is a much bigger change than the bug it works around. Narrow it, and test the narrow version too.

This is the reverse of an older problem on this site: [Docker publishing ports straight past ufw](https://homelabpostmortem.com/2026/08/22/docker-publishes-past-ufw/), where ufw said a port was closed and Docker made it reachable anyway. Here ufw is consulted where it wasn't before, and the traffic it now drops is Docker's own.
