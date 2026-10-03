---
title: "vLLM's weight cache daemon gives an engine another checkpoint's weights when the two have the same tensor layout"
date: 2026-10-03
excerpt: "vLLM 0.30.0's weight cache (load_format ipc_cache) decides whether the daemon's weights match the engine's checkpoint by hashing safetensors headers: names, shapes, dtypes, offsets, no values. With the daemon holding Qwen3-0.6B, an engine started on a copy with one tensor zeroed answered exactly like the original, logged that it mapped 339 tensors from the daemon, and warned about nothing. A checkpoint with a different layout was rejected as documented."
devto_title: "vLLM's weight cache can serve another checkpoint's weights when the tensor layout matches"
devto_tags: llm, vllm, selfhosted, debugging
---

**TL;DR**: vLLM 0.30.0 can keep a model's weights in a long-running daemon so that engines restart without reloading them (`load_format="ipc_cache"`). Before an engine uses those weights, both sides compare a fingerprint, and the docs describe the checkpoint part of it as "checkpoint content". In the code it is a hash of each shard's file name and safetensors header: tensor names, shapes, dtypes and offsets, but no tensor values. Two checkpoints with the same layout, such as a base model and a fine-tune of it, or two training steps, get the same fingerprint. On an RTX 2070, a daemon holding Qwen3-0.6B served an engine started on a copy with `model.norm.weight` zeroed. On its own that copy answers `'!!!!!!!!!!!!'`. With the daemon running, it answered `' Paris. The capital of Italy is Rome. The capital of'`, exactly like the original, logged `Mapped 339 tensors from the weight cache daemon`, and warned about nothing. Upstream report: [vllm-project/vllm#59647](https://github.com/vllm-project/vllm/issues/59647).

## The symptom

RTX 2070 (8 GB) on Windows 11, WSL2 Ubuntu, driver 591.86, vLLM 0.30.0 with torch 2.13.0+cu130, everything in fp16 since the card has no bf16. Two checkpoints, following the report:

```bash
hf download Qwen/Qwen3-0.6B --local-dir q
cp -r q q_mod
# zero the 2,048 bytes of model.norm.weight in q_mod/model.safetensors, header untouched
```

The files differ, and loaded normally each behaves like itself. Greedy decoding, 12 tokens, "The capital of France is":

```
q      load_format=auto   ' Paris. The capital of Italy is Rome. The capital of'
q_mod  load_format=auto   '!!!!!!!!!!!!'
```

Then the daemon, preloaded with `q`. The report used `vllm preload`, which isn't in the 0.30.0 CLI. The module the docs point to is:

```bash
python -m vllm.model_executor.model_loader.weight_cache.daemon --model q --dtype float16
# ===== Weight cache daemon READY: node 0/1 serving 1 local rank(s) in the default socket dir =====
```

and an engine on `q_mod` with the cache:

```
q_mod  load_format=ipc_cache   ' Paris. The capital of Italy is Rome. The capital of'
  INFO [ipc_loader.py:203] Mapped 339 tensors from the weight cache daemon (zero_copy mode)
```

The engine was asked for `q_mod` and ran `q`, with no warning from either process. To confirm that the check itself works, an engine started with `ipc_cache` on a different model (a small random Qwen3 with different shapes) was turned away and fell back to disk, as documented:

```
WARNING [ipc_loader.py:139] Weight cache unusable (WeightCacheKey mismatch on fields: ['checkpoint']); falling back to disk loading
```

So the fallback works when the layout differs, and doesn't trigger when only the values do.

## Why it's easy to miss

Everything you'd look at points at the checkpoint you asked for. The engine was started on `q_mod`, the only log line about weights says they were mapped successfully, and the output is fluent text from a working model. Only the weights are someone else's. In the realistic case, a base model and its fine-tune, or the same fine-tune at two steps, the wrong answers are plausible ones. Nothing points at the cache.

The documentation says this case can't happen. The feature's page on the main branch (`docs/features/preload.md`, which isn't in the 0.30.0 tag) lists a "Safe fallback" for cached weights that "don't match the engine's configuration". It describes the fingerprint as covering "checkpoint content (hashed from safetensors metadata, ...)". That parenthesis gives it away: metadata is all it hashes, and different weights can have identical metadata.

## What's really going on

`vllm/model_executor/model_loader/weight_cache/protocol.py` in 0.30.0:

```python
def hash_checkpoint(model: str) -> str | None:
    """Fingerprint checkpoint content from local safetensors metadata.

    Hashes each shard's safetensors header so a daemon and an engine pointing
    at identical weights in different directories produce the same key. ...
    """
    ...
    for path in sorted(files, key=os.path.basename):
        hasher.update(os.path.basename(path).encode())
        hasher.update(_safetensors_header(path))
    return hasher.hexdigest()
```

A safetensors header is a JSON index: for each tensor, its name, dtype, shape and byte offsets. Fine-tuning changes none of those. The design goal in the docstring, letting a copy of the same weights in another directory match, is met by hashing less than the content. The side effect is that different weights with the same layout match too. The rest of `WeightCacheKey` (architecture, dtype, quantization, TP rank, vLLM version) is the same for a local base model and its fine-tune as well.

A fix is proposed in [#59648](https://github.com/vllm-project/vllm/pull/59648), titled "Fingerprint sampled tensor bytes, not headers only". It is open, and 0.30.0 is the current release.

## The fix

Until that ships, the daemon's checkpoint and the engine's must be the same one, and nothing will tell you if they aren't. In practice:

- **Run a weight-cache daemon only for the checkpoint you serve.** If you switch between a base model and fine-tunes of it, or between training checkpoints, either stop the daemon and start one for the new checkpoint, or load the others with the default `load_format`.
- **Treat "Mapped N tensors from the weight cache daemon" as a claim to check.** After any switch, compare one deterministic prompt between `load_format="ipc_cache"` and `"auto"` for the checkpoint you think you're serving. Here that took one prompt and twelve tokens to show the difference.

Neither of those was needed for a different-shaped model, which the existing check caught.

## The generalisable habit

A cache key decides what counts as the same thing. Whoever chose this one optimised for matching identical weights in different places, and in doing so it also matched different weights in the same layout. When a cache promises a safe fallback on mismatch, find out what the key covers before relying on it. The test is cheap: make two inputs that differ only in what the key leaves out, and see whether the cache tells them apart.

The same version of vLLM also [loads a LoRA adapter's per-module scaling as one number](https://homelabpostmortem.com/2026/10/03/vllm-ignores-lora-rank-pattern-and-alpha-pattern/) and serves it without a warning. In both cases vLLM read less of what it was given than it reported using.
