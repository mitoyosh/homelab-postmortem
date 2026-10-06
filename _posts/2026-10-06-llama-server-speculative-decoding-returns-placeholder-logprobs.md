---
title: "With speculative decoding on, llama-server's logprobs are placeholders: 0.0 and no alternatives for every token after the first"
date: 2026-10-06
excerpt: "llama-server emits every token that comes out of its speculative decoding loop with logprob 0.0 and an empty top_logprobs list, and never fills them in. With a draft model that is every token after the first. On b11430, mean logprob over 64-token samples went from -0.48 without speculation to -0.0011 with it, while the generated text looked normal. The server's sampled tokens kept the right distribution; the llama-speculative example did not."
devto_title: "llama-server's logprobs are placeholders when speculative decoding is on"
devto_tags: llamacpp, llm, selfhosted, ai
---

**TL;DR**: When `llama-server` runs with speculative decoding (a draft model with `-md`, MTP, or one of the n-gram types), every token that comes out of the speculative loop is sent with `logprob: 0.0` and an empty `top_logprobs` list. The code sets the probability to 1.0 with the comment `// set later` and never sets it. With a draft model that is every token after the first. On b11430, the current release, the mean logprob of 64-token samples at temperature 1 was -0.48 without speculation and -0.0011 with it. The generated text looked normal, and nothing in the response or the log says the numbers are fill-ins. There is no per-request switch: the request fields that used to tune speculation are compiled out and ignored. Send logprob requests to an instance started without speculation. The tokens themselves are fine: on a small fixture, the server's speculative output had the same next-token distribution as plain sampling. The `llama-speculative` example program did not. The toolkit's `check-spec-logprobs.sh` checks a running server. Upstream: [ggml-org/llama.cpp#27972](https://github.com/ggml-org/llama.cpp/issues/27972) and [#29975](https://github.com/ggml-org/llama.cpp/issues/29975).

## The symptom

Debian 13 LXC, CPU only, llama.cpp b11430 from the release tarball (the current release, SHA-256 matching the release digest), `gemma-3-1b-it-Q4_K_M`. A draft model normally has to be smaller than the target to save time; using the same file as its own draft is enough to put every token through the speculative path, and needs no extra download. The request is the one from the report:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "messages": [{"role": "user", "content": "Explain how a CPU branch predictor works."}],
  "max_tokens": 24, "temperature": 1.0, "seed": 1, "logprobs": true, "top_logprobs": 3}'
```

Without speculation:

```
'Okay'    logprob=-0.00813608   top_logprobs=3
','       logprob=0             top_logprobs=3
' let'    logprob=-2.38419e-07  top_logprobs=3
'’'       logprob=-2.60903      top_logprobs=3
's'       logprob=0             top_logprobs=3
' break'  logprob=-0.0479959    top_logprobs=3
```

Same server started with `-md gemma-3-1b-it-Q4_K_M.gguf --spec-type draft-simple`:

```
'Okay'    logprob=-0.00813608   top_logprobs=3
','       logprob=0             top_logprobs=0
' let'    logprob=0             top_logprobs=0
"'"       logprob=0             top_logprobs=0
's'       logprob=0             top_logprobs=0
' break'  logprob=0             top_logprobs=0
```

All 23 tokens after the first came back as 0 with no alternatives, at temperature 0 and at 1, on `/v1/chat/completions` and on the native `/completion` with `n_probs`. With `post_sampling_probs: true` the native endpoint reported `prob: 1.0` and an empty `top_probs` for every token after the first; the unspeculated run gave `What` 0.048, for example.

The effect on anything that aggregates logprobs is not subtle. Five seeds, 64 tokens each, "Write a short story about a lighthouse keeper." at temperature 1:

```
no speculation    -0.5158 -0.6775 -0.3832 -0.3360 -0.4898   mean -0.4805
draft model       -0.0055 -0.0    -0.0    -0.0    -0.0      mean -0.0011
```

The report saw the same shape on a Vulkan iGPU with Gemma 4 26B and an MTP drafter: a mean of -0.00107 with MTP against -0.38244 without, measured while trying to find out whether MTP changes the output. b10703, from August and before #27694, gave the same placeholders on the same probes.

## Why it's easy to miss

The fields are all there. `logprob` is a number, `top_logprobs` is a list, and the response validates against any schema you have for it.

A logprob of exactly 0 is not suspicious either. In the run without speculation above, `,` and `s` came back as 0 with three alternatives: a 1B model is that certain of them. So you can't spot the placeholders by looking for zeros. The giveaway is the empty `top_logprobs` on a request that asked for three.

The text looks normal, so nothing seems wrong to anyone reading the output. And the server's own description doesn't help: `/props` reported `"speculative.types": "none"` in its default generation settings on servers started with `-md` and with `--spec-type ngram-mod`. `/slots` is the place that is right: `"speculative": true`.

With the n-gram types it is patchier still. Those only draft when the recent text repeats, so a single response mixes real values and placeholders. On a prompt asking the model to copy a repeated sentence, `--spec-type ngram-mod` with its default settings left 27 of the 30 tokens after the first correct and 3 as placeholders. With a shorter match length it was 26 placeholders out of 30.

## What's really going on

`tools/server/server-context.cpp` at b11430 has two places that emit a generated token. The normal one:

```cpp
result.prob         = 1.0f; // TODO: set it here instead of doing inside populate_token_probs

