---
title: "With one model slot, a keep_alive on the loaded Ollama model cancels the swap another request is waiting for"
date: 2026-10-22
excerpt: "On Ollama 0.40.8 with OLLAMA_MAX_LOADED_MODELS=1, a request for a second model waits for the loaded one to go idle and unload. If a request for the loaded model arrives meanwhile with keep_alive set, the unload is replaced by a keep-alive timer: the second model's request answered in 9 seconds without it, and not within 150 seconds with keep_alive 30m. Unloading the loaded model by hand released it in 1.5 seconds."
devto_title: "Ollama: a keep_alive on the loaded model cancels the swap another request waits for"
devto_tags: ollama, llm, selfhosted, ai
---

**TL;DR**: With `OLLAMA_MAX_LOADED_MODELS=1`, a request for a model that isn't loaded makes Ollama schedule the loaded model to unload as soon as it's idle, and the request waits. If a request for the loaded model arrives during that wait and carries `keep_alive`, that value replaces the pending unload: when the loaded model goes idle, Ollama sets a keep-alive timer instead of unloading, and the request for the other model waits for the whole keep_alive. On Ollama 0.40.8 on CPU, the second model answered in 9 seconds when the interfering request had no `keep_alive`, and didn't answer within 150 seconds when it had `"keep_alive": "30m"`. Nothing errors, and `/api/ps` shows a healthy loaded model. Sending `keep_alive: 0` for the loaded model released the waiting request in 1.5 seconds. Upstream: [ollama/ollama#19182](https://github.com/ollama/ollama/issues/19182), with a fix proposed in [#19190](https://github.com/ollama/ollama/pull/19190).

## The symptom

A disposable LXC container, Ollama 0.40.8 from the GitHub release, CPU only, two small models, and the reporter's settings:

```
OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_NUM_PARALLEL=4 OLLAMA_KEEP_ALIVE=30m OLLAMA_DEBUG=1
```

`qwen3:0.6b` is loaded. The same three requests as in the report:

1. a long generation on the loaded model (`num_predict` 400),
2. three seconds later, a short request for `gemma3:270m`, which needs the slot,
3. two seconds later, a one-token request for the loaded model.

Run once with step 3 as a plain request, and once with `"keep_alive": "30m"` added to it:

```
=== control: step 3 without keep_alive
  step3 (resident, no keep_alive) done at +5.129s
  step1 (resident long gen) done at +7.646s
  step2 (other model) http=200 at +9.156s
  ps after: [('gemma3:270m', ...)]
=== step 3 with keep_alive 30m
  step3 (resident, "keep_alive":"30m",) done at +5.113s
  step1 (resident long gen) done at +7.610s
  step2 (other model) http=000 at +153.0s
  ps after: [('qwen3:0.6b', ...)]
```

`http=000` is curl giving up at its 150-second limit. The scheduler's debug log for the second run:

```
sched.go:309 msg="max runners achieved, unloading one to make room"
sched.go:382 msg="resetting model to expire immediately to make room"
sched.go:393 msg="waiting for pending requests to complete and unload to occur"
sched.go:1424 msg="evaluating already loaded"
sched.go:437 msg="runner with non-zero duration has gone idle, adding timer"
```

The healthy run instead ended with `runner with zero duration has gone idle, expiring to unload` and `unload completed`.

## Why it's easy to miss

The server is fine from every angle you'd check. `/api/ps` shows the loaded model, requests for it are answered, and the scheduler messages that show what happened are debug-level (they were visible here with `OLLAMA_DEBUG=1`). Only requests for other models hang, and they hang without an error: the client just waits, until its own timeout or the keep_alive runs out.

The trigger is ordinary client behaviour. Many clients and UIs send `keep_alive` on every request; the reporter lost two hours to a client sending `"2h"` and thirteen minutes to a health probe. One slot is also the normal setting on a machine whose memory holds one model at a time, which is most homelab GPUs.

And it depends on timing: the keep_alive request has to land while the swap is waiting. Under light use it may never happen; under a steady stream of requests for the loaded model it happens again and again, and the other model effectively never gets loaded.

## What's really going on

With one slot full, Ollama picks the loaded runner to evict, sets its remaining time to zero so it unloads as soon as its last request finishes, and the waiting request sits until that happens. A request for the same model that arrives in between is served by the runner that's already loaded, and, according to the report's reading of `server/sched.go`, its `keep_alive` overwrites the runner's session duration. When the runner then goes idle it's no longer marked to expire, so it gets an ordinary keep-alive timer and stays. The waiting request stays queued for it.

The debug log above shows exactly that sequence: the eviction is set up, the loaded model is evaluated for the new request, and the runner goes idle with a "non-zero duration" and a timer instead of unloading. Without `keep_alive` on that request, the duration stays at zero and the unload goes through.

## The fix

The proposed fix, [#19190](https://github.com/ollama/ollama/pull/19190), stops a request's `keep_alive` from cancelling a pending eviction. It's open and not in a release, and none of the commit messages between v0.40.8 and v0.40.9-rc1 mention it.

Until then:

**Release a stuck swap by unloading the loaded model:**

```
curl http://127.0.0.1:11434/api/generate -d '{"model":"qwen3:0.6b","keep_alive":0}'
```

Here that let the waiting request finish 1.5 seconds later, with `gemma3:270m` loaded afterwards.

**Avoid the trigger:** stop clients from sending `keep_alive` on every request (set it once on the server with `OLLAMA_KEEP_ALIVE` instead), or give the server more than one slot if memory allows, so a second model doesn't need an eviction at all (the three-request sequence wasn't rerun with two slots here).

The toolkit's `check-ollama-eviction-stall.sh` reads the server's `OLLAMA_MAX_LOADED_MODELS` and loaded models, and if the server logs at debug level, counts evictions that were turned into keep-alive timers. On the test server:

```
  Ollama 0.40.8 at http://127.0.0.1:11434, OLLAMA_MAX_LOADED_MODELS=1, loaded: qwen3:0.6b
  AT RISK  one model slot: a request for another model can wait for the whole keep_alive of the loaded one
  STALLED  2 unload(s) since -1day were replaced by a keep-alive timer
```

`--release <model>` sends the unload. With two slots and no stall it reports "Not at risk here" and exits 0.

## The generalisable habit

When a per-request option and a scheduler decision touch the same field, ask which one wins. Here a client's preference ("keep this model around") silently overrode the server's own plan ("unload it now, someone is waiting"), and the request that paid for it was a different client's. Options that look harmless on their own, like keep_alive, can carry the most surprising side effects precisely because nobody thinks of them as instructions to the scheduler.

And when something hangs with no error, measure the alternatives side by side: the same three requests with and without one field made the difference between 9 seconds and never.

Another Ollama setting that doesn't reach the place you'd expect: [`OLLAMA_GPU_OVERHEAD` is logged but never reaches the runner](https://homelabpostmortem.com/2026/09/28/ollama-gpu-overhead-is-logged-but-never-reaches-llama-server/).
