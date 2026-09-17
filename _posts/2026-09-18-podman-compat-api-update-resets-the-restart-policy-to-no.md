---
title: "Send Podman's Docker-compatible API an update that only changes memory, and the container's restart policy is now 'no'. HTTP 200, no warning, and the container stays down after the next crash or reboot."
date: 2026-09-18
excerpt: "Podman 5.4.2 (Debian 13), compat API v1.41: POST /containers/{id}/update with any body that omits RestartPolicy — a memory limit, a CpuShares value, an empty {} — returns 200 {\"Warnings\":null} and quietly sets the restart policy to no. Resource limits merge; the policy does not. A container that had restarted itself three times in sixteen seconds never restarted again, and after a reboot the one that had been 'always' did not come back. Docker 26.1.5 given the identical requests keeps the policy. The native podman update CLI and the libpod API keep it too. Three lines in the compat handler, unchanged on main."
devto_title: "Podman's Docker-compatible API resets a container's restart policy to 'no' on any update that omits it"
devto_tags: podman, docker, linux, devops
---

**TL;DR**: On Podman 5.4.2 the Docker-compatible `POST /containers/{id}/update` endpoint always writes a restart policy, whether or not the request contained one. A body of `{"Memory":67108864}` applies the memory limit and changes `unless-stopped` to `no`; so does `{"CpuShares":512}`; so does `{}`. The response is `200 {"Warnings":null}` every time. The consequence is exactly what the policy name says: a container that had been restarting itself after crashes stopped doing so, and a container with `always` did not come back after a reboot. Docker 26.1.5 given the same three requests keeps the policy — its handler only touches the policy when the body names one. Podman's own `podman update` CLI and its native libpod endpoint are fine; the reset lives in the compat handler alone, which passes a pointer to an empty string down to libpod, and libpod accepts the empty string as a valid policy. The reporter's fix — always send `RestartPolicy` in the body — works and is the only fix until [containers/podman#29790](https://github.com/containers/podman/issues/29790) is addressed. The toolkit's `check-podman-compat-update-restart.sh` probes the box you are on and lists the running containers that will not come back.

## The symptom

A fresh Debian 13 container on Proxmox, `apt install podman` (5.4.2+ds1-2+b2, rootful, cgroup v2, crun), the API socket enabled with `systemctl enable --now podman.socket`. The four requests from the upstream report, sent with curl to the Docker-compatible path:

```
## 1 create (RestartPolicy unless-stopped)
201 {"Id":"7e20d62370660c7ed26b6c50e92665cfdf47c1da75eafd36c9ecc44cc2ef8937","Warnings":[]}
## 2 start
204
## 3 inspect
RestartPolicy=unless-stopped Memory=0
## 4 update, memory only:  POST /v1.41/containers/t/update  {"Memory":67108864}
200 {"Warnings":null}
## 5 inspect
RestartPolicy=no Memory=67108864
```

The memory limit is applied. The restart policy is gone. Nothing in the response says so, and the compat `GET /containers/t/json` agrees with `podman inspect`: `{"RestartPolicy":{"Name":"no","MaximumRetryCount":0},"Memory":67108864}`.

It is not specific to memory. Three more containers, each created with `--restart unless-stopped --memory 128m`:

```
## C. compat update {"CpuShares":512}
before  RestartPolicy=unless-stopped Memory=134217728 CpuShares=0
after   RestartPolicy=no             Memory=134217728 CpuShares=512
## E. compat update {}
before  RestartPolicy=unless-stopped Memory=134217728 CpuShares=0
after   RestartPolicy=no             Memory=134217728 CpuShares=0
## D. compat update {"Memory":67108864,"RestartPolicy":{"Name":"unless-stopped"}}
before  RestartPolicy=unless-stopped Memory=134217728
after   RestartPolicy=unless-stopped Memory=67108864
```

C is the telling one: the memory limit set at creation survives a CpuShares-only update — resources are merged into the existing set, as you would expect — and the restart policy does not. E says it more bluntly: an update with nothing in it resets the policy. D is the workaround from the report, and it holds.

Then whether it matters. Two containers whose command exits on its own after four seconds (`sh -c 'sleep 4; exit 1'`), both created with `unless-stopped`; `g` gets a memory-only compat update, `f` is left alone:

```
f RestartPolicy=unless-stopped State=running RestartCount=0
g RestartPolicy=no             State=running RestartCount=0
-- after 8 s
f RestartPolicy=unless-stopped State=running RestartCount=2
g RestartPolicy=no             State=exited  RestartCount=0
-- after 16 s
f RestartPolicy=unless-stopped State=running RestartCount=3
g RestartPolicy=no             State=exited  RestartCount=0
```

And across a reboot, with `podman-restart.service` enabled: `p` created with `--restart always`, `q` created the same way and then given a CpuShares-only compat update.

```
p always
q no
(pct reboot)
up 0 minutes
p Up 20 seconds
q Exited (137) 25 seconds ago
```

## Why this is easy to miss

Nobody types this request by hand. It comes out of a Docker client library — dockerode, docker-py, the Docker SDK for Go — called by something that manages containers: a dashboard that lets you drag a memory slider, an autoscaler, a plugin that keeps a fleet of service containers within limits. Those libraries build the body from the fields you passed. If you passed a memory limit, the body has a memory limit in it and nothing else, which on Docker is the correct and documented way to change one thing. The upstream report came from exactly that shape of software: a container-management plugin that updated limits and found, later, that none of its containers had a restart policy any more.

Nothing on the Podman side flags it. The call returns 200. `Warnings` is null. The memory change is visible immediately and is what the caller checks. The policy change is visible only if you inspect a field you had no reason to touch, and its effect — the container not coming back — arrives at the next crash or the next reboot, hours or weeks later, with no line in any log connecting it to an API call that happened in between. When the container is found dead, `podman inspect` shows `RestartPolicy.Name: no`, which looks like it was always that way.

One more thing that hides the affected containers once you go looking: the stored value is not the string `no`. It is the empty string, which Podman's `define.RestartPolicyNone` is. `podman inspect` renders it as `no`, but the `ps` filter does not accept that spelling:

```
$ podman ps -a --filter restart-policy=no
(nothing)
$ podman ps -a --filter restart-policy=none
t c e g h
```

## What is really going on

`pkg/api/handlers/compat/containers.go`, `UpdateContainer`, at v5.4.2 and — for these lines — identical on `main` today. After decoding the body into a Docker-shaped `container.UpdateConfig` and merging the resource fields one by one (`if options.CPUShares != 0 { … }`, and so on for every limit), it gets to the policy:

```go
localPolicy := string(options.RestartPolicy.Name)
restartPolicy := &localPolicy

var restartRetries *uint
if options.RestartPolicy.MaximumRetryCount != 0 {
    localRetries := uint(options.RestartPolicy.MaximumRetryCount)
    restartRetries = &localRetries
}

if err := ctr.Update(resources, restartPolicy, restartRetries, &define.UpdateHealthCheckConfig{}); err != nil {
```

Every resource field is guarded by "did the caller set it". The policy is not: `restartPolicy` is a pointer to whatever `Name` was, and when the body had no `RestartPolicy`, `Name` is `""`. libpod's `Update` treats a non-nil pointer as an instruction:

```go
if restartPolicy != nil {
    if err := define.ValidateRestartPolicy(*restartPolicy); err != nil {
        return err
    }
    …
    c.config.RestartPolicy = *restartPolicy
```

and `ValidateRestartPolicy("")` succeeds, because `""` is `RestartPolicyNone`, one of the five accepted values. So the empty string is stored as the policy, and from then on the container has none.

The CLI does not have this problem because `cmd/podman/containers/update.go` only fills in the pointer when the flag was given:

```go
if cmd.Flags().Changed("restart") {
    policy, retries, err := util.ParseRestartPolicy(updateOpts.Restart)
    …
    opts.RestartPolicy = &policy
```

Confirmed on the box: `podman update --memory 64m a` changed the memory limit and left `unless-stopped` alone. The native libpod endpoint (`/v5.4.2/libpod/containers/{id}/update`, which takes an OCI-shaped body — `{"memory":{"limit":67108864}}`; send it the Docker shape and you get a 500 decode error, not a silent reset) also left the policy alone.

Docker, given the identical compat requests from a second throwaway container running `docker.io` 26.1.5 from the same Debian release: `{}`, `{"CpuShares":512}`, `{"Memory":67108864,"MemorySwap":134217728}` — all 200, policy `unless-stopped` after every one. (Docker rejected a bare `{"Memory":67108864}` with a 409 about the memoryswap limit, which is its own quirk and beside the point; the policy was untouched by that too.) That is the comparison the report drew, and it holds: the same request means "change these limits" to one daemon and "change these limits and delete the restart policy" to the other.

## The fix

Upstream: the handler needs the same guard the resource fields have — set `restartPolicy` only when `options.RestartPolicy.Name != ""`. That is the reporter's suggestion and there is no PR yet; #29790 is where it will happen.

Until then, on the client side, **every compat update request must carry the restart policy you want to keep**, even when you are not changing it:

```json
{"Memory":67108864,"RestartPolicy":{"Name":"unless-stopped"}}
```

which means reading it back first (`GET /containers/{id}/json`, `.HostConfig.RestartPolicy`) unless your code already knows it. If you control the client and can call Podman natively, `podman update` and the libpod endpoint do not have the bug.

For containers that have already lost their policy, `podman update --restart=always <name>` (or `unless-stopped`) puts it back; the CLI path is safe. Finding them is the harder part, since a container that never had a policy and one that lost it look identical. The toolkit's `check-podman-compat-update-restart.sh` does two things: lists the running containers whose policy is currently none — the set that will not come back — and probes the Podman you are on, because there is no fixed version to compare against yet:

```
podman             5.4.2  (rootful)
running, policy=no 1 container(s): q
                   (will not restart after a crash or a reboot; if any were meant to,
                    re-apply with: podman update --restart=always <name>)
api socket         /run/podman/podman.sock
probe              create --restart always -> always; POST /v1.41/containers/{id}/update {} -> HTTP 200 {"Warnings":null}; policy now: no

AFFECTED: a Docker-compat update without RestartPolicy resets the policy to 'no' (containers/podman#29790).
```

The probe creates a throwaway container with `--restart always`, sends `{}` to the compat endpoint, inspects, and removes it. If no API socket is active it starts `podman system service` on a private socket for thirty seconds and stops it afterwards; nothing is pulled and nothing else on the host is touched. `--no-probe` does only the listing. The probe was run against 5.4.2 with the socket active, with the socket stopped, and on a machine with no Podman at all (exit 2); it has not been run against a fixed Podman because none exists.

## The generalisable habit

**"Compatible" is a claim about the request format, not about what the daemon does with the fields you left out.** Every Docker-shaped client that talks to Podman is relying on the compat layer to have made the same decision Docker made for each absent field, and this is one field where it made a different one. There is no way to see that from the request or the response; the two daemons return the same `200 {"Warnings":null}` and diverge in a field nobody asked about. [The same runtime, on the same box, publishes a port with a different firewall outcome from Docker while printing the identical `0.0.0.0:8080->80/tcp`](https://homelabpostmortem.com/2026/08/25/podman-respects-your-firewall/) — there the difference was in Podman's favour; here it is not. Either way it was found by sending the same input to both and reading everything back, not the field that was changed.

**When you test a partial update, inspect the whole object, not the field you changed.** The report's reproduction is four commands, and the one that finds the bug is an inspect of a field the update had no business touching. Merging semantics — "fields you omit are left alone" — are the kind of thing every API is assumed to have and few document, and the only way to know is to omit a field that matters and see whether it survives.
