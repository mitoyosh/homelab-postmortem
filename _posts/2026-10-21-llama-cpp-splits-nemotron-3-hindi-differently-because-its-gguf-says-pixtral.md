---
title: "llama.cpp splits Hindi, Tamil and Thai differently from how Nemotron 3 was trained, because its GGUF says pixtral"
date: 2026-10-21
excerpt: "NVIDIA's Nemotron 3 Nano 4B GGUF carries tokenizer.ggml.pre = pixtral, which llama.cpp handles with the Llama 3 pre-tokenizer instead of Tekken. English, Japanese and code tokenized exactly as on Hugging Face; Hindi took 30 tokens instead of 19, Tamil 20 instead of 15, Thai 16 instead of 15. Running llama-server with --override-kv tokenizer.ggml.pre=str:tekken made every sample match. llama-tokenize accepts that flag and silently ignores it."
devto_title: "llama.cpp splits Hindi and Thai differently for Nemotron 3 because its GGUF says pixtral"
devto_tags: llm, llamacpp, selfhosted, ai
---

**TL;DR**: NVIDIA's `Nemotron-3-Nano-4B` GGUF says `tokenizer.ggml.pre = "pixtral"`. In llama.cpp, `pixtral` selects the Llama 3 pre-tokenizer, but Nemotron's own tokenizer uses the Tekken split rules. The result: on llama.cpp master (339f324), English, Japanese, Arabic and code tokenized exactly as Hugging Face's tokenizer does, while Hindi took 30 tokens instead of 19, Tamil 20 instead of 15 and Thai 16 instead of 15, and `दी` became two tokens instead of one. Nothing errors; the model loads and answers. Starting `llama-server` with `--override-kv tokenizer.ggml.pre=str:tekken`, or rewriting the file's metadata to `tekken`, made every sample match Hugging Face. One trap: `llama-tokenize`, the obvious tool to check this with, accepts `--override-kv` and ignores it, so the fix looks like it doesn't work. Upstream: [ggml-org/llama.cpp#30894](https://github.com/ggml-org/llama.cpp/issues/30894), which lists other affected uploads.

## The symptom

A disposable LXC container, llama.cpp built from master at 339f324, `NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf` from `nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF` (2,837,072,864 bytes, matching the size on Hugging Face), and the same model's `tokenizer.json` from `nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16` as the reference. The GGUF's tokenizer metadata:

```
general.architecture = nemotron_h
tokenizer.ggml.model = gpt2
tokenizer.ggml.pre = pixtral
```

Token IDs for the same text, without special tokens, Hugging Face `tokenizers` against llama-server's `/tokenize`:

```
  english    HF  19  server  19 ==
  hindi-one  HF   1  server   2 !=  [4894, 2063]
  hindi      HF  19  server  30 !=
  tamil      HF  15  server  20 !=
  thai       HF  15  server  16 !=
```

`hindi-one` is `दी`, which Hugging Face encodes as `[44213]`. Japanese (13), Arabic (5) and a line of Python (12) matched exactly.

The same server started with `--override-kv tokenizer.ggml.pre=str:tekken`:

```
  english    HF  19  server  19 ==
  hindi-one  HF   1  server   1 ==  [44213]
  hindi      HF  19  server  19 ==
  tamil      HF  15  server  15 ==
  thai       HF  15  server  15 ==
```

A copy of the GGUF with the metadata rewritten to `tekken` gave the same full match.

## Why it's easy to miss

Everything a quick check looks at is fine. The file loads, `llama-server` starts, chat works, and English, the language most people test with, is token-for-token identical. Code and Japanese were identical too. The difference is confined to scripts where the two split rules disagree, here the Indic scripts and Thai, and the only symptoms are that those prompts use more tokens and the model sees them split in a way it never saw in training. How much that hurts answers wasn't measured here, and it may be small for a short prompt.

It also hides behind something people already expect: Indic scripts take more tokens than English with most tokenizers, so a high count for Hindi doesn't look unusual. The extra from llama.cpp only shows up next to the Hugging Face count.

