---
title: "llama-server's sleep mode loses, or crashes on, a request that arrives in the last few dozen milliseconds before it sleeps"
date: 2026-10-03
excerpt: "With --sleep-idle-seconds, a request handler checks that the server is awake, tokenizes the prompt, then queues the task. If the idle timer fires in between, the server unloads the model and sleeps. A 17,653-token prompt sent 46 to 34 ms before that moment sat in the queue until another request woke the server. Sent 34 to 3 ms before, it crashed llama-server with SIGSEGV inside the tokenizer. Short prompts never hit it. A 1-token completion sent first avoided both in 123 of 123 tries."
devto_title: "llama-server's sleep mode loses or crashes on a request that arrives just before it sleeps"
devto_tags: llm, llamacpp, selfhosted, debugging
---

**TL;DR**: `llama-server --sleep-idle-seconds N` unloads the model after N idle seconds and is documented to reload it for "any new incoming task". A request handler checks that the server is awake when it starts, then tokenizes the prompt, then queues the task. If the idle timer fires in between, the server goes to sleep anyway. On llama.cpp b11368 (CPU, Gemma 3 1B), a 17,653-token prompt sent 46 to 34 ms before the server fell asleep sat in the queue with no reply until a second request woke the server, 32 times out of 32. Sent 34 to 3 ms before, it crashed the server with SIGSEGV inside the tokenizer, which was reading the vocabulary the sleep had just freed, 41 times out of 41. With a two-word prompt the window is too short to hit: 0 of 93. Sending a 1-token completion first and the real request right after it avoided both in 123 of 123 tries. The toolkit's `check-llama-sleep-race.sh` finds servers with sleep mode on and says whether a crash would be restarted. Upstream report (the hang): [ggml-org/llama.cpp#29689](https://github.com/ggml-org/llama.cpp/issues/29689).

## The symptom

The report that led here was intermittent: a client that sends `/health`, `/props`, `/tokenize` and then `POST /completion` right after the server starts, with `--sleep-idle-seconds 1`, got no answer to the completion about one time in eight. The server log showed it going to sleep and never waking:

```
I que    start_loop: entering sleeping state
I srv  handle_sleep: server is entering sleeping state
W srv          stop: cancel task, id_task = 0          <- the client giving up 10 s later
```

To find where the window is, a Debian 13 LXC with 6 CPU cores, the llama.cpp `b11368` release binary, `gemma-3-1b-it-Q4_K_M`, `-np 1 --sleep-idle-seconds 1`. Each trial starts a fresh server, takes the moment `/health` first returns 200 as zero, waits a chosen offset, sends one `POST /completion`, and timestamps every server log line as it arrives. The server fell asleep 0.978 to 1.000 s after zero, so every send can be placed relative to the moment it slept.

With the prompt `"Say OK"`, 93 sends between 0.97 and 1.03 s gave 93 answers. The 61 that arrived after the server was asleep woke it as documented, at about 1.4 s latency for the reload.

Then the same with a 17,653-token prompt. To keep each trial fast, the context was `-c 512`, so a prompt that gets processed is rejected at once with HTTP 400 ("exceeds the available context size"). A 400 means the request reached a slot. Anything else means it didn't. 123 sends between 0.93 and 1.01 s, grouped by when they were sent relative to the moment the server fell asleep:

```
sent relative to sleep    result
early enough (> ~50 ms)    13  answered before the timer fired (400, ~45 ms)
46 .. 34 ms before         32  no answer; /props says is_sleeping: true
34 .. 3 ms before          41  connection closed with no response; server gone
2 ms before .. 29 ms after 37  woke the server, answered (~1.3 s)
```

The hung requests were still in the queue. After 3 s the harness checked `/props` (`"is_sleeping": true`) and sent a second, short completion. That woke the server, and the first request was answered right behind it:

```
first sent      0.935 s   (server fell asleep at 0.979 s)
/props at 3 s   is_sleeping: true
second sent     3.938 s   -> "exiting sleeping state" at 3.938 s
first answered  5.172 s   (4.2 s after it was sent)
```

Without the second request the first would have waited until the client's own timeout. For a single client that sends one request after a quiet period, which is how cron jobs, home automations and agent turns tend to look, that means no reply at all.

The other 41 were not hangs. The server process had exited with signal 11, and the client got `RemoteDisconnected`. Ten more sends between 0.970 and 0.990 s crashed it all ten times. Run under `gdb`, the faulting thread was an HTTP worker in the middle of tokenizing the prompt:

```
Thread 9 "llama-server" received signal SIGSEGV, Segmentation fault.
#1  llama_vocab::text_to_token(...)
#2  llm_tokenizer_spm_session::try_add_bigram(int, int)
#3  llama_vocab::impl::tokenize(...)
#6  common_tokenize(...)
#9  tokenize_input_prompts(...)
#10 server_routes::handle_completions_impl(...)
```

## Why it's easy to miss

It happens in a few dozen milliseconds out of every idle period, so most requests never see it, and the ones that do look like unrelated faults. The hang leaves no error anywhere: the log's last word is "entering sleeping state", which is what an idle server should say, and `/props` correctly reports that the server is asleep. The crash leaves nothing in the server's own log either, because the process dies mid-request. If a supervisor restarts it, the outage can pass for a blip.

