---
title: "An Ollama library tag that pulls, runs, and streams fluent text with no working code in it. The same model at the same quantisation, converted by someone else, is fine."
date: 2026-09-07
excerpt: "qwen2.5-coder:3b-instruct-q3_K_M downloads cleanly, loads at normal speed and answers every prompt. It scored 0/3 on trivial coding tasks here. The q4_K_M sibling scored 3/3, and so did the official Qwen GGUF at the same q3_K_M level with the same template — so it is not that 3B at q3 is too small. It is that conversion."
devto_tags: ai, ollama, llm, devops
---

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
about ten seconds and it is the only signal you are going to get.

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
