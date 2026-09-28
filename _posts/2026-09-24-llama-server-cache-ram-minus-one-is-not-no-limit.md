---
title: "llama-server's `--cache-ram -1` is documented as \"no limit\". On a dense model it keeps less than the default; on a hybrid model it has no memory limit at all."
date: 2026-09-24
excerpt: "The prompt cache has two limits, bytes and tokens. -1 removes the byte limit, and the token limit, which a positive setting raises to fit the bytes, stays pinned at n_ctx. With 16 distinct prompts on a 4096-token context, the default kept all of them and -1 evicted twelve. On a hybrid model every cache entry carries a fixed-size recurrent state, so with -1 memory grew by about 40 MiB per short prompt, linearly, with nothing to stop it until the entries add up to n_ctx tokens. --cache-ram 256 held flat."
devto_title: "llama-server's --cache-ram -1 is not \"no limit\": less cache on dense models, no memory cap on hybrid ones"
devto_tags: llm, llamacpp, selfhosted, performance
---

**TL;DR**: `llama-server --help` and the README describe `--cache-ram` as "maximum cache size in MiB (default: 8192, -1 - no limit, 0 - disable)". The prompt cache actually has two limits, one in bytes and one in tokens. The token limit starts at `n_ctx`, and only when the byte limit is positive is it raised to "however many tokens fit in that many bytes". `-1` turns the byte limit off, so the token limit never moves off `n_ctx`. On a dense model that means `-1` keeps *less* than the default: with 16 distinct prompts on a 4096-token context, the default cached all 16 and `-1` evicted 12, and re-sending the first prompt cost a full reprocess. On a hybrid or recurrent model (Qwen3.5 and later, LFM2, Mamba, Granite 4 H) every cache entry also carries a fixed-size state no matter how short the prompt, so the entry count, and memory, grows until the cached prompts add up to `n_ctx` tokens: here about 40 MiB per 140-token prompt, 1.3 GiB to 3.7 GiB over 60 prompts, linear, no eviction. `--cache-ram 256` held flat at 1.6 GiB. Use an explicit size. The toolkit's `check-llama-cache-ram.sh` finds `-1` on running servers, in `LLAMA_ARG_CACHE_RAM`, and in router presets. Upstream report: [ggml-org/llama.cpp#29324](https://github.com/ggml-org/llama.cpp/issues/29324).

## The symptom

The report that led here came from a knowledge-graph extraction job: tens of thousands of short prompts against a 27B hybrid model on a machine with 96 GB of RAM, with `--cache-ram -1` set on the reasonable assumption that "no limit" meant the cache could use what it liked. The server's private memory climbed past the machine's RAM into the page file. The reporter measured roughly +6 GiB per ten prompts, linear, with `-1`, against a plateau with `--cache-ram 24576`, and pointed out the one clue the server gives: a warning that a *token* limit had been reached, on a setting that was supposed to have no limit.

To separate the two effects, the same thing on a CPU box with llama.cpp master (`930e2fa`), a 1B dense model first. `-c 4096 -np 1`, sixteen distinct prompts of 590–840 tokens each sent to `/completion` with `cache_prompt: true`, then the first prompt re-sent:

```
default (8192 MiB)
  evictions                 0
  resend prompt 1           prompt_n 5    cache_n 593     <- served from the cache
  RSS                       941 -> 1452 MiB

--cache-ram -1
  evictions                 12
  first: cache token limit (4096, est: 4096) reached, removing oldest entry (size = 26.119 MiB)
  resend prompt 1           prompt_n 598  cache_n 0       <- reprocessed from scratch
  RSS                       941 -> 1202 MiB
```

"No limit" kept four prompts. The default kept sixteen, and would have kept more.

Then a hybrid model, Qwen3.5-0.8B (`general.architecture = qwen35`, which llama.cpp classes as hybrid), `-c 32768`, sixty distinct prompts of about 140 tokens:

```
--cache-ram -1
  after 15 prompts   RSS 1887 MiB
  after 30           RSS 2490 MiB
  after 45           RSS 3093 MiB
  after 60           RSS 3697 MiB      evictions 0; prompt 1 still cached

--cache-ram 256
  after 15 prompts   RSS 1589 MiB
  after 30           RSS 1585 MiB
  after 45           RSS 1592 MiB
  after 60           RSS 1590 MiB      making room for prompt cache entry, removing oldest entry (size = 39.824 MiB)
```

Forty MiB per cache entry for a 140-token prompt, about 0.28 MiB per token. The dense model's entries were around 26 MiB for 600 tokens, about 0.04 MiB per token. The difference is the recurrent state each hybrid entry carries whatever the prompt length. With `-1` those entries accumulate until the prompts in them add up to 32768 tokens, which at 140 tokens each is about 230 entries, roughly 9 GiB for a 0.8B model. That endpoint is arithmetic from the measured slope and the source below; the run stopped at 60 prompts, which is where this 8 GB container would have started swapping.

## Why this is easy to miss

The documentation gives three values and their meanings, and `-1 - no limit` reads as the most permissive of the three. Nothing in the help text mentions a token limit at all, so there is no reason to suspect `-1` switches one on, or rather leaves one that the other settings quietly raise.

On a dense model the cost is invisible unless you are measuring cache hits. Requests succeed, responses are correct, and memory is if anything lower than with the default. The only difference is that prompts you expected to be cached get reprocessed, which shows up as latency, which is easy to blame on anything.