The documentation describes the opposite: "When the server enters sleep mode, the model and its associated memory (including the KV cache) are unloaded from RAM to conserve resources. Any new incoming task will automatically trigger the model to reload." That holds for a request that arrives after the server is asleep. It doesn't hold for one that arrives slightly before.

And it depends on the prompt. With a two-word prompt there was no window to hit in 93 tries. The reporter's server had a vision projector loaded (`--mmproj`) and speculative decoding on, and saw it one time in eight. What widened their window isn't stated, but an image is preprocessed in the same place a prompt is tokenized, so either would do it.

## What's really going on

Every completion handler starts by building its response object, and that constructor is the wake check (`tools/server/server-context.cpp`):

```cpp
server_res_generator(server_queue & queue_tasks, ...) {
    bypass_sleep |= sleep_idle_seconds < 0;
    if (!bypass_sleep) {
        queue_tasks.wait_until_no_sleep();
    }
}
```

`wait_until_no_sleep()` returns at once if the server is awake. Only if it is already asleep does it set `req_stop_sleeping` and wait for the wake-up. After that, `handle_completions_impl` tokenizes the prompt (or runs `process_mtmd_prompt` for an image), builds the tasks, and only then calls `rd.post_tasks(...)`.

Meanwhile the queue's main loop (`tools/server/server-queue.cpp`), finding the queue empty and the idle timer expired, does this while holding the queue lock:

```cpp
QUE_INF("%s", "entering sleeping state\n");
sleeping = true;
for (auto & cb : callback_sleeping_state) {
    cb(true);                       // unloads the model, vocabulary included
}
req_stop_sleeping = false;
condition_tasks.wait(lock, [&]{
    return (!running || req_stop_sleeping);
});
```

That gives two outcomes, depending on where the sleep lands:

- **During tokenization.** The handler is still reading the vocabulary when `cb(true)` frees it. That is the SIGSEGV in `text_to_token`.
- **After tokenization, before `post_tasks`.** The task is queued while the loop is asleep. The loop only wakes when `req_stop_sleeping` is set, and a queued task doesn't set it. The task waits for the next request that arrives while the server is asleep, since that one goes through `wait_until_no_sleep()`'s wake path.

The window is the time between the wake check and the post, which is mostly tokenization. On this CPU a 17,653-token prompt took about 45 ms end to end, and the dangerous span measured 46 ms to 3 ms before the sleep. It grows with prompt length and with image preprocessing.

The issue proposes two fixes. One is to also wake when the queue is not empty. As this code reads, that covers the hang but not the crash, which happens before anything is queued. The other is to count requests that are between the wake check and the post, and not sleep while that count is above zero. That would cover both.

## The fix

There is no release with a fix yet. These are the options that were measured or are plain configuration:

**Send a 1-token completion before the real request.** A request whose prompt is a couple of tokens has almost no window: 0 hits in 93. When it is queued it resets the idle timer, so the real request that follows gets a full idle period of headroom instead of whatever was left. The same 123-send sweep with that in front:

```bash
curl -s localhost:8080/completion -d '{"prompt":"hi","n_predict":1}' >/dev/null
curl -s localhost:8080/completion -d @real-request.json
```

```
123 sends, 0.93 .. 1.01 s:  123 answered, 0 hung, 0 crashed
```

The two requests have to go out back to back, well within the idle period. With a real setting in minutes, that is easy. `/health` and `/props` don't work as the warm-up: the README says they "do not reset the idle timer". The reporter's workaround goes the other way: wait until `/props` reports `is_sleeping: true`, then send. That relies on the wake path, which handled all 37 sends here that arrived after the sleep (and 61 of 61 with the short prompt), at the cost of a model reload on every request.

**Give the client a timeout and a retry.** It doesn't prevent anything, but a hung request becomes a slow one. The retry also wakes the server, which releases the stuck request.

**Make sure a crash is restarted.** Under systemd that means `Restart=on-failure` on the unit. The request that triggered the crash is lost either way.

**Or leave sleep mode off** (the default, `-1`) on servers that take long prompts or images from a single client.

## The generalisable habit

A "check, then act" sequence is only as good as what stops the state from changing between the two steps. Here the wake check and the queueing are separate steps with real work between them, and nothing keeps the sleep from happening in that gap. When a feature adds a background transition (sleep, eviction, reload, rotation), ask what a request that started just before the transition is still holding, and whether the transition can take it away. Then test the boundary on purpose. A sweep of send times against the moment of the transition found in an hour what the reporter saw one time in eight, and it also turned up the crash. Nobody had reported that one, because the process that could log it dies first.

The same server has other places where what a request was promised and what it gets come apart: a [documented `response_format` that is accepted and ignored](https://homelabpostmortem.com/2026/09/12/llama-server-ignores-the-response-format-its-readme-shows/) is the earlier one on this site.

The toolkit's `check-llama-sleep-race.sh` reads running `llama-server` command lines (and router preset files) for `--sleep-idle-seconds`. For a running process, it also asks systemd whether a crash would be restarted. It never sends a request to the server, because a probe of this race can crash it.
