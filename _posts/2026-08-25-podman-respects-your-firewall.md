---
title: "Podman publishes the same port and your firewall still holds. Even as root."
date: 2026-08-25
excerpt: "A commenter said rootless Podman avoids the Docker-bypasses-ufw problem because it has no root to write firewall rules with. The conclusion is right and the reason isn't: running Podman as root still leaves ufw in control. The difference is netavark's design, not the privilege level."
devto_tags: podman, docker, security, linux
---

**TL;DR**: On the same box, same port, same `ufw` config where [Docker published straight past the firewall](https://homelabpostmortem.com/2026/08/22/docker-publishes-past-ufw/), Podman does not — the port times out from another machine exactly as `ufw status` claims. Rootless Podman writes no firewall rules at all. But **rootful Podman does write them, and the port is still blocked**, so "it has no root" is not the explanation. Docker inserts an ACCEPT into `FORWARD` ahead of ufw's chains; netavark keeps its rules in its own table and never overrides ufw's `policy drop`. Also: Podman never needed `iptables` installed at any point.

## Where this came from

The Docker writeup got a comment on r/selfhosted saying, roughly: this is why I use rootless Podman — it can't modify the system firewall if it doesn't have root.

That is a satisfying explanation, and I wanted it to be true, which is a good reason to go and check it rather than repeat it. It turns out to be right about the outcome and wrong about the mechanism, and the wrong part is the more interesting half.

## Setup

Identical to the Docker test, deliberately. Raspberry Pi OS Lite (Trixie) on a Pi 4B, `ufw` active, default deny incoming, one rule for SSH:

```bash
$ sudo ufw status verbose
Status: active
Default: deny (incoming), allow (outgoing), disabled (routed)

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    Anywhere
```

Baseline, before any container runtime: a plain listener on 8080 is blocked from another machine on the LAN.

```
$ python3 -m http.server 8080 --bind 0.0.0.0
# from the laptop:
192.168.128.154:8080 → Connection timed out
```

Then `apt install podman` — 26 packages, none of them `iptables`. It pulls `netavark` (Podman's network backend), `aardvark-dns`, and `passt`/`slirp4netns` for rootless networking.

## Rootless: no firewall rules at all

```bash
$ podman run -d --name pmtest -p 8080:80 docker.io/library/nginx:alpine
$ podman ps --format '{% raw %}{{.Ports}}{% endraw %}'
0.0.0.0:8080->80/tcp
```

That is byte-identical to what Docker printed. Bound to all interfaces, same port, same everything. Locally it answers:

```
localhost:8080 → HTTP 200
```

From another machine:

```
192.168.128.154:8080 → timed out
```

And the firewall is untouched:

```bash
$ sudo nft list ruleset | wc -l
387                      # unchanged from before the container started
$ sudo nft list ruleset | grep -c 8080
0
$ sudo nft list tables
table ip filter
table ip6 filter         # ufw's. No nat table, no netavark table.
```

Nothing. No DNAT, no ACCEPT, no new table. The commenter's description holds exactly here: rootless has no way to write these rules, so it doesn't, and `ufw` decides — correctly.

## Rootful: rules appear, and the port is *still* blocked

This is the part that decides whether "no root" is really the explanation.

```bash
$ sudo podman run -d --name pmroot -p 8080:80 docker.io/library/nginx:alpine
$ sudo podman ps --format '{% raw %}{{.Ports}}{% endraw %}'
0.0.0.0:8080->80/tcp
```

Now the firewall *does* change:

```bash
$ sudo nft list ruleset | wc -l
447                      # was 387
$ sudo nft list ruleset | grep -c 8080
4
$ sudo nft list tables
table ip filter
table ip6 filter
table inet netavark      # new
```

Rules written, DNAT in place. By the Docker precedent this is the moment the port becomes reachable. It doesn't:

```
192.168.128.154:8080 → timed out
```

So the privilege level is not what saved us. Something about *which* rules get written is.

## What netavark actually writes

```
table inet netavark {
    chain FORWARD {
        type filter hook forward priority filter; policy accept;
        ct state invalid drop
        jump NETAVARK-ISOLATION-1
        ip daddr 10.88.0.0/16 ct state established,related accept
        ip saddr 10.88.0.0/16 accept
    }

    chain PREROUTING {
        type nat hook prerouting priority dstnat; policy accept;
        fib daddr type local jump NETAVARK-HOSTPORT-DNAT
    }

    chain NETAVARK-HOSTPORT-DNAT {
        tcp dport 8080 jump nv_2f259bab_10_88_0_0_nm16_dnat
    }
}
```

The DNAT is there and it works — more on proving that below. What matters is the FORWARD chain. netavark's accepts are scoped to its own container network, `10.88.0.0/16`. It has `policy accept`, but it only *accepts* traffic that belongs to it.

ufw's FORWARD chain, in a separate table, is not so relaxed:

```
chain FORWARD {
    type filter hook forward priority filter; policy drop;
    counter packets 19 bytes 2309 jump ufw-before-logging-forward
    counter packets 19 bytes 2309 jump ufw-before-forward
    counter packets 19 bytes 2309 jump ufw-after-forward
}
```

`policy drop`, and a counter that is climbing — those 19 packets are the connection attempts from my laptop being dropped.

Both chains hang off the same `forward` hook at the same priority. In nftables that means both run, and a drop anywhere is final. netavark never tries to be first, never inserts anything into ufw's chains, and never short-circuits them. It manages its own traffic and leaves the host's policy alone.

Docker's `-A FORWARD -j DOCKER` with an ACCEPT inside is the outlier here, not the norm.

## Proving the DNAT genuinely works

"It's blocked" could just mean the port forwarding never worked. It isn't that. Turn ufw off with the same rootful container still running:

```
$ sudo ufw disable
192.168.128.154:8080 → HTTP 200
$ sudo ufw enable
192.168.128.154:8080 → timed out
```

The redirect is fine. ufw is doing the blocking, which is the entire point — the firewall is back to being the thing that decides.

## One more thing: iptables never appeared

Worth noting because it changes what a Podman box looks like. On the Docker test, `iptables` arrived as a dependency of `ufw` and Docker used it. Here, after installing Podman and running containers both rootless and rootful:

```bash
$ command -v iptables
$                        # nothing
```

netavark talks to nftables directly. There is no legacy-vs-nft backend question to get wrong, because there is no iptables layer at all.

## What I'd take from this

**The comment was right and worth acting on, and the reason it gave was wrong.** If I'd repeated it without checking, I'd have published "rootless protects you because it can't write rules" — true as far as it goes, and it would have left people thinking rootful Podman is as dangerous as Docker. It isn't.

That distinction is practical. Plenty of people run rootful Podman because they need low ports, or systemd integration, or just inherited it that way. They get the firewall behaviour too.

The narrower lesson is about **what "publishes a port" means**. Docker, rootless Podman and rootful Podman all print `0.0.0.0:8080->80/tcp`. Three different security outcomes behind one identical string. The output tells you the intent, not the result — same as `ufw status` telling you its rules rather than your exposure.

Which loops back to the habit from the Docker post, now with a second data point behind it: **curl the port from another machine.** It is the only check that has been right about every one of these configurations.