On a hybrid model the cost is memory, but slowly. Each prompt adds a fixed chunk, and the growth only becomes a problem after hundreds or thousands of distinct prompts — a batch job, an agent, a RAG pipeline — long after anyone is watching the server start. When it does, the natural suspects are the model or the context size, not a cache setting that says "no limit".

The one log line that points at the cause, `cache token limit (N, est: N) reached`, only appears on the dense side of the problem, and it reads as a normal eviction notice.

## What is really going on

Three lines in `tools/server` at `930e2fa` (the third is the same in the `b10703` release):

```cpp
// server-context.cpp:1359 — the token limit is always n_ctx
prompt_cache = std::make_unique<server_prompt_cache>(params_base.cache_ram_mib, n_ctx);

// server-task.h:614 — -1 becomes a byte limit of 0, which update() treats as "none"
this->limit_size = 1024ull*1024ull*(limit_size_mib < 0 ? 0 : limit_size_mib);

// server-task.cpp:1883 — the token limit is only raised when the byte limit is positive
const size_t limit_tokens_cur = limit_size > 0
    ? std::max<size_t>(limit_tokens, limit_size/size_per_token)
    : limit_tokens;
```

`size_per_token` is the cache's average, `max(1, bytes / tokens)`. With a positive byte limit, `limit_tokens_cur` is "as many tokens as fit in the byte budget", which for 8192 MiB is far more than any context size, so the byte limit is the one that binds. With `-1`, `limit_size` is 0, the byte check is skipped, and `limit_tokens_cur` is `n_ctx`. The cache is then bounded by tokens alone.

For a dense model, bytes are roughly proportional to tokens, so a token cap is also a memory cap, just a small one. For a hybrid model they are not: each entry's size is its KV cells plus a recurrent state whose size depends on the model, not the prompt. A token cap of `n_ctx` bounds the number of entries only by `n_ctx / prompt_length`, and short prompts make that number large.

A positive setting is a real bound in both cases. The 256 MiB run evicted through a different path (`alloc: making room for prompt cache entry`) and stayed flat. Context checkpoints (`--ctx-checkpoints`), which hybrid models use for long prompts, are allocated separately and were not exercised by these short prompts; this post does not claim `--cache-ram` bounds them.

## The fix

Give `--cache-ram` a number:

```bash
llama-server -m model.gguf --cache-ram 16384      # MiB
```

Size it from the entry sizes the server logs (`removing oldest entry (size = … MiB)`) times the number of prompts you want to keep. On a dense model the default of 8192 is usually already more than `-1` gives you. `--cache-ram 0` disables the cache, which is the right answer for batch jobs where no prompt repeats — the report that started this noted the cache had saved about four minutes of prefill over a 36-hour run.

The setting can arrive three ways, and `-1` in any of them has the same effect: the command-line flag, the `LLAMA_ARG_CACHE_RAM` environment variable, and `cache-ram = -1` in a router-mode `--models-preset` file. The toolkit's `check-llama-cache-ram.sh` looks at all three for every running `llama-server`, reads the model's architecture from its GGUF header, and says which of the two failure modes applies:

```
pid 2252: /opt/lab/src/build/bin/llama-server -m /opt/lab/gguf/Qwen3.5-0.8B-Q8_0.gguf -c 8192 --port 8092 --cache-ram -1
  --cache-ram        -1
  n_ctx              8192  <- with -1 this is the prompt cache's token limit
  architecture       qwen35
  EXPOSED: '-1' is documented as 'no limit' but removes only the byte limit. The cache then keeps
           at most n_ctx tokens in total, fewer than the default 8192 MiB would keep on a dense model.
           qwen35 is recurrent/hybrid: every cache entry carries fixed-size state, so memory grows
           with the number of cached prompts and nothing caps it in bytes (llama.cpp#29324).
           Use an explicit size instead, e.g. --cache-ram 16384.
```

`--args "<command line>"` checks a unit file or compose command without a running server. It is read-only and never talks to the server.

## The generalisable habit

**"No limit" usually means "one fewer limit".** A resource with more than one bound — bytes and tokens here, but also bytes and entries, or time and count — tends to expose one of them as a flag and derive the others from it. Switching the exposed one off does not switch the others off; it can leave them at whatever they were derived from before, which is often smaller. The same shape as [a documented request field that is accepted and ignored](https://homelabpostmortem.com/2026/09/12/llama-server-ignores-the-response-format-its-readme-shows/): the option parses, the server starts, and the only way to learn what it does is to set it and measure the thing it was meant to change. Two days later the same shape turned up in a decision model: [Laya clamps a 0.1 temperature when it loads the checkpoint, but the file still says 0.1, and an ONNX port that reads the file applies it](https://homelabpostmortem.com/2026/09/26/laya-onnx-port-skips-the-temperature-clamp/). And four days later in Ollama, which runs this same llama-server underneath: [`OLLAMA_GPU_OVERHEAD` is parsed and printed as reserved VRAM, and never reaches the `--fit` that places the layers](https://homelabpostmortem.com/2026/09/28/ollama-gpu-overhead-is-logged-but-never-reaches-llama-server/).

**Measure a cache by what it serves, not by whether it errors.** Neither run here produced an error. The dense `-1` run looked healthier than the default by memory. The finding was in `cache_n` on a re-sent prompt, and in RSS sampled every fifteen requests — two numbers nobody looks at until the latency or the page file makes them.
