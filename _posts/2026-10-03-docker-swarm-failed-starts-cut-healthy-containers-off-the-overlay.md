---
title: "A Docker swarm service failing on a taken host port cut every container on the node off its overlay network, and docker ps still said running"
date: 2026-10-03
excerpt: "The overlay driver destroys a network's sandbox on a node when its join count reaches zero, and every container start that fails after the driver's Join takes one too many off that count. A swarm service publishing a host port that was already in use retried on its own, and within 20 seconds both healthy containers on the same overlay network were NO-CARRIER while docker ps showed them running. Restarting them didn't help; restarting the daemon did. Docker 29.8.2, the current release."
devto_title: "A failing Docker swarm service cut healthy containers off the overlay network"
devto_tags: docker, networking, selfhosted, debugging
---

**TL;DR**: On a Docker swarm node, the overlay driver keeps a count of how many endpoints have joined each network there, and destroys the network's sandbox on that node when the count reaches zero. When a container start fails after the driver's `Join` (for example because the host port it publishes is taken), libnetwork rolls the join back by calling `Leave` twice, so every such failure takes one more off the count than it added. On Docker 29.8.2, a node with two healthy containers on an overlay network lost that network within 20 seconds of creating a swarm service that published a host port another container already held. Nobody touched anything: the service's own retries did it. Both containers went `NO-CARRIER`, could no longer reach anything on the overlay, and `docker ps` showed them running throughout. Restarting the containers didn't bring them back. Restarting the daemon did. The toolkit's `check-overlay-sandbox.sh` finds containers in that state. Upstream report: [moby/moby#53834](https://github.com/moby/moby/issues/53834).

## The symptom

A Debian 13 VM on Proxmox, Docker 29.8.2 from Docker's apt repository (the current release; the report was against 29.8.1), `docker swarm init` as a single-node swarm. An attachable overlay network with two long-running containers on it, and one more container on the default bridge holding host port 8080:

```bash
docker network create -d overlay --attachable ovs
docker run -d --name c1 --network ovs alpine sleep infinity
docker run -d --name c2 --network ovs alpine sleep infinity
docker run -d --name holder -p 8080:80 alpine sleep infinity
```

Then a service that wants port 8080 in host mode. Port conflicts happen easily, from a leftover container, a second compose project or a forgotten test:

```bash
docker service create -d --name web --network ovs \
  --publish mode=host,target=80,published=8080 alpine sleep infinity
```

The service's task fails, and swarm schedules a new one, again and again:

```
starting container failed: failed to set up container networking: ... endpoint join on GW Network
failed: driver failed programming external connectivity on endpoint gateway_8e90e46aa0fb (...):
Bind for 0.0.0.0:8080 failed: port is already allocated
```

