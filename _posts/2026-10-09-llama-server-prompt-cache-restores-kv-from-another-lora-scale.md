---
title: "llama-server's RAM prompt cache brings a prompt back with KV computed under a different LoRA scale, and answers from it"
date: 2026-10-09
excerpt: "llama-server's RAM prompt cache, on by default, stores a slot's KV without recording which LoRA scale it was computed with, and the check for a LoRA change compares against the slot's previous request, not the entry it just restored. Send a prompt at LoRA scale 0, let another request take the slot, send the prompt again at scale 1, and it is answered from the scale-0 KV. On b11514 that gave a different answer from the uncached request on 10 of 10 prompts, with cache_n showing the whole prompt reused. --cache-ram 0 or cache_prompt:false on every request avoids it."
devto_title: "llama-server's prompt cache reuses KV computed under a different LoRA scale"
devto_tags: llamacpp, llm, selfhosted, lora
---

**TL;DR**: `llama-server`'s RAM prompt cache (`--cache-ram`, on by default) saves a slot's KV when another request takes the slot, and restores it when the same prompt comes back. The saved entry doesn't record which LoRA adapters and scales the KV was computed with. The server does check for a LoRA change, but it compares the new request with the slot's previous request, not with the entry it has just restored. So: send a prompt with an adapter at scale 0, send something else that takes the slot, send the first prompt again at scale 1, and the answer is decoded on the scale-0 KV. On b11514, the current release, that happened on 10 of 10 prompts: `cache_n` showed the whole prompt reused, `prompt_n` was 1, and the answer differed from the same request without the cache. Changing the scale globally with `POST /lora-adapters` did the same. b10703 from August behaved the same way. `--cache-ram 0`, or `cache_prompt: false` on every request, gave the right answers. The toolkit's `check-lora-cache.sh` tests a running server. Upstream: [ggml-org/llama.cpp#30129](https://github.com/ggml-org/llama.cpp/issues/30129), and [#26207](https://github.com/ggml-org/llama.cpp/issues/26207) for the global path.

## The symptom

Debian 13 LXC, CPU only, llama.cpp b11514 from the release tarball. The models are the ones llama.cpp's own server tests use for LoRA: `stories15M_MOE-F16.gguf` (a 15M-parameter story model) and its `moe_shakespeare15M.gguf` adapter, both checked against the SHA-256 on Hugging Face. The server:

```bash
llama-server -m stories15M_MOE-F16.gguf --lora moe_shakespeare15M.gguf \
  --lora-init-without-apply -np 1 -c 4096
```

Ten prompts, each about 116 tokens, at temperature 0, 48 tokens out. First, the reference answers from a separate server started with `--cache-ram 0`: each prompt at scale 1 and at scale 0. The two scales gave different answers on all ten. Then, on a fresh default server, the sequence from the report, for each prompt P:

```
1. P  with "lora": [{"id": 0, "scale": 0}]
2. Q  with "lora": [{"id": 0, "scale": 1}]     (another prompt; it takes the only slot)
3. P  with "lora": [{"id": 0, "scale": 1}]
```

Step 3 for the first prompt:

```
scale 1, no cache:   ' loved to watch the time.\nBut that I in that bears that I want to keep,\nThe neither of you'
scale 0, no cache:   ' is very far away. The farmer and his family who is very far away. The farmer and his fami'
step 3:              ' had many:\nThe old men who had used it to sell,\nThe old men and men who had gone out to se'
                     timings: cache_n=116 prompt_n=1
```

The whole prompt came from the cache and one token was evaluated. The answer is neither the scale-1 answer nor the scale-0 one: the prompt was read under scale 0 and the continuation generated under scale 1. Across the ten prompts:

```
default server                                    differs from the scale-1 answer 10/10
--cache-ram 0                                     0/10
step 3 sent with cache_prompt: false              0/10
step 1 also at scale 1 (KV and request match)     1/10
scale changed with POST /lora-adapters instead    10/10
b10703 (August), default                          10/10
```

The 1 in the matching-scale row was the same prompt each time the ten ran in sequence. Re-run on its own three times, it matched. The KV there was built in a different order from the reference, so a floating-point difference is the likely cause, but that wasn't proven. It is a different thing from the 10 out of 10.

