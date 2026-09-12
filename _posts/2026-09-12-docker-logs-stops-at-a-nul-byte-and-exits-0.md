---
title: "docker logs stops at the first NUL byte in the file, returns exit 0, and --since after a crash tells you nothing happened."
date: 2026-09-12
excerpt: "One record of a json-file log overwritten with NUL bytes — what an abrupt power loss leaves behind — and the full read returns 17 of 50 lines with exit 0 and an empty stderr. --tail works only if its window starts after the corruption. --since with any earlier timestamp returns zero lines. The daemon logs one warning the client never sees. The reader's own comment says it returns EOF 'so we can move to the next file'; when there is no next file, it just stops."
devto_title: "docker logs stops at a NUL byte, exits 0, and --since says nothing happened"
devto_tags: docker, devops, linux, sysadmin
---

**TL;DR**: with the default `json-file` log driver, a run of NUL bytes anywhere in the log file makes `docker logs <container>` stop at that point and report success. On Docker 29.8.0 with one of 50 records zeroed, the full read returned 17 lines, exit 0, stderr empty. `--tail N` works only when its window begins after the corruption. `--since <time>` reads forward from the start, hits the NUL, and returns **zero lines** for any timestamp before the end of the file — which after a crash reads as "nothing happened since then." The daemon logs exactly one warning that never reaches the client. The reader code returns EOF on a decode error with a comment saying this is so it can move to the next file; when the corruption is in the last or only file, there is no next file, and the read just ends.

## The symptom

Docker Engine 29.8.0, Debian 13, a throwaway LXC container, `json-file` driver with no options — the default. A busybox container printing numbered lines every 100 ms, stopped after 50:

```
$ docker logs logtest | wc -l
50
$ docker logs logtest | tail -1
line 49
```

Then one record in the middle of the log file — number 17 of 51 — overwritten with NUL bytes of the same length, so the file size does not change:

```
record index 17 of 51: b'{"log":"line 17\n","stream":"stdout","time":"2026-09-12T00:1'
size before: 3889 bytes   size after: 3889 bytes
NUL bytes in file: 77
```

Now the same read, with stdout, stderr and the exit code captured separately rather than through a pipe:

```
$ docker logs logtest > out 2> err; echo $?
0
$ wc -l < out; wc -c < err
17
0
$ tail -1 out
line 16
```

Seventeen lines, exit zero, nothing on stderr. The other thirty-three records are intact on disk, and the client has no idea they exist.

`--tail` looks like it works, and that is the trap:

```
docker logs --tail 5    logtest    exit 0   5 lines    line 45 … line 49
docker logs --tail 30   logtest    exit 0   30 lines   line 20 … line 49
docker logs --tail 40   logtest    exit 0   7 lines    line 10 … line 16
docker logs --tail 100  logtest    exit 0   17 lines   line 0  … line 16
```

A window that starts after record 17 is fine. A window that includes it stops at it. You do not know where the corruption is, so you do not know which of those you are getting.

## Why this is easy to misdiagnose

Two things make this worse than a truncated file.

**The tail-vs-full disagreement points at the wrong thing.** `--tail 50` shows fresh lines. The plain read ends in the past. The natural conclusion is that something is wrong with the *reader* — a client version mismatch, a buffering problem, a terminal issue — because the file is evidently still being written. It is not a reader problem. The file has a hole in it, and only one of the two commands walks through the hole.

**`--since` gives an answer that is wrong in the most plausible direction.** This is the one the upstream report did not mention. Take the timestamp of record 20, three records past the corruption, and ask for everything since:

```
$ docker logs --since 2026-09-12T00:11:23.772318762Z logtest > out; echo $?
0
$ wc -l < out
0
```

Zero lines, exit zero. There are thirty records after that timestamp on disk. `--since` still reads forward from the beginning of the file, hits the NUL region at record 17, and stops before it reaches anything new enough to match. The control, with the corrupt record removed and the same timestamp:

```
$ docker logs --since 2026-09-12T00:11:23.772318762Z logtest | wc -l
30
```

So the exact command you would run after a power loss — "what was this container doing in the minutes before it died?" — returns the same output as "it was doing nothing." Not an error. Not a truncated list. Empty.

The daemon knows. `journalctl -u docker` on the host has one line:

```
level=warning msg="Error decoding log file" error="invalid character '\x00' looking for beginning of value"
```

Nothing carries that to the client, and a warning-level line in the daemon journal is not where anyone looks when `docker logs` returns cleanly.

## What is really going on

`daemon/logger/loggerutils/logfile.go`, in the function that tails the log files, as of master on 2026-09-11:

