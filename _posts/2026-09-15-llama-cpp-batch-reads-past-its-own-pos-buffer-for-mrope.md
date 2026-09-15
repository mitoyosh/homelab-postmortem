---
title: "llama.cpp's batch API says pass pos as NULL and positions are tracked automatically. For M-RoPE embeddings it then reads past its own buffer, and nothing reports it."
date: 2026-09-15
excerpt: "An embeddings batch with pos = NULL on a Qwen2.5-VL-style model gets a position vector sized n_tokens, and the batch splitter reads n_tokens × 4 from it. AddressSanitizer on today's master: heap-buffer-overflow, READ of size 4, zero bytes after an 8-byte region, llama-batch.cpp:787, allocated at line 91. No crash in a normal build — the extra bytes are whatever sits next to the vector, and they go into the model. The open fix PR makes the read stop; a caller who follows the header's other instruction, allocate n_tokens, is still on their own."
devto_title: "llama.cpp reads past its own pos buffer for M-RoPE embeddings, and nothing reports it"
devto_tags: llm, ai, cpp, debugging
---

**TL;DR**: `include/llama.h` says the `pos` array "must have size of n_tokens", and that if you pass `NULL` "the token position will be tracked automatically". For a model that uses multiple positions per embedding — M-RoPE, which is Qwen2.5-VL and Qwen2.5-Omni — the automatic path sizes its own vector to `n_tokens` and the batch splitter then reads `4 × n_tokens` from it. On master as of today, AddressSanitizer reports a `heap-buffer-overflow`, `READ of size 4`, `0 bytes after 8-byte region`, at `llama-batch.cpp:787`, on a vector allocated at `llama-batch.cpp:91`. In a normal build nothing fires; the bytes that follow the allocation become positions and the model runs on them. An open pull request fixes the `NULL` path and I have verified it does; the caller-allocated path is fixed only by changing what the header asks for.

## The symptom