Meanwhile, on the containers that had nothing to do with it (`ping` from each to the network's load-balancer endpoint):

```
baseline   c1 ping=0  c2 ping=0  netns=present  c1/c2 running
t+10 s     c1 ping=0  c2 ping=0  netns=present  (2 failed tasks)
t+20 s     c1 ping=1  c2 ping=1  netns=MISSING  c1/c2 running  (4 failed tasks)
t+45 s     c1 ping=1  c2 ping=1  netns=MISSING  c1/c2 running
```

Inside them the overlay interface had lost its carrier:

```
eth0: <NO-CARRIER,BROADCAST,MULTICAST,UP,M-DOWN> state DOWN
```

The same happens without swarm services, with plain `docker run`. With one container on the network, the second failed `docker run --network ovp -p 8080:80 ...` against the taken port cut it off. The report used an invalid endpoint sysctl as the failing step, which reproduced here the same way: two failures with one container on the network, three with two.

## Why it's easy to miss

The damage lands on containers that did nothing wrong, and the error lands somewhere else. The failing service logs a port conflict, which looks like the whole story: fix the port, and the service starts. The containers that lost their network stay `running` and healthy by every check that doesn't send traffic over the overlay. Health checks that only test the process inside the container still pass. The symptom other services see is "can't reach c1", and `docker ps` and `docker inspect` still show it running.

The usual reflex doesn't work once it has gone far. After the service's retries had failed more times than there were joins, restarting `c1` and `c2` left the sandbox missing. Stopping both and starting them again recreated `/run/docker/netns/1-…`, but the ping still failed. Only restarting the daemon brought them back:

```
restart c1 and c2               ping=1 ping=1  netns=MISSING
stop both, start both           ping=1 ping=1  netns=present
systemctl restart docker        ping=0 ping=0  netns=present
```

(After only two manual failures on a one-container network, a plain `docker restart c1` was enough. How much it takes depends on how far past zero the count went.)

## What's really going on

The overlay driver, `daemon/libnetwork/drivers/overlay/ov_network.go` in 29.8.2:

```go
if incJoinCount {
    n.joinCnt++
}
...
func (n *network) leaveSandbox() {
    n.joinCnt--
    if n.joinCnt != 0 {
        return
    }
    n.destroySandbox()
```

And the caller, `Endpoint.sbJoin` in `daemon/libnetwork/endpoint.go`, which sets up two rollbacks for one join:

```go
defer func() {
    if retErr != nil {
        if err := ep.sbLeave(ctx, sb, n, true); err != nil { ... }   // calls d.Leave(...)
    }
}()
...
if err := d.Join(ctx, nid, epid, sb.Key(), ep, ep.generic, sb.Labels()); err != nil {
    return err
}
defer func() {
    if retErr != nil {
        if err := d.Leave(nid, epid); err != nil { ... }              // and so does this
    }
}()
```

If anything after `d.Join` fails, both deferred functions run, and the driver sees one `Join` and two `Leave`s. Each failed start therefore costs the network one join it never had. On a node, the count is the containers on the network plus the network's load-balancer endpoint, so a node with N containers on an overlay network loses it after N+1 such failures. These accumulate over the daemon's lifetime, so they don't have to come in a burst. Once the count reaches zero the sandbox is destroyed under the containers still attached. If it goes below zero, the bookkeeping is wrong for every later join on that network until the daemon restarts. That matches what the recovery attempts showed.

A swarm service is the efficient way to get there. Its restart policy turns one bad port into a stream of failed starts, a few per ten seconds, and every one takes another join off the count.

## The fix

There is no release with a fix. The reporter has one ready, pending a maintainer's view. Until then:

**Fix the failing start first.** Anything that fails a container start on an overlay network after the driver has joined (a published host port in use, a bad endpoint option) counts against the healthy containers on that node. A service in a restart loop counts every few seconds. `docker service ps <service> --no-trunc` shows the error. Scale the service to zero or remove it while you fix it.

**Then restart the daemon on that node** if containers are already cut off:

```bash
systemctl restart docker
docker start <containers without a restart policy>
```

Restarting the affected containers may be enough if the count only just reached zero. Here it wasn't, once a service had been retrying.

**Check, rather than trust `docker ps`.** On each node, the sandbox for a network with local containers should exist, and each container's interface on it should have a carrier:

{% raw %}
```bash
NET=ovs
ls /run/docker/netns/1-$(docker network inspect $NET -f '{{slice .Id 0 10}}')
docker exec c1 ip link show eth0      # NO-CARRIER = cut off
```
{% endraw %}

## The generalisable habit

`running` describes the process, not its connections, and the errors are on the container that failed rather than on the ones that paid for it. When a failure can have side effects on shared state, here a per-node reference count, look at the bystanders as well as the thing that failed. A cheap way to cover this is a check that sends real traffic over the network a container depends on, not one that only asks whether the process is alive.

It is the second time on this site that Docker reported success over a broken state: [`docker logs` stops at a NUL byte in a json-file log and exits 0](https://homelabpostmortem.com/2026/09/12/docker-logs-stops-at-a-nul-byte-and-exits-0/). Both times, the command whose job was to tell you said nothing was wrong.

The toolkit's `check-overlay-sandbox.sh` (run as root on each swarm node) checks every overlay network with local containers: that its sandbox exists, and that each running container's interface on it has a carrier. It reads the interface flags from inside the container's network namespace. It also counts swarm tasks that failed during network setup and are still listed, since each of those may have taken a join off the count.