if (slot.task->params.sampling.n_probs > 0) {
    populate_token_probs(slot, result, slot.task->params.post_sampling_probs, params_base.special, tok_idx);
}
```

and the one after the target has verified a draft, which loops over the accepted tokens plus the one the target sampled itself:

```cpp
for (size_t i = 0; i < ids.size(); ++i) {
    completion_token_output result;

    result.tok          = ids[i];
    result.text_to_send = common_token_to_piece(slot.ctx_tgt, result.tok, accept_special_token(slot, result.tok));
    result.prob         = 1.0f; // set later

    // TODO: set result.probs
```

Nothing sets it later. `populate_token_probs` is called in one place, the normal path. The first token of a response always comes from the normal path, because there is nothing to draft from yet, which is why it alone has real values. After that, with a draft model, every step goes through the speculative loop. That includes steps where the target rejected the whole draft: on a two-token native request the draft got 0 of 3 accepted, and the second token, sampled by the target itself, still came back empty.

## Does speculation change the tokens too?

If the logprobs are wrong, the obvious next question is whether the output is. Speculative decoding is meant to be lossless: the target's verification should leave the distribution of sampled tokens exactly as if there were no draft. [#27694](https://github.com/ggml-org/llama.cpp/pull/27694), merged on 2026-10-02 and in b11430, made the server verify draft-simple and MTP drafts by rejection sampling at temperature above 0, and its description says the output distribution is preserved exactly.

[#29975](https://github.com/ggml-org/llama.cpp/issues/29975) reports that the `llama-speculative` example program does not preserve it, and ships a fixture to show it: two 24 KB GGUFs with an eight-letter vocabulary, a target and a noised copy as draft. After the prompt `bcdbc` and a first generated `f`, the target's own top-3 distribution for the next token is `e` 0.345, `g` 0.452, `h` 0.203. The archive's SHA-256 matched the one in the issue. Built from source at b11430 and run over seeds 1 to 1000 with the report's script:

```
seeds 1..1000; runs with first token 'f' (5): 820
  next token 4 ('e'): 1.000   target: 0.345
  next token 6 ('g'): 0.000   target: 0.452
  next token 7 ('h'): 0.000   target: 0.203
```

The report doesn't test the server. The same fixture through `llama-server` from the same build, same sampler settings (top-k 3, temperature 1), 1000 seeds, with and without `-md draft.gguf`:

```
no speculation    first token 'f': 840   next e 0.330  g 0.452  h 0.218
draft model       first token 'f': 840   next e 0.330  g 0.452  h 0.218   (2470 drafted, 884 accepted)
```

Both match the target distribution within sampling error (one standard deviation is about 0.016 at 840 samples). So the server's speculative path does what #27694 says: it changes which tokens it reports probabilities for, but not which tokens it picks. The example program, a natural place to look when learning how speculative decoding works or benchmarking it, always picks `e`. The report points at two lines: the example takes the draft's top candidate instead of the one it sampled, and on rejection it subtracts the two distributions position by position after sorting both, which pairs up different tokens when top-k leaves different sets. Those reasons are the report's; only the output above was measured here.

## The fix

There is no way to turn speculation off for one request. The server used to accept `speculative.n_max` and related fields per request; on b11430 they are inside an `#if 0` block in `tools/server/server-schema.cpp` ("we disable speculative parameter adjustments for now"), and unknown fields are ignored. Sending `"speculative.n_max": 0` or `1` changed nothing: the same 17 tokens were drafted and the same 23 placeholders came back.

So:

- **Send requests that need logprobs to a server started without `-md` / `--spec-type`.** The unspeculated runs above returned real values on every token. If you want speculation for everything else, that means a second instance.
- **Check `/slots`, not `/props`, to see whether a server speculates.** `curl -s localhost:8080/slots | jq '.[].speculative'`.
- **Treat an empty `top_logprobs` on a request that asked for alternatives as a missing value, not a certain one.** If you can't change the server, at least don't average over those tokens.
- If you benchmark distributions, use `llama-server` rather than `llama-speculative` until #29975 is fixed.

## The generalisable habit

When a measurement comes back too good, check the instrument before the thing you are measuring. The reporter's numbers said MTP made a model almost perfectly certain at temperature 1, which is physically implausible, and that is what made them look at the logprobs instead of the model. A cheap way to do that is to run the same measurement under a condition you know must differ, here with and without the draft, and see whether the instrument can tell them apart. Here it did, and the whole difference was the instrument's.

The second check is the one people skip: when an optimisation is meant to be invisible, test that it is, with something small enough to count. Two 24 KB models and 1000 seeds were enough to show that the server's speculation leaves the distribution alone and the example's doesn't.

The toolkit's `check-spec-logprobs.sh` reads `/slots`, sends one logprob request, and reports whether the tokens after the first came back with alternatives.