This one did not present as a symptom to me. It presented as a code-read on the llama.cpp tracker, [`#28902`](https://github.com/ggml-org/llama.cpp/issues/28902), where two people had converged on the same diagnosis from the source and a third, running Qwen2.5-Omni under Metal, had the field data: a 750-token audio prefill that "allocated 3,000 bytes and read 12,000", output that was intermittently incoherent, and a failure rate that moved with what else was running on the machine — the signature of a read past the end of an allocation, where the extra bytes depend on what happens to be next to it.

What the thread did not have was a sanitiser trace. "The ASan build would help," one of them wrote. "A heap-buffer-overflow trace turns two code reads into a reproducible report." So that is what this is.

## What is really going on

Two lines from `include/llama.h`, as shipped:

```c
// The provided arrays (i.e. token, embd, pos, etc.) must have size of n_tokens          (line 248)
// - pos : the positions of the respective token in the sequence
//         (if set to NULL, the token position will be tracked automatically ...)         (line 253)
```

The automatic path, `src/llama-batch.cpp`, line 91:

```cpp
if (!batch.pos) {
    pos.resize(batch.n_tokens);
```

And the batch splitter, lines 780–787, which for an embeddings batch (`batch.token == NULL`) reads one position per RoPE section:

```cpp
for (size_t j = 0; j < (size_t)n_pos_per_embd; ++j) {
    // if we are using M-RoPE
    //     if the current batch is text, we need to broadcast the same position across all RoPE sections
    //     otherwise, the input batch is image embeddings, we copy the positions as-is
    size_t src_off = batch.token ? 0 : j*batch.n_tokens;
    udata->pos[j*n_tokens + i] = batch.pos[src_off + idxs[i]];
}
```

`n_pos_per_embd` is 4 for M-RoPE. The loop reads `batch.pos[0 … 4·n_tokens − 1]`. The vector it reads from has `n_tokens` entries. Both halves of the header are wrong for this model family: a caller who allocates `n_tokens` gets overread, and a caller who passes `NULL` gets overread by the library's own fallback. The comment on the loop describes the intent correctly; the intent was never matched by an allocation.

## The trace

The fix PR, [`#28910`](https://github.com/ggml-org/llama.cpp/pull/28910), adds a 24-line test to the existing `tests/test-batch-alloc.cpp`: a two-token embeddings batch with `pos = NULL` against a mock vocab with `n_pos_per_embd = 4`. That test does not need a model, a GPU, or a Linux box, so I ran it on a Mac mini — master `4c9233c`, Apple clang 21, Metal off, `-DLLAMA_SANITIZE_ADDRESS=ON` — first with only the test applied and the fix left out:

```
==8100==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x602000007c18
READ of size 4 at 0x602000007c18 thread T0
    #0 llama_batch_allocr::ubatch_add(...)      llama-batch.cpp:787
    #1 llama_batch_allocr::split_simple(...)    llama-batch.cpp:507
    #2 test_mrope(...) auto_pos_broadcast_for_embd   test-batch-alloc.cpp:640

0x602000007c18 is located 0 bytes after 8-byte region [0x602000007c10,0x602000007c18)
allocated by thread T0 here:
    ...
    #8 llama_batch_allocr::init(...)             llama-batch.cpp:91

SUMMARY: AddressSanitizer: heap-buffer-overflow llama-batch.cpp:787
```

Eight bytes is two `int32` positions — `n_tokens = 2`. The first read past the end is `pos[2]`, the start of the second M-RoPE section. That is the diagnosis from the thread, with an address on it.

Then with the PR's `src/` and `include/` changes applied, same build flags:

```
  auto_pos_broadcast_for_embd (11 assertion(s))                                 [PASS]
failures   : 0
```

The fix resizes the fallback vector to `n_tokens × n_pos_per_embd` and broadcasts each auto-generated position across the sections. Eleven assertions, no sanitiser output, exit 0.

## Why this is easy to miss

A `READ` past the end of a heap allocation does not crash. It reads whatever is there. In a release build the next eight, sixteen, or several thousand bytes of the heap become RoPE positions, the model computes attention against them, and the output is a little wrong, or a lot wrong, or fine, depending on what the allocator happened to place there. That is exactly the field report: intermittent, load-dependent, silent. A bug that presents as "the model is flaky on long audio" is not one anybody goes looking for in the batch allocator.

It also survives the obvious defence. Someone who reads the header and allocates `pos` to exactly `n_tokens` has done the documented thing. Someone who reads the header and passes `NULL` has done the other documented thing. Neither one is a bug in their code, and neither one can be fixed in their code without knowing the layout the library actually wants — four section-major planes of `n_tokens` each, which the header did not say until this PR.

## The fix

Upstream, when `#28910` merges: the `NULL` path is repaired, and `llama.h` gains a note that embeddings batches on `n_pos_per_embd > 1` models must supply `n_tokens × n_pos_per_embd` positions in consecutive sections. Note what that second half is: a documentation change. `llama_batch_init()` still allocates `pos` at `n_tokens`; the caller-side overread is closed by telling callers to allocate more, not by the library allocating more. The thread calls this an API question for the maintainers, and it is.

Until then, if you feed embeddings to an M-RoPE model through the batch API directly — not through `mtmd`, which already lays positions out correctly — allocate `pos` yourself at `n_tokens × 4` and fill the four planes, as `tools/mtmd/mtmd-helper-common.h` does. That is what the reporter of the field data did, and it is what turned four intermittently broken runs into four coherent ones.

If you want to know whether your build has it, the test is the check. Apply the PR's `tests/` hunk to a checkout, build `test-batch-alloc` with `-DLLAMA_SANITIZE_ADDRESS=ON`, and run it. Under a minute after the build, no model required.

There is no toolkit script for this one. The detection is "build with a sanitiser and run the test", and that is not something a script would improve on.

## The generalisable habit

The narrow one: **when a header documents a size, find the loop that reads the array and check its bound against the same expression.** Here they were `n_tokens` and `n_pos_per_embd × n_tokens`, in files a few hundred lines apart, and both were individually reasonable.

The wider one is about what a code-read is worth. Two competent people agreed on this bug from reading the source, and they were right — but agreement is not a reproduction, and the thread knew it. A sanitiser trace took twenty minutes and settled it with an address and a line number. When a finding is "we read the code and it looks like it overreads", the next step is not a third reader. It is [the same move as removing a constraint to see whether the bytes change](https://homelabpostmortem.com/2026/09/12/llama-server-ignores-the-response-format-its-readme-shows/): arrange for the thing to be observed rather than inferred, then observe it.
