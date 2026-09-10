---
title: "An Ollama library tag that pulls, runs, and streams fluent text with no working code in it. The same model at the same quantisation, converted by someone else, is fine."
date: 2026-09-07
excerpt: "qwen2.5-coder:3b-instruct-q3_K_M downloads cleanly, loads at normal speed and answers every prompt. It scored 0/3 on trivial coding tasks here. The q4_K_M sibling scored 3/3, and so did the official Qwen GGUF at the same q3_K_M level with the same template — so it is not that 3B at q3 is too small. It is that conversion."
devto_title: "An Ollama tag that pulls and runs and has no working code in it. The same model at the same quantisation, elsewhere, is fine."
devto_tags: ai, ollama, llm, devops
---

**Update (2026-09-09)**: the reporter has published the full audit as a
preprint — [*Broken on Arrival: Silently Defective LLM Artifacts in Public Model
Registries and How to Catch Them*](https://arxiv.org/abs/2609.05881) (Aditi
Patodiya, 2026), with the dataset and tooling at
[aditi-p31/quantcheck](https://github.com/aditi-p31/quantcheck). It executed 327
quantised code-capable artifacts, 305 of them from the official Ollama library,
and confirmed silently defective artifacts in the official library, including
the batch of four Qwen2.5-Coder-3B conversions that the `q3_K_M` below belongs
to. **This post only ever tested `q3_K_M`** — the three siblings are the
census's result, not mine.

**Correction (2026-09-10)**: the paragraph above first said *five* defects,
including `phi3.5:3.8b-mini-instruct-q2_K`. **The author has since retracted the
phi3.5 case and the count is four.** The retraction came out of the control this
site asked for: an independent conversion of phi3.5 at `q2_K` *with no
importance matrix* fails identically (0/15), which is genuine capability
collapse at that quantisation, not a bad file. The original referee had been an
imatrix build, and that is what made phi3.5 look like an outlier. The four
Qwen artifacts came through the same re-run stronger, not weaker — the model
author's own no-imatrix conversions score 14/15 at `q2_K` and 15/15 at
`q3_K_M`, where the library artifacts score zero. A revised preprint is going
to arXiv.

Worth carrying away, because it is what caused the error: the replacement
referee turned out to be **the same file under a different name.** The library's
phi3.5 `q2_K` blob is byte-identical to uploads in two separate HuggingFace
repositories — verified here without downloading anything, since Ollama's
registry manifest gives the layer digest and HuggingFace returns the file's
SHA-256 in the `x-linked-etag` header:

```
ollama library  phi3.5:3.8b-mini-instruct-q2_K   54d47caa8bf3…
QuantFactory/Phi-3.5-mini-instruct.Q2_K.gguf     54d47caa8bf3…
neopolita/phi-3.5-mini-instruct_q2_k.gguf        54d47caa8bf3…
bartowski/Phi-3.5-mini-instruct-Q2_K.gguf        7425cb5fec0d…   (imatrix build)
```

**A different repository is not evidence of a different conversion.** Only the
hash settles it, and you can get the hash without transferring the file.

One of its findings is a caveat on my own advice, so it goes at the top rather
than the bottom. **Two of the five defects produce output whose surface
statistics sit inside the healthy range.** The ten-second check further down
this page — look for a missing `def` and `return` — is calibrated against the
artifact I actually had, where the output was a stray `.` and a stray `00`. It
would not catch those two. Reading the output is a filter, not a test; if you
want a test, run what comes back, which is what [the toolkit
script](https://homelabpostmortem.com/toolkit/) does and what the census does.

**TL;DR**: `ollama pull qwen2.5-coder:3b-instruct-q3_K_M` succeeds, `ollama run` streams at normal speed, and nothing anywhere reports a problem. On three trivial HumanEval-style tasks it produced **no implementation at all** — 0/3. The obvious conclusion is that 3B at q3 is simply too degraded to code. That conclusion is wrong, and one control disproves it: the **official Qwen GGUF at the same q3_K_M level**, imported with the library model's own template so only the weights differ, scored **3/3** on the same tasks. The failure is in that conversion, not in the quantisation level.

## The symptom

Debian 13, Ollama 0.33.3, CPU only. Ask for the simplest function in HumanEval:

```
Please provide a self-contained Python script that solves the following
problem in a markdown code block:

def sum_to_n(n: int) -> int:
    """ sum_to_n is a function that sums numbers from 1 to n. """
```

`qwen2.5-coder:3b-instruct-q3_K_M` answers, deterministically, with 85 characters:

```
.
00











 to_n: function to_n:










```

A stray `.`, a stray `00`, two floods of newlines, and `to_n: function to_n:` —
the identifier from the prompt echoed back. No `def`. No `return`. Nothing to run.

It is not a fluke or a sampling artefact. At `temperature 0` and `seed 42`, two
runs produced byte-identical output (`sha256 ec98f76dfeeda2a3…`).

**Everything around it reported success.** The pull completed and verified, the
model is 1.6 GB on disk as advertised, load time and token rate look normal, and
the HTTP API returns 200 with a populated `response` field. The only thing wrong
is the content.

## Why "q3 is just too small" is the wrong conclusion

That was the first hypothesis here, and it is the one most people will reach,
because it is usually right. Low-bit quantisation of a small model genuinely
does fall apart — it is a known trade-off, it is discussed everywhere, and a
3B model at 3 bits is exactly where you would expect it.

Two controls, same machine, same prompts, same `temperature 0` / `seed 42`,
generated code extracted and **actually executed** against assertions rather
than eyeballed:

```
model                                                    result
qwen2.5-coder:3b-instruct-q3_K_M   (Ollama library)      0/3
qwen2.5-coder:3b-instruct-q4_K_M   (Ollama library)      3/3
Qwen official qwen2.5-coder-3b-instruct-q3_k_m.gguf      3/3
```

The third row is the one that settles it. **Same model, same quantisation
level, a different conversion — and it works.** Here is what it returns for the
prompt above:

```python
def sum_to_n(n: int) -> int:
    """ sum_to_n is a function that sums numbers from 1 to n. """
    return n * (n + 1) // 2
```

So "3B at q3 cannot code" is false on this machine. Something specific to that
artifact is broken.

### The control had to be chosen carefully

The obvious control is one of the popular community re-quantisations, and it is
the wrong one. Those repositories ship an `.imatrix` file — they use
importance-matrix quantisation, which is a different process. If the working
control is an imatrix quant and the broken one is not, then a difference between
them supports two stories at once: "this conversion is broken", and "imatrix
matters enormously at 3B/q3". You cannot tell which you are looking at.

The official Qwen GGUF repository has no `.imatrix`, which makes it the control
that answers only one question:

```bash
curl -s https://huggingface.co/api/models/bartowski/Qwen2.5-Coder-3B-Instruct-GGUF \
  | grep -o 'imatrix'          # present
curl -s https://huggingface.co/api/models/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF \
  | grep -o 'imatrix'          # nothing
```

One more thing had to be held constant. A raw GGUF imported into Ollama needs a
chat template supplied by hand, and **a wrong template produces garbage that
looks exactly like a broken quantisation.** So the template was not written from
scratch — it was lifted from the working library model, verbatim:

```bash
ollama show --modelfile qwen2.5-coder:3b-instruct-q4_K_M \
  | grep -v '^#' \
  | sed 's|^FROM .*|FROM /path/to/qwen2.5-coder-3b-instruct-q3_k_m.gguf|' \
  > Modelfile
ollama create qwen-official-q3 -f Modelfile
```

With that, the only difference between the 0/3 model and the 3/3 model is the
weights.

## What you can check, and what it costs

The artifact is unchanged since it was first reported. All the relevant tags
still read "1 year ago" on the model's tag page, and the manifest being served
right now hashes to the digest that page shows:

```bash
$ curl -s https://registry.ollama.ai/v2/library/qwen2.5-coder/manifests/3b-instruct-q3_K_M \
    | sha256sum | cut -c1-12
65ff2bc170f3
```

`ollama list` shows the same `65ff2bc170f3` after pulling, so what is described
here is what you would get today.

Reproduced on **Ollama 0.33.3**, which is newer than the 0.32.6 in the original
report — upgrading is not the fix.

## The fix

There is no flag for this. The artifact is what it is, and the repair belongs
upstream. What you can do on your own machine is stop using that tag:

**Move up one level.** `q4_K_M` from the same library works and costs about
300 MB more. If you were on `q3` for size reasons, check whether you actually
needed to be.

**Or convert from a source you can name.** The model author's own GGUF at the
same level works. Import it with the library model's template as above, so you
are not trading one silent failure for another.

**And check before you trust it.** The whole test is three prompts and running
what comes back:

```bash
curl -s http://127.0.0.1:11434/api/generate -d '{
  "model": "your-tag-here",
  "prompt": "Please provide a self-contained Python script that solves the following problem in a markdown code block:\n\ndef sum_to_n(n: int) -> int:\n    \"\"\" sums numbers from 1 to n \"\"\"\n",
  "stream": false,
  "options": {"temperature": 0, "seed": 42}
}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["response"])'
```

If what comes back has no `def` and no `return` in it, you have this. It takes
about ten seconds.

**It is a filter, not a test.** It catches the shape of failure I had, where
there was nothing resembling code in the response at all. It does not catch a
defective artifact that emits a plausible-looking function which does not work
— and per the census in the update at the top, two of the five confirmed
defects are exactly that. The only check that separates them is to paste the
returned block into a file and run it against assertions you wrote yourself.

## The generalisable habit

The narrow lesson is that a quantised model is a *build artifact*, not a
property of the model. "Qwen2.5-Coder-3B at q3_K_M" names a recipe; the file you
downloaded is one execution of that recipe by one party, and it can be wrong on
its own without the recipe being wrong. When a model underperforms, the question
"is this quantisation level too low?" and the question "is this file bad?" feel
like the same question and are not. **Converting it yourself, or fetching
another party's conversion at the same level, separates them for the price of
one download.**

The wider one cost me the most time today, and it is about the order you run
things in.

The first control run reported the *working* model as 0/3. The harness was
broken: this model emits its language tag on the line after the code fence
rather than on the fence line, so the extractor was handing `python` to the
interpreter as if it were code. Twenty minutes of a perfectly good model looked
like a second broken one.

I only caught it because the control ran **before** the suspect. Had I started
with `q3_K_M`, I would have seen 0/3, matched it against a report that predicted
0/3, and stopped — with a broken measurement and a conclusion that happened to
agree with it. The error would have survived, because the evidence for it looked
exactly like the evidence for the truth.

So: **run the case you expect to pass first, and treat its failure as a bug in
your instrument until proven otherwise.** A test that has never been seen to
pass has not been shown to work — it has only been shown to produce the answer
you were hoping for. That is the same trap as
[a build that confidently reports a commit hash from a repository it has never
heard of](https://homelabpostmortem.com/2026/09/05/llama-cpp-stamps-a-foreign-repos-commit/):
the thing doing the reporting is not the thing you are trying to measure, and
when they disagree, you will believe the wrong one unless you have arranged in
advance to tell them apart.

The same ordering saved a second finding the same day. [vLLM accepts a LoRA
adapter it has already decided not to apply
anywhere](https://homelabpostmortem.com/2026/09/07/vllm-accepts-a-lora-it-will-never-apply/)
returns base-model output for the ignored adapter — which is also what an
untrained adapter returns when it *is* applied. Only running the overlapping
allow-list first, and watching the same file change the output, made the
identical result mean anything.