## Why it's easy to miss

The request is honoured on its face. It names an adapter and a scale, the server accepts it, and the generated tokens are produced with that adapter applied. Only the part of the context that came from the cache was computed differently, and nothing in the response says which part that was. `cache_n` tells you that something was reused, not under what.

It needs a particular pattern to show up: the same prompt prefix sent under two different LoRA settings, with another request in between that takes the slot. That is exactly what a server that switches adapters per request does all day, with a shared system prompt and different personas or tasks per adapter. A test that sends one request per setting, or sends the two settings back to back, never sees it, because then the slot still holds the KV and the slot-level check works. With `-np 4` and the same ten-prompt sequence, every answer was right: each prompt kept its own slot.

And the output from a contaminated request is plausible. On a 15M story model the difference is easy to see. On a real model with a style or persona adapter, a request that is half one adapter and half the other looks like a slightly off answer.

## What's really going on

The unit the cache stores, in `tools/server/server-task.h` at b11514:

```cpp
struct server_prompt {
    server_tokens tokens;

    std::list<common_prompt_checkpoint> checkpoints;
    ...
};
```

Tokens and checkpoints, nothing about adapters. When a request is assigned a slot, `get_available_slot` saves the slot's current prompt to the cache and loads the entry with the longest matching prefix for the new request (`prompt_save`, then `prompt_load`). Matching is by tokens only.

The LoRA check comes after that, in `launch_slot_with_task`:

```cpp
if (!task.params.lora.empty()) {
    auto task_loras = construct_lora_list(task.params.lora);
    if (!are_lora_equal(task_loras, slot.lora)) {
        // if lora has changed, check to see if the cache should be cleared
        if (lora_should_clear_cache(slot.lora, task_loras)) {
            slot.prompt.clear();
        ...
        slot.lora = task_loras;
    }
} else {
    slot.lora = params_base.lora_adapters;
}
```

`slot.lora` is the LoRA setting of the slot's previous request. In the sequence above that is step 2 at scale 1, the new request is also scale 1, so nothing is cleared, and the KV that `prompt_load` just put in the slot, computed at scale 0, stays. When the prompt keeps its own slot, `slot.lora` really is the setting its KV was computed under, and the check clears it as intended. That is why `-np 4` was fine here.

Requests with no `lora` field, which is what you send after changing the scale globally with `POST /lora-adapters`, take the `else` branch, which doesn't compare anything. That is the path in #26207, and it was 10 out of 10 here as well.

## The fix

Until the cache records the adapters it was computed with:

- **Start the server with `--cache-ram 0`** if it serves more than one LoRA setting. All ten answers were right. You lose the RAM cache across slots, but each slot still reuses its own prefix, and the LoRA check works there.
- **Or send `"cache_prompt": false` on every request.** Step 3 sent that way came back with `cache_n=0` and the right answer on all ten. It has to be every request, because the entries are written whatever the flag says, and any request that doesn't opt out can read one computed under another setting.

Changing the scale globally through `POST /lora-adapters` is affected in the same way and is fixed the same way.

To test a running server, `check-lora-cache.sh` runs the same three steps with a probe prompt containing a random marker, after pushing it out of every slot, and compares the answer with an uncached request. On the default server it reported contamination with one slot and with four. With `--cache-ram 0` it reported that the cache never restored the probe, which is the fixed state.

## The generalisable habit

A cache key has to include everything that went into computing the value. Here the value is KV, and it depends on the tokens and on which adapters were applied. The key has only the tokens. The server knew about the second input, but checked it against the wrong thing: the slot's history instead of the cached entry's. The question to ask of any cache is "what else did this value depend on, and is it in the key?".

The test for it is the A, B, A sequence. Compute something under setting A, make the cache evict it, ask for it again under setting B, and compare with an uncached answer under B. Back-to-back requests won't find it, because nothing has been evicted yet.

The same RAM cache also has [a "no limit" setting that keeps less than the default](https://homelabpostmortem.com/2026/09/24/llama-server-cache-ram-minus-one-is-not-no-limit/). In both cases the server gave no error, and the evidence was in `cache_n`.
