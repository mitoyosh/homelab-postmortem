---
title: "COPY --chown with a user that doesn't exist builds fine and gives the files to root, although the Dockerfile reference says the build fails"
date: 2026-10-20
excerpt: "On Docker 29.9.1 with buildx v0.38.0, COPY --chown=nosuchuser built with exit 0 and no warning, and the file was owned by 0:0. So was --chown=2147483648. --chown=1000:nosuchgroup gave 1000:1000. The Dockerfile reference says that when a name isn't in the image's passwd or group file, the build fails. Only COPY --link, and a base image with no passwd file, actually failed."
devto_title: "COPY --chown with a missing user builds fine and leaves the files owned by root"
devto_tags: docker, security, devops, linux
---

**TL;DR**: The Dockerfile reference says a `COPY --chown` name that isn't in the image's `/etc/passwd` or `/etc/group` makes the build fail. With Docker 29.9.1 and buildx v0.38.0 (BuildKit v0.34.0 inside), it didn't. `COPY --chown=nosuchuser file.txt /a` built with exit 0, printed no warning, and `/a` was owned by `0:0`. A numeric ID of 2^31 or more (`--chown=2147483648`) also became `0:0`. A missing group with a numeric user (`--chown=1000:nosuchgroup`) became `1000:1000`. The only cases that failed were `COPY --link --chown=nosuchuser`, with a clear error, and a `FROM scratch` stage with no passwd file at all. So a typo, or a user created in a different build stage, quietly gives files to root, and you find out when the non-root process that was supposed to own them gets `Permission denied`. Upstream: [moby/buildkit#7292](https://github.com/moby/buildkit/issues/7292).

## The symptom

A disposable Debian 13 VM, Docker CE 29.9.1 with buildx v0.38.0 from download.docker.com, the default `docker` builder. One Dockerfile with four `--chown` forms:

```
FROM alpine:3.24
COPY --chown=nosuchuser file.txt /a
COPY --chown=2147483648 file.txt /b
COPY --chown=1000:nosuchgroup file.txt /c
COPY --chown=nobody file.txt /d
```

```
$ docker buildx build --no-cache --progress=plain --load -t chtest .
...
build rc=0
$ docker run --rm chtest stat -c '%n %u:%g' /a /b /c /d
/a 0:0
/b 0:0
/c 1000:1000
/d 65534:65534
```

No warning in the build output. `/d` is the control: `nobody` exists in alpine, and the file got `65534:65534`. Every other line asked for an owner that doesn't exist and got something else without a word. With both names missing (`--chown=nosuchuser:nosuchuser`), a `RUN stat` later in the same build printed `/a 0:0`. With a known user and a missing group (`--chown=nobody:nosuchgroup`), the result was `65534:65534`, the user's own group.

The two cases that did fail:

```
COPY --link --chown=nosuchuser file.txt /a
ERROR: failed to build: failed to solve: --chown=nosuchuser: user and group names can't be resolved
when used with --link, use numeric uid[:gid] instead

FROM scratch
COPY --chown=nosuchuser file.txt /a
ERROR: failed to build: failed to solve: failed to load cache key: invalid user index -1
```

