---
title: "llama-server can leave a keep-alive connection unread until another one closes, when clients hold more connections than its HTTP threads"
date: 2026-10-18
excerpt: "With --threads-http 4 and 32 keep-alive clients, 3 of 9 runs on a fresh llama-server (b11717) had one connection whose first request waited about 42 seconds, while the median was under 2 seconds. Its request bytes sat in the socket's receive queue until the other clients closed their connections; no error, no log line, and the answer was correct when it came. --threads-http 64 never did it. The cause was in cpp-httplib's thread pool; llama.cpp b11737 and later have the fix, and b11750 ran the same test 12 times without a stall."
devto_title: "llama-server can leave a keep-alive connection unread until another closes"
devto_tags: llm, selfhosted, linux, performance
---

**TL;DR**: When clients keep more keep-alive connections open to `llama-server` than it has base HTTP threads, a newly accepted connection can sit with its request unread until some other connection closes. With `--threads-http 4` and 32 keep-alive clients on llama.cpp b11717, 3 of 9 runs on a freshly started server had exactly one such connection: its first response took about 42 seconds while the median was 1.6 to 1.7 seconds, and `ss` showed its 209 request bytes sitting in the socket's Recv-Q for the whole wait. No error, no log line, and the response was correct when it arrived. With `--threads-http 64` it never happened in 8 runs. The cause was in cpp-httplib's thread pool, which llama-server uses for HTTP. Its maintainer fixed it on 18 October, llama.cpp took the fixed library into build b11737 the next day, and b11750 ran the same test 12 times without a single stall. Update to b11737 or later; on an older build, set `--threads-http` to at least the number of connections your clients keep open. Upstream: [ggml-org/llama.cpp#30675](https://github.com/ggml-org/llama.cpp/issues/30675) and [yhirose/cpp-httplib#2633](https://github.com/yhirose/cpp-httplib/issues/2633).

## The symptom

A disposable LXC container with 6 cores, the b11717 release binary, `gemma-3-1b-it-Q4_K_M`:

```
llama-server -m gemma-3-1b-it-Q4_K_M.gguf --parallel 8 -c 4096 --threads-http 4 --port 18089
```

The client opens 32 HTTP/1.1 keep-alive connections back to back, then each one sends `POST /completion` (4 tokens) in a loop for 40 seconds and records how long its first response took. That is roughly what a proxy, a chat UI backend or an agent framework with a connection pool does. A typical run:

```
clients 32, 40s: requests 584, median first 1.75s, max first 2.5s, slowest later 2.4s, stuck 0
```

And one of the bad ones:

```
clients 32, 40s: requests 584, median first 1.70s, max first 42.1s, slowest later 2.5s, stuck 1 #31 42.1s
```

Connection #31, the last one opened, waited 42.1 seconds for its first answer. Every later request on it was as fast as the rest. Sampling `ss` once a second during that run showed the same socket the whole time:

```
05:19:29 209    0          127.0.0.1:18089    127.0.0.1:33046
05:19:30 209    0          127.0.0.1:18089    127.0.0.1:33046
05:19:31 209    0          127.0.0.1:18089    127.0.0.1:33046
...
```

209 bytes in the Recv-Q is the whole request, delivered by the kernel and never read by the server. That went on for about 40 seconds.

The count over all runs:

| Server | `--threads-http` | Runs with a stuck connection |
|---|---|---|
| fresh for each run | 4 | 3 of 9 (41.8 s, 42.1 s, 42.1 s) |
| reused across runs | 4 | 0 of 4 |
| fresh or reused | 64 | 0 of 8 |

The server log had nothing for any of them.

## Why it's easy to miss

It is rare, and it only hits one connection. On average everything is fine: throughput is normal, every request succeeds, and the slow one eventually gets a correct answer. Unless something records per-request latency, the only symptom is an occasional user whose message hangs for most of a minute, and that looks like a slow model or a busy GPU.

It also didn't show in 4 runs on a server that had already handled a run. All three stalls were on a freshly started server, which in a homelab is the moment right after a restart or a model swap, when a proxy reconnects its whole pool at once.

And `--threads-http` doesn't sound like it matters. Generation is bounded by `--parallel` slots, so it's natural to assume the HTTP threads only parse requests and a handful is plenty.

## What's really going on

cpp-httplib gives each accepted connection to a thread for the life of that connection: a keep-alive connection is one job, not one job per request. The pool starts with a base number of threads and can add dynamic threads when it runs out. llama-server sets the base to `--threads-http` if given, otherwise `max(--parallel + 4, CPUs - 1)`, which is 12 for `--parallel 8` on 6 cores.

The reporter's analysis in cpp-httplib#2633, which the maintainer confirmed, is that the pool only adds a dynamic thread when its idle-thread counter is zero, but that counter still includes threads that have already been woken for an earlier job and haven't picked it up yet. When connections are accepted in a burst, the pool sees "idle threads > 0" for a job that no idle thread will actually take, adds nothing, and the job waits in the queue. The queued connection is then served only when some thread finishes a whole connection: the client closes it, it hits the idle timeout, or it reaches cpp-httplib's limit of 100 requests per connection. In this test each connection made about 18 requests in its 40 seconds, so none reached the limit, and the stuck connection was served at about 42 seconds, right after the other clients finished their 40-second loops and closed their connections. So the 42 seconds is the length of the test, not a property of the bug. With clients that never close, the wait would last until one of them did.

The test here can't see inside the pool, but the observable parts match: the stall only happened when connections outnumbered base threads, it was always the last connection accepted, its request was unread rather than slow to process, and it ended when other connections closed.

## The fix

**Update llama.cpp to b11737 or later.** The library fix went into cpp-httplib on 18 October as [e97165b](https://github.com/yhirose/cpp-httplib/commit/e97165b5dc6960ad19f9cd152965442afe06469f), "Spawn a dynamic thread when queued jobs outnumber idle threads". It changes that one condition from `idle_thread_count_ == 0` to `jobs_.size() > idle_thread_count_` and adds a regression test, and it shipped in cpp-httplib 0.62.0. llama.cpp updated its vendored copy to 0.62.0 in [#30785](https://github.com/ggml-org/llama.cpp/pull/30785), merged on 19 October, which is build b11737; b11738 is the first release with binaries.

On the same container, the b11750 release binary, the same model and client, `--threads-http 4`, a fresh server for every run:

```
fresh threads-http 4 run 1: clients 32, 40s: requests 576, median first 1.66s, max first 2.4s, slowest later 2.5s, stuck 0
...
fresh threads-http 4 run 12: clients 32, 40s: requests 656, median first 1.50s, max first 2.0s, slowest later 2.2s, stuck 0
```

0 of 12 runs stuck, the slowest first response 2.4 seconds, and no request left in a Recv-Q in any sample. b11717 had stalled in 3 of 9.

On an older build, start llama-server with enough HTTP threads for every connection your clients keep open:

```
llama-server ... --threads-http 64
```

With 64 for 32 connections, no run stalled on b11717 either. Size it from the client side: the connection pool of your proxy, UI or agent framework, plus some headroom for other clients. An idle thread costs little.

The toolkit's `check-llama-http-stall.sh` reads each running llama-server's build number and command line. A build before b11737 with more established connections than base HTTP threads is flagged:

```
  TOO MANY llama-server 9677 port 18089 (build 11717): 32 client connection(s), 4 base HTTP thread(s)
```

and the same load on b11750 passes:

```
  ok       llama-server 9783 port 18089: build 11750 has the fix; 32 client connection(s), 4 base HTTP thread(s)
```

With `--watch SECONDS` it also samples the server's sockets every second and reports any connection whose request stays unread for 5 seconds or more. In the b11717 run that stalled, it printed `STALLED  127.0.0.1:18089<-127.0.0.1:54264: request unread for 38 s` and exited 1.

## The generalisable habit

Look at the maximum, not the average. A median of 1.7 seconds and a maximum of 42 came out of the same run, and only the second one is what a user remembers. Any benchmark of a server that only reports averages or throughput will miss this whole class of problem.

When a request is slow, find out where it was waiting. A non-zero Recv-Q on the server's socket means the request was delivered and nobody read it, which rules out the network and the model in one look and points at the server's own scheduling.

Another llama-server setting that doesn't mean what it seems to: [`--cache-ram -1` is not "no limit"](https://homelabpostmortem.com/2026/09/24/llama-server-cache-ram-minus-one-is-not-no-limit/).
