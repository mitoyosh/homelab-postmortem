---
title: "llama.cpp reads past your pos array on every embedding batch for an M-RoPE model — the header says n_tokens, the batch code reads four times that, and the logits change with the heap."
date: 2026-09-16
excerpt: "Same batch, same context, memory cleared, one thread: token ids in, bitwise identical every run; embedding vectors in, Qwen3.5-0.8B, five runs, five different logits and the argmax moves. It looked like the weight type and the batch size mattered. They did not. llama.h says every batch array must have size n_tokens; for an embd batch on an M-RoPE model, ubatch_add copies pos[j*n_tokens + i] for four sections, and sections 1-3 come from whatever follows your array on the heap. valgrind points at the exact line. Sizing pos to 4*N fixes every case."
devto_title: "llama.cpp reads past your pos array on embedding batches for M-RoPE models, and the logits change with the heap"
devto_tags: llm, ai, cpp, debugging
---

**TL;DR**: decode the same `llama_batch.embd` batch twice on an M-RoPE model — Qwen3.5, Qwen2.5-VL, Qwen3-VL, anything whose `llama_model_rope_type()` is `MROPE` or `IMROPE` — and the logits differ, on the CPU, one thread, memory cleared, nothing random anywhere. Token ids through the same context are bitwise identical. The cause is a heap over-read: `llama.h` says every array in a batch "must have size of n_tokens" and `llama_batch_init` allocates `pos` that way, but for an embedding batch on an M-RoPE model `llama_batch_allocr::ubatch_add` reads `pos[j*n_tokens + i]` for `j` in 0..3, on the assumption that embeddings are images with per-section positions. Sections 1–3 are whatever sits after your array. valgrind: `Invalid read of size 4 … ubatch_add … 0 bytes after a block of size 20 alloc'd … llama_batch_init`. Which batch sizes misbehave, and whether BF16 or F16 weights "matter", is heap layout and nothing else — an extra environment variable changed the answer. Allocate `pos` with `4 * n_tokens` entries and fill every section and every case is deterministic. The upstream report ([ggml-org/llama.cpp#28963](https://github.com/ggml-org/llama.cpp/issues/28963)) has the symptom and localises it to the first attention layer; the read that causes it is below, and it is the twin of [the `pos = NULL` over-read from the day before](https://homelabpostmortem.com/2026/09/15/llama-cpp-batch-reads-past-its-own-pos-buffer-for-mrope/).

## The symptom

llama.cpp master `930e2fa` (2026-09-16), CPU build, Debian 13 in an LXC on an i5-8400T, `n_threads = n_threads_batch = 1`, flash attention off, `n_ctx = n_batch = n_ubatch = 512`. A 90-line C program against `libllama`: load a model, build one batch of N positions with `llama_batch_init`, fill `pos[i] = i` the way the header describes, then six times in a row call `llama_memory_clear(mem, true)` and `llama_decode` on that same batch, and compare the full N × n_vocab logits block of each run against run 0. In `tokens` mode the batch carries token ids; in `embd` mode it carries seeded pseudo-random floats through `llama_batch.embd`, as in the report.

`Qwen3.5-0.8B`, BF16 GGUF from `ggml-org`:

```
mode=tokens N=5
run 1..5: bitwise_equal=yes  max_abs_diff=0  cosine=1.00000000  argmax_same=yes

mode=embd N=5
run 1: bitwise_equal=NO  max_abs_diff=2.4   cosine=0.99422627  argmax_same=yes
run 2: bitwise_equal=NO  max_abs_diff=2.05  cosine=0.99525302  argmax_same=NO
run 3: bitwise_equal=NO  max_abs_diff=2.11  cosine=0.99615401  argmax_same=yes
run 4: bitwise_equal=NO  max_abs_diff=1.85  cosine=0.99524820  argmax_same=NO
run 5: bitwise_equal=NO  max_abs_diff=2.06  cosine=0.99490347  argmax_same=yes
```

The report says `argmax` stays constant and the practical impact is on reproducibility. Here it does not stay constant: at N=5 the greedy token differs from run 0 in two runs out of five, and at N=8 in every run. At N=8 the shape is also different — runs 1 through 5 are identical to each other and only run 0 stands apart:

```
mode=embd N=8
run 1..5: bitwise_equal=NO  max_abs_diff=2.47  cosine=0.99254973  argmax_same=NO   (all five identical)
```

## Why this is easy to miss

Nothing in the API says anything. `llama_decode` returns 0, the logits are finite and plausible, and the top token is right most of the time. Greedy generation through this path can match a token-path baseline for a whole sequence and then diverge on the next run where two candidates were close, which reads as "the model is a bit unstable", not "the library read past my array".

It is invisible to almost everyone. `llama-cli`, `llama-server`, chat, completion — all tokenise text and go through `llama_batch.token`, where positions for text are broadcast across the M-RoPE sections and nothing is over-read. `llama_batch.embd` is for people who inject vectors: multimodal projectors, hidden-state relays between model instances, embedding-space experiments. The report came from a layer-pipeline prototype. And the multimodal code in the tree that does use this path — `mtmd` — allocates four positions per token itself, so it never sees it.

Then there is the false trail, which cost most of the afternoon and is worth recording because it looked like a result. The first thing tried was the dense model already on the box, `gemma-3-1b` Q4_K_M: deterministic at every N. Then Qwen3.5 in BF16: not. Then the same Qwen file converted to F16 and Q8_0 with `llama-quantize`: deterministic. Then gemma converted to BF16: deterministic. A tidy six-cell grid with exactly one failing cell — hybrid architecture, BF16 weights — and a one-command workaround. Meanwhile, which batch sizes failed moved around when the graph was rebuilt instead of reused, moved again with a fresh context per decode, and N=8 failed in every configuration. That grid was going to be the article.

It was heap layout. Every one of those variables changes what `malloc` puts next to a 20-byte allocation. The proof that it was layout and not weights came from setting `MALLOC_PERTURB_`, which fills freed and allocated memory with a byte pattern: the results changed, but so did they with `X_PERTURB_=1`, a variable glibc has never heard of, because a longer environment shifts the initial heap. A "fix" that works for reasons you cannot state is a layout accident, and the F16 conversion was one.

## What is really going on

`llama_context_params.cb_eval` is a public callback that sees every graph node after it is computed. Hashing every node's output on each run and reporting the first one that differs from run 0, with the hashes of its sources, gives this at N=8:

```
run 1: 948/1441 nodes differ; FIRST differing node = #0
  #0     node_0        op=GET_ROWS  ne=[1024,8,1,1]     srcs: ALL SAME
  #204   Qcur-3        op=ROPE      ne=[256,8,8,1]
          src0 Qcur_normed-3   (in-place, same buffer)
          src1 leaf_55         DIFFERS   data=…9c860..…9c8e0   (128 bytes)
  #211   Kcur-3        op=ROPE      ne=[256,2,8,1]
          src1 leaf_55         DIFFERS
```

`node_0` is the unselected token-path branch that `ggml_build_forward_select` leaves in the graph without computing; nothing reads it, and zero nodes list it as a source. The first divergence that matters is `Qcur-3`, the RoPE on layer 3 — the first full-attention layer in this model, which is exactly where the reporter's per-layer comparison put it. Its output differs because its second input differs: `leaf_55`, 128 bytes, is `int32 × 32` = 8 tokens × 4. That is the M-RoPE position tensor, and it is different on every run with the same batch.

Positions come from the batch through `llama-batch.cpp`:

```cpp
for (size_t j = 0; j < (size_t)n_pos_per_embd; ++j) {
    // if we are using M-RoPE
    //     if the current batch is text, we need to broadcast the same position across all RoPE sections
    //     otherwise, the input batch is image embeddings, we copy the positions as-is
    size_t src_off = batch.token ? 0 : j*batch.n_tokens;
    udata->pos[j*n_tokens + i] = batch.pos[src_off + idxs[i]];
}
```

For a token batch, `src_off` is 0 and the one position per token is broadcast into all four sections. For an embedding batch, the code assumes "image embeddings" and copies four sections from `batch.pos[j*n_tokens + i]` — indices up to `4*n_tokens - 1`. And the header, `include/llama.h`:

```
// The provided arrays (i.e. token, embd, pos, etc.) must have size of n_tokens
```

with `llama_batch_init` documented, and implemented, to allocate `pos` with `n_tokens` entries. So a caller who does what the header says — the reporter, this probe, anyone relaying hidden states — hands over N positions, and the library reads 4N. valgrind on the unmodified library says it in one line:

```
Invalid read of size 4
   at llama_batch_allocr::ubatch_add(...)
   by llama_batch_allocr::split_equal(...)
   by llama_memory_hybrid::init_batch(...)
   by llama_context::decode(...)
 Address 0xb4e4244 is 0 bytes after a block of size 20 alloc'd
   at malloc
   by llama_batch_init
```

Twenty bytes is five positions. The next twelve ints are the heap. What lives there depends on everything that was allocated before and after the batch — the model's tensors, the context's buffers, the environment — which is why the symptom tracked the weight type, the batch size, graph reuse, a fresh context and an unrelated environment variable, and why at N=8 run 0 differed from runs 1–5 (the neighbour was written once, early, and then left alone). It is also why the zero-input control in the report is bitwise stable: garbage positions rotate a zero vector to another zero vector.

Dense models have `n_pos_per_embd = 1`; the loop runs once and never leaves the array. The over-read needs an M-RoPE model and an embedding batch, and nothing else — not the weight type, not the architecture beyond the RoPE mode, not the batch size.

This is the second over-read in the same fifteen lines in two days. [Yesterday's](https://homelabpostmortem.com/2026/09/15/llama-cpp-batch-reads-past-its-own-pos-buffer-for-mrope/) was `pos = NULL`, where the library auto-generates positions and sized its own buffer to `n_tokens` before reading `4*n_tokens`; that one had a PR, [#28910](https://github.com/ggml-org/llama.cpp/pull/28910), still open. This one is `pos != NULL`, where the buffer is yours and the library reads past it. Same loop, same assumption — that an embedding batch on an M-RoPE model carries four positions per token — applied to a buffer the header told you to make one-quarter the size.

## The fix

**In your code, today.** Allocate four positions per token for any embedding batch on an M-RoPE model, and fill every section — for text-like input, the same position in each:

```c
enum llama_rope_type rt = llama_model_rope_type(model);
int n_pos = (rt == LLAMA_ROPE_TYPE_MROPE || rt == LLAMA_ROPE_TYPE_IMROPE) ? 4 : 1;

struct llama_batch batch = llama_batch_init(N, n_embd, 1);
free(batch.pos);
batch.pos = calloc((size_t)n_pos * N, sizeof(llama_pos));
for (int j = 0; j < n_pos; j++)
    for (int i = 0; i < N; i++)
        batch.pos[j * N + i] = i;   /* position of token i */
```

That is the single-variable test. With it and nothing else changed — same BF16 file, same build, same thread count — every case that failed above is bitwise deterministic across six runs, including N=7–10 with graph reuse disabled and with a fresh context per decode, the configurations nothing else fixed:

```
### pos allocated 4*N, every section filled
RESULT embd N=3: DETERMINISTIC
RESULT embd N=5: DETERMINISTIC
RESULT embd N=8: DETERMINISTIC
RESULT embd N=10: DETERMINISTIC
### + LLAMA_GRAPH_REUSE_DISABLE=1 / fresh context
RESULT embd N=7..10: DETERMINISTIC (all)
```

`llama_batch_free` frees `pos` with `free()`, so replacing the pointer with your own `calloc` is safe.

**Upstream.** The header and the loop disagree, and one of them has to move. Either the header says that embedding batches on M-RoPE models carry `n_pos_per_embd * n_tokens` positions and `llama_batch_init` grows to match (which needs to know the model, and today it does not), or the batch code stops guessing that every embedding is an image and broadcasts when it is handed one position per token — which is what #28910 does for the `pos = NULL` case. The `mtmd` code that legitimately passes four sections would need a way to say so. That is a design decision for the maintainers; the comment in the thread has the trace, the valgrind line and the probe.

**Before you build on this path.** The toolkit's `check-embd-determinism.sh` compiles the probe against your llama.cpp checkout, runs the token path as a control, sweeps the embd path over a list of batch sizes with `pos` sized as documented, and for any N that is not deterministic re-runs it with `pos` sized `n_pos_per_embd * N` to confirm that the over-read is the cause on your build rather than something new:

```
control  tokens N=5   deterministic   (rope_type=40 n_pos_per_embd=4)
embd     N=2          deterministic
embd     N=5          NON-DETERMINISTIC   worst cosine 0.99631981   argmax changed in 3 of 3 runs
         N=5   with pos sized n_pos_per_embd*N: deterministic  -> over-read confirmed
embd     N=8          NON-DETERMINISTIC   worst cosine 0.99226277   argmax changed in 3 of 3 runs
         N=8   with pos sized n_pos_per_embd*N: deterministic  -> over-read confirmed

FAIL: the embd path gave different logits for the same input at N = 5 8,
      while the token path did not.
      Cause on this build: llama-batch.cpp reads n_pos_per_embd*N positions from an
      embd batch on an M-RoPE model, past the N that llama.h documents and
      llama_batch_init allocates.
```

Against gemma-3-1b, or against Qwen3.5 with the fix in place, it prints `OK`. Note that "N=2 deterministic" above is not safety: the twelve bytes past a two-position array happened to be stable on this heap. The over-read is there at every N.

## The generalisable habit

Two, and the second is the one that cost time.

**When a header states a size, find the loop that reads the array and check its bound against the same expression** — the habit from yesterday, and it would have found this in ten minutes if applied to `batch.pos` instead of `udata->pos`. Yesterday's loop and today's are the same loop. The fix for one over-read was a resize of the library's own buffer; the buffer in the other over-read belongs to the caller, so the same loop needed the same look twice.

**A workaround you cannot explain is a measurement of your heap, not of the bug.** The six-cell weight-type grid was real data: every cell was measured, reproducible, and wrong about what it meant. What gave it away was not a failed reproduction but a *successful* one from a variable that could not possibly matter — an environment variable with a made-up name flipped the result, which meant the real variable was memory layout, which meant an uninitialised or out-of-bounds read, which meant stop characterising and start tracing. `cb_eval` found the tensor in one run and valgrind found the line in one more. Neither needed a fork, a hidden-state API or a sanitiser build; both were available the whole afternoon. The order that would have saved three hours is: reproduce, then locate, then characterise — and treat any characterisation that depends on things like weight type or batch size with suspicion until the located cause explains why it should.