And the obvious way to test a fix gives the wrong answer. `llama-tokenize` is llama.cpp's tool for exactly this, and it accepts `--override-kv` without complaint:

```
$ llama-tokenize -m NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf -p "दी" --ids --log-disable --no-bos \
    --override-kv tokenizer.ggml.pre=str:tekken
[4894, 2063]
```

Still two tokens, exit 0. Its source (`tools/tokenize/tokenize.cpp`) has no override handling at all, while an unknown flag such as `--no-such-flag` is rejected with an error, so the override is parsed and then dropped. The same flag on `llama-server` works, as shown above.

## What's really going on

When a model is converted, llama.cpp's converter identifies the tokenizer by hashing how it splits a fixed test string, and looks the hash up in a table of known tokenizers to choose the `pre` name it writes into the GGUF. According to the report, the Nemotron tokenizer's hash is the same as Pixtral-12B's, so the converter writes `pixtral`. In `src/llama-vocab.cpp`, `pixtral` is grouped with `llama3` and gets the Llama 3 pre-tokenizer, which is right for Pixtral. Nemotron's `tokenizer.json` uses the Tekken split pattern, which llama.cpp has under the separate name `tekken`. The two patterns behave the same on English and code and differ on the scripts above.

The test here can't see the converter's hash, but the results fit that explanation exactly: everything else in the file is unchanged, and changing only the `pre` name, by override or by rewriting the file, makes every sample match.

The report proposes a load-time fix (treat `pixtral` as Tekken when the architecture is Nemotron), which would also correct GGUFs already published. As of 21 October the issue has no replies and there is no pull request.

## The fix

**At load time:** add the override to whatever runs the model.

```
llama-server -m NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf --override-kv tokenizer.ggml.pre=str:tekken
```

**Or rewrite the file once**, with the script that ships in llama.cpp's `gguf-py`:

```
python gguf-py/gguf/scripts/gguf_new_metadata.py --pre-tokenizer tekken \
    NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf nemotron-tekken.gguf
```

That writes a new file and leaves the original alone; it took about five seconds for the 2.8 GB file here.

**Check with `llama-server`'s `/tokenize`, not `llama-tokenize`**, for the reason above.

Other front ends that bundle llama.cpp, such as Ollama and LM Studio, have their own ways of passing metadata overrides, if any; those weren't tested here. Only NVIDIA's Nano 4B upload was tested; the report lists other Nemotron 3 and 3.5 GGUFs from NVIDIA, ggml-org, Unsloth, bartowski and LM Studio as carrying `pixtral` too, and one Unsloth upload as carrying `tekken`.

The toolkit's `check-gguf-pretokenizer.sh` reads the GGUF header directly (no model load, 0.05 s for this file) and flags this combination:

```
  WRONG    m/NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf: architecture nemotron_h, pre-tokenizer 'pixtral' (llama.cpp splits it as Llama 3); should be 'tekken'
  ok       m/nemo-tekken.gguf: architecture nemotron_h, pre-tokenizer 'tekken'
```

With `--server <url> --hf-tokenizer tokenizer.json` it sends multilingual samples to a running `llama-server` and compares them with Hugging Face's tokenizer, which catches this kind of mismatch for any model, not just this one.

## The generalisable habit

Test a local model in the languages you'll actually use, against the reference tokenizer, not just by chatting with it. A tokenizer mismatch doesn't break anything visibly; it shifts what the model sees. Comparing token IDs with the original `tokenizer.json` for a few sentences in each language takes a minute and settles it.

And when a check says a fix didn't work, check the checker. Here the tool silently ignored the option being tested. A tool that accepts a flag it doesn't implement will make a correct fix look wrong; trying the same thing a second way, through the server, showed it.

A different metadata field steering a model to the wrong behaviour came up with Ollama: [it picks the Gemma 4 prompt template from the model's name](https://homelabpostmortem.com/2026/10/07/ollama-picks-the-gemma-4-template-from-the-model-name/).