The [Dockerfile reference](https://docs.docker.com/reference/dockerfile/#copy---chown), read on 20 October, says that if the passwd and group files "don't contain the specified names, the build fails". Here that held only for a base with no passwd file at all.

## Why it's easy to miss

The build succeeds and the image runs. Ownership only matters when a process other than root touches the file, and in a typical image that happens at run time: an app running as `USER app` can't write to a directory that was supposed to be its own, or a config file meant to be private belongs to root instead. The error points at the running container, not at a `COPY` line in the Dockerfile.

The ways to get a missing name are ordinary. A typo. A user created in a build stage, and the `COPY --chown` in the next stage, which starts from a different base without that user. A base image changed from Debian to alpine, where the same user doesn't exist. A distroless base, where few names exist at all.

## What's really going on

When BuildKit applies a `--chown` name, it reads the destination stage's `/etc/passwd` and looks the name up (`readUser` in `solver/llbsolver/ops/user_linux.go`, the same code in BuildKit v0.34.0, which Docker 29.9.1 vendors). The result starts as uid 0, gid 0, and is only filled in if the lookup finds something:

```go
if len(users) > 0 {
    us.UID = users[0].Uid
    us.GID = users[0].Gid
}
```

There's no `else`. A name that isn't found leaves `0:0` and returns no error. Groups work the same way, which is why `1000:nosuchgroup` kept the gid that the numeric user had set, and `nobody:nosuchgroup` kept nobody's group.

The numeric case is a parsing limit. In BuildKit's LLB client, `parseUID` parses a `--chown` value with `strconv.ParseInt(str, 10, 32)`, a 32-bit signed parse, so `2147483648` and above don't parse as numbers, are treated as names, aren't found, and end up as root.

`--link` refuses names outright, and its error says why: they "can't be resolved when used with --link". The `scratch` failure comes from a different place in the build, not from this lookup. A fix for the silent fallback was proposed in [buildkit#7295](https://github.com/moby/buildkit/pull/7295), but it was closed without being merged on 20 October, and no other fix is open.

## The fix

**Make sure the user exists in the stage that does the `COPY`.** In a multi-stage build, create it again in the final stage, or start the final stage from a base that has it:

```
FROM alpine:3.24
RUN addgroup -S svc && adduser -S -G svc svc
COPY --chown=svc:svc file.txt /a
```

**Or use numeric IDs below 2^31**, which never need a lookup: `--chown=1000:1000`. `/c` above shows that a numeric user with a named group can still go wrong, so make both numeric.

**Check the result, not the Dockerfile.** After a build, `docker run --rm <image> stat -c '%n %u:%g' <paths>` on the paths you chowned takes a second and catches all of the above.

The toolkit's `check-dockerfile-chown.sh` reads a Dockerfile, finds every `COPY`/`ADD --chown` without `--link`, and resolves each user and group against the stage's base image (read with `docker create` and `docker cp`, nothing is run) plus any users created with `useradd`/`adduser`/`groupadd`/`addgroup` earlier in the stage or its parents. On a test Dockerfile (excerpt):

```
  ok       app
  SILENT   nosuchuser: user 'nosuchuser' is not in alpine:3.24's /etc/passwd. The build succeeds and the files get root (0:0).
  SILENT   2147483648: numeric user 2147483648 is 2^31 or more and is treated as a name. The build succeeds and the files get root (0:0).
  SILENT   1000:nosuchgroup: group 'nosuchgroup' is not in alpine:3.24's /etc/group. The build succeeds and the files get a group other than the one named.
  ok       nobody
  ok       nosuchuser: used with --link, which fails the build if a name does not resolve
```

It exits 1 when any `--chown` would fall back. Building that Dockerfile confirmed each line: the paths it flagged came out as `0:0`, `0:0`, `1000:1000` and, for `nobody:nosuchgroup`, `65534:65534`, and the `app` user created with `adduser` earlier in the build owned its file as expected.

## The generalisable habit

When the documentation promises a failure, test the failure. "The build fails if the user doesn't exist" is the kind of sentence that's easy to believe and never check, because you only discover it's wrong by making the mistake it's supposed to catch. One deliberately wrong `--chown` would have shown it.

The code pattern is worth recognising too: a value that starts as a safe-looking default (zero) and is only overwritten when a lookup succeeds. Zero is not safe for a uid; it's root. A lookup that can fail should either fail loudly or have a default chosen for that purpose.

Ownership going quietly wrong between build and run came up before with Podman, where [`podman export` of a keep-id container shifted every file owner](https://homelabpostmortem.com/2026/09/30/podman-export-of-a-keep-id-container-shifts-every-owner/).