```go
ok := fwd.Do(ctx, watcher, func() (*logger.Message, error) {
    msg, err := dec.Decode()
    if err != nil && !errors.Is(err, io.EOF) {
        // We have an error decoding the stream, but we don't want to error out
        // the whole log reader.
        // ...
        // Instead just log the error here and return an EOF so we can move to
        // the next file.
        log.G(ctx).WithError(err).Warn("Error decoding log file")
        return nil, io.EOF
    }
    return msg, err
})
```

The comment describes the design: a decode error is converted into EOF so that the reader can give up on this file and continue with the next one in the rotation. That is reasonable when there *is* a next file. When the corruption is in the last file — or the only file, which is every container that has not rotated — "move to the next file" means "finish." The warning is logged, the EOF is returned, the read completes, and completion is success.

`--tail` escapes this because it seeks backward from the end of the file and only decodes forward from there. If the seek lands after the NUL region, the decoder never sees it. `--since` does not seek; it filters, and the filter never gets input past the hole.

**Where the NUL bytes come from is not something I reproduced.** I wrote them into the file with Python. What I can say is what the upstream tracker says: the issue this came from, [`moby/moby#53631`](https://github.com/moby/moby/issues/53631), got its zeroed region from a Docker Desktop VM stopping uncleanly. The eight-year-old sibling issue about half-written records, [`moby/moby#29511`](https://github.com/moby/moby/issues/29511), has a maintainer comment from 2024 that is the part relevant here:

> There are other reports of the exact behavior with the 'local' log driver on rpi's after abrupt power loss … The fact that it is writing null bytes when this occurs … makes it extra suspicious

A filesystem that has extended the file but not yet written the data — ext4 with delayed allocation, power gone before the flush — leaves exactly this: the right length, zeros where the bytes should be. On a Raspberry Pi on a wall adapter with no UPS, that is not an exotic scenario. It is the scenario.

## The fix

Upstream has not fixed it; the decode-error path has looked like this for years and `#53631` is a day old with no comments. Two things you can do on your own machine.

**Repair a stopped container's log by dropping the records that contain NUL bytes.** Those records were never recoverable — the bytes are zeros — but everything after them is, and this is what brings it back:

```bash
LOG=$(docker inspect --format '{% raw %}{{.LogPath}}{% endraw %}' logtest)
cp -p "$LOG" "$LOG.bak-$(date +%Y%m%d-%H%M%S)"
python3 - "$LOG" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, 'rb').read().split(b'\n')
kept = [l for l in lines if b'\0' not in l]
open(p, 'wb').write(b'\n'.join(kept))
print(f"removed {len(lines) - len(kept)}, kept {len(kept)}")
PY
```

```
removed 1, kept 50
$ docker logs logtest | wc -l
49
```

Restoring the corrupt file brings the 17-line read straight back, so the repair and the fault are cleanly attributable to that one record.

**Check before you trust a read, especially after a crash.** The file is the ground truth and it is readable without going through the daemon at all:

```bash
LOG=$(docker inspect --format '{% raw %}{{.LogPath}}{% endraw %}' "$C")
echo "NUL bytes: $(tr -cd '\000' < "$LOG" | wc -c)"
echo "last on disk: $(grep -avP '\x00' "$LOG" | tail -1 | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["log"].rstrip())')"
echo "last from docker: $(docker logs "$C" 2>/dev/null | tail -1)"
```

On the corrupted container above:

```
NUL bytes: 77
last on disk: line 49
last from docker: line 16
```

(`grep -P '\x00'` rather than a shell `$'\0'` — a NUL cannot be passed as a shell argument, so the latter silently matches the empty string and excludes everything. That version was wrong the first time I wrote it.)

If the NUL count is nonzero, or the two last lines disagree on a stopped container, the full read is stopping short. The toolkit's `check-docker-log-integrity.sh` is this comparison across rotated files with the exit code read directly rather than through a pipe, and the repair printed for you.

## The generalisable habit

The narrow lesson is that `docker logs` reports whether the *read finished*, not whether it *read everything*, and those diverge exactly when you most need them not to. After a power loss, treat the log file as the record and `docker logs` as one view of it that may end early.

The wider one is about comments that describe a design and code that runs outside it. The EOF-on-decode-error path is correct for the case its author had in mind — rotated files, skip the bad one, keep going. Nobody wrote a lie. The code simply also runs in the case where there is nothing to keep going *to*, and in that case the same three lines mean "stop and say nothing." The same shape as [a cloud-init module that reports SUCCESS for the run it skipped](https://homelabpostmortem.com/2026/09/11/cloud-init-never-reads-the-instance-id-you-set/): the status word is true about the control flow and says nothing about your intent. And it sits next to [a journal that is discarded on every reboot](https://homelabpostmortem.com/2026/08/18/trixie-journald-volatile-logs/) as a second way to find, after the crash, that the logs you were counting on are not there — this time with the bytes still on disk.
