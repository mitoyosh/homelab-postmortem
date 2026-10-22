---
title: "Docker's graphdriver store pushes pulled zstd layers labelled gzip, and a BuildKit build on top then fails or copies the label"
date: 2026-10-22
excerpt: "On Docker 29.9.1 and 29.9.2 with the overlay2 graphdriver store, docker push of an image that was pulled with zstd layers wrote a manifest labelling them gzip; the blobs were unchanged zstd. The push succeeded and docker run worked. A BuildKit build FROM that image with compression=zstd,force-compression=true failed with 'failed to get compression blob \"zstd\": not found', and without force-compression the gzip label was copied into the new image."
devto_title: "Docker's graphdriver store re-pushes zstd layers labelled gzip"
devto_tags: docker, devops, containers, linux
---

**TL;DR**: When a Docker daemon uses the graphdriver image store (overlay2: every Docker 28, and Docker 29 installs that were upgraded from 28 or have `"containerd-snapshotter": false`), `docker push` of an image it pulled with zstd-compressed layers writes a manifest that labels those layers `application/vnd.docker.image.rootfs.diff.tar.gzip`. The blobs are reused as they are, so they're still zstd. The push succeeds, the registry accepts it, and `docker run` of the image works, because Docker detects the compression from the data. Tools that trust the label don't: a BuildKit build `FROM` the relabelled image with `compression=zstd,force-compression=true` failed with `failed to get compression blob "zstd": not found`, and without `force-compression` it succeeded and copied the gzip label into the new image. Reproduced on Docker 29.9.1 and 29.9.2; the containerd image store labels the same layers correctly. Upstream: [moby/moby#53999](https://github.com/moby/moby/issues/53999) and [moby/buildkit#7308](https://github.com/moby/buildkit/issues/7308).

## The symptom

A disposable Debian 13 VM with Docker CE 29.9.2 from download.docker.com. First the reporter's own reproducer, after reading it: Compose runs `registry:3.1.2`, two `docker:<version>-dind` daemons (one with each image store) and an Alpine container with curl, jq and zstd. It pushes a one-layer zstd image to the registry with curl, then has each daemon pull it, retag it and push it, and compares each manifest's media type with the blob's first bytes:

```
== 1. Push a one-layer zstd image built with curl and the zstd CLI (registry:5000/repro/app:zstd)
  application/vnd.oci.image.layer.v1.tar+zstd        sha256:b520d8eb3b4b…  content: zstd

== 2. Graphdriver store: pull it, then push it under new tags
  registry:5000/repro/app:graphdriver (blob already in the repo):
  application/vnd.docker.image.rootfs.diff.tar.gzip  sha256:b520d8eb3b4b…  content: zstd
  registry:5000/repro/other-graphdriver:latest (blob mounted from repro/app):
  application/vnd.docker.image.rootfs.diff.tar.gzip  sha256:b520d8eb3b4b…  content: zstd

== 3. containerd store: the same, for comparison
  registry:5000/repro/app:containerd (blob already in the repo):
  application/vnd.oci.image.layer.v1.tar+zstd        sha256:b520d8eb3b4b…  content: zstd
```

Same blob digest everywhere; only the graphdriver pushes call it gzip. It reproduced with `docker:29.9.1-dind` and with `docker:29.9.2-dind`.

Then the part the reproducer doesn't show: what happens downstream. On the VM's own daemon, switched to the graphdriver store, with a registry on `localhost:5000` and a BuildKit builder (`docker-container` driver):

```
1. buildkit pushed base:zstd rc=0  layers: tar+zstd tar+zstd
2. graphdriver dockerd re-pushed base:relabeled  layers: gzip gzip
3. FROM relabeled, compression=zstd,force-compression=true rc=1
   ERROR: failed to build: failed to solve: failed to get compression blob "zstd": not found
4. FROM relabeled, compression=zstd (no force) rc=0  layers: tar+gzip tar+gzip tar+zstd
6. docker run of relabeled image: base
```

The relabelled layer's first bytes are `28 b5 2f fd`, the zstd magic. Step 4 is the quieter failure: the build works and the new image inherits the two wrong labels, so whoever builds on it next gets them too. `docker run` doesn't care (step 6).

## Why it's easy to miss

Nothing in Docker's own workflow ever fails. Push succeeds, pull succeeds, run succeeds, because Docker and containerd look at the blob's magic bytes rather than the label. The wrong label only matters to something that trusts it, and that's usually another tool, later, maybe on someone else's machine. BuildKit's recompression, below, is one; any tool that decides how to decompress a layer from its media type would be another.

The store you're on isn't obvious either. Fresh Docker 29 installs use the containerd image store; according to the report, a Docker 29 that was upgraded from 28 keeps overlay2 ("using prior storage driver: overlay2" at startup), and any daemon with `containerd-snapshotter` turned off uses it too, as the test daemon here did. `docker info` shows it as the storage driver: `overlay2` is the graphdriver store, `overlayfs` the containerd one.

And there was one more trap when testing. After BuildKit had built from the relabelled image once, a build `FROM` the correctly labelled original also failed with the same error, because the builder's cache now held the layer under the gzip label. After `docker buildx prune -af`, the correctly labelled base built fine and the relabelled one still failed. So a single mislabelled image can make unrelated builds fail on the same builder until its cache is cleared.

## What's really going on

When the graphdriver store pushes a layer that the registry already has, or can mount from another repository, it doesn't upload anything, it just writes the manifest entry. According to the report, the media type for both of those paths is hard-coded to the gzip Docker type in `daemon/internal/distribution/push_v2.go`. For a layer that was originally gzip that's correct; for a zstd layer pulled from a registry it's wrong, and nothing checks.

The containerd image store keeps the layer's original descriptor, media type included, which is why it pushes the same layers correctly.

On the BuildKit side, according to buildkit#7308, `force-compression` decides whether a layer needs converting from its media type, so a zstd layer labelled gzip is treated as needing conversion to zstd, and the lookup for a zstd version of it fails, which is the `failed to get compression blob "zstd": not found` above.

## The fix

There's no fix in a release; the issue is labelled `help wanted`.

**Push from a containerd-store daemon.** Either a fresh Docker 29 install, or set `"features": {"containerd-snapshotter": true}` in `/etc/docker/daemon.json` and restart. Images stored under the old store don't appear in the new one, so pull them again after switching. With that store the same push kept `tar+zstd`.

**Or don't re-push pulled zstd images from a graphdriver daemon**; rebuild them instead.

**Clear the builder cache** after hitting the BuildKit error: `docker buildx prune -af` on the builder involved.

**Check what's already in your registry.** The toolkit's `check-image-layer-compression.sh` fetches an image's manifest (each platform of an index, or one with `--platform`) and the first bytes of every layer, and compares them with the label. Anonymous pulls, read-only:

```
  ok       localhost:5000/base:zstd e2975860bc76  label zstd  content zstd
  MISLABEL localhost:5000/base:relabeled e2975860bc76  label gzip  content zstd
  MISLABEL localhost:5000/app:noforce e2975860bc76  label gzip  content zstd
  ok       localhost:5000/app:noforce 0cc3546756f5  label zstd  content zstd
```

It exits 1 when any layer is mislabelled. Against Docker Hub's `alpine:3.24` and `nginx:alpine` it reported every layer `ok`.

## The generalisable habit

A label is a claim, not a fact. When a format records what something is in metadata next to the data, the two can drift apart, and the tools that read only the metadata are the ones that break. If you consume artifacts produced by other people's tooling, check the content when it's cheap to, the way Docker does here with magic bytes.

And test the next step, not just the one that was reported. The reproducer showed a wrong label; the cost of that label only appeared one build later, as an error in a different tool and a cache that went on failing for a correctly labelled image.

Another Docker 29 behaviour that depends on which store the daemon uses: [type=image mounts come back empty after a reboot](https://homelabpostmortem.com/2026/10/18/docker-image-mount-comes-back-empty-after-a-reboot/), differently on overlay2 and on the containerd store.
