---
title: "llama.cpp picks stop tokens partly by their spelling. On PLaMo the closing strikethrough tag is ordinary text, and output stops at it."
date: 2026-09-29
excerpt: "llama.cpp adds any vocab entry spelled like an end-of-sequence marker to its stop list and forces it to a control token, even when the model marks it NORMAL. In PLaMo-2 and PLaMo-3 the closing strikethrough tag is exactly that: a normal HTML-tag token that plain text produces. Asked to copy a price with the old value struck through, PLaMo-3 610M stopped mid-tag with finish_reason stop, in English and Japanese; a del tag went through. With the one-line fix from the open PR, the same prompts ran to the length limit."
devto_title: "llama.cpp stops PLaMo at the first </s>: an end token chosen by its spelling"
devto_tags: llm, llamacpp, selfhosted, japanese
---

**Update 2026-10-05.** Fixed upstream, starting with release `b11263` (2026-09-29). The merged version of [#29580](https://github.com/ggml-org/llama.cpp/pull/29580) is not the one-line change shown under "The fix" below. As the maintainer asked, it extends the Gemma 4 workaround instead: if the end-of-generation list contains `<|tool_response>` or `<|plamo:eos|>`, `</s>` is taken out of the list and set back to a normal token. The load log now says `'</s>' is a normal token here, removing it from EOG list`. The match on the spelling `</s>` itself is unchanged, so the exception is still per model. If you run PLaMo, update to `b11263` or later rather than patching. This was read from the merged diff, not re-tested here.

**TL;DR**: When llama.cpp loads a model, it builds the list of tokens that end generation partly by matching token *text*: any vocab entry spelled `</s>` (and a handful of other spellings) is added and forced to a control token, even when the model's own vocab marks it `NORMAL`. In PLaMo-2 and PLaMo-3, `</s>` is exactly that, a normal token for the closing HTML strikethrough tag, sitting in the vocab next to `<p>`, `<s>` and `</p>`, and plain text `</s>` tokenizes to it. On llama.cpp master (`fc07d78`, 2026-09-29) with PLaMo-3 610M instruct, asking for `<p>Price: <s>100</s> 80</p>` produced a response that ended at `<s>100`, with `finish_reason: "stop"` and HTTP 200. The same happened in Japanese. `<del>100</del>` went through. The raw next token was 48202, `</s>`, with `stop_type: "eos"`. The one-line fix in the open [ggml-org/llama.cpp#29580](https://github.com/ggml-org/llama.cpp/pull/29580) removed 48202 from the list and the same prompts ran to their length limit. The load log does flag the token, as "probably a bug in the model". The toolkit's `check-eog-text-tokens.sh` finds end tokens that plain text can produce, against your own build. Upstream report: [ggml-org/llama.cpp#29577](https://github.com/ggml-org/llama.cpp/issues/29577).

## The symptom

Debian 13 LXC, CPU only, llama.cpp master `fc07d78` built from source, and [`pfnet/plamo-3-610m-fin-instruct`](https://huggingface.co/pfnet/plamo-3-610m-fin-instruct) as the Q8_0 GGUF from `mradermacher/plamo-3-610m-fin-instruct-GGUF`. `llama-server -c 4096`, requests to `/v1/chat/completions` at `temperature 0`, `max_tokens 120`:

```
"Output this HTML exactly: <p>Price: <s>100</s> 80</p>"
  finish_reason "stop", 25 tokens
  content: thinkまず、ユーザーの指示を確認します。「Output this HTML exactly: <p>Price: <s>100

"次のHTMLをそのまま出力してください: <p>価格: <s>100円</s> 80円</p>"
  finish_reason "stop", 25 tokens
  content: thinkまず、ユーザーの指示を確認します。「HTMLをそのまま出力してください：<p>価格: <s>100円

"Output this HTML exactly: <p>Price: <del>100</del> 80</p>"
  finish_reason "length", 120 tokens
  content: ... 「Output this HTML exactly: <p>Price: <del>100</del> 80</p>」とあります。...
```

This model starts by restating the instruction, so it writes the tag almost immediately, and the response ends in the middle of the quote. Nothing in it says so. A client that checks `finish_reason` sees a normal completion.

To see which token ended it, the raw `/completion` endpoint, with the text up to the point of failure as the prompt:

```
prompt: "Copy the line exactly.\nInput: <p>Price: <s>100</s> 80</p>\nOutput: <p>Price: <s>100"
-> {"content": "", "tokens": [48202], "stop_type": "eos", "tokens_predicted": 1}
```

The model's next token was 48202, and the server treated it as end-of-sequence and did not print it.

## Why it's easy to miss

The token is ordinary text for this model. PLaMo's tokenizer (`tokenizer.jsonl` on Hugging Face) lists it as:

```
["</s>", -20.0, "NORMAL"]      <- id 48202
["<s>",  -20.0, "NORMAL"]      <- id 48258
```

and `llama-tokenize` on plain text, with special-token parsing off, uses it as one piece among the other HTML tags:

```
"<p>Price: <s>100</s> 80</p>"
 48256 '<p>'  7244 'Price'  58 ':'  32 ' '  48258 '<s>'  49 '1'  48 '0'  48 '0'
 48202 '</s>'  312 ' 8'  48 '0'  48200 '</p>'
```

The real end-of-sequence token is `<|plamo:eos|>`, id 2. PLaMo-2's tokenizer (the 1B was checked) has the same `NORMAL` entry.

The one visible sign is a load-time warning that points at the model:

```
W load: control-looking token:  48202 '</s>' was not control-type; this is probably a bug in the model. its type will be overridden
```

followed by the list the build will use:

```
I print_info: EOG token             = 2 '<|plamo:eos|>'
I print_info: EOG token             = 4 '<|plamo:op|>'
I print_info: EOG token             = 48202 '</s>'
```

Anyone who searches that warning lands on [#21471](https://github.com/ggml-org/llama.cpp/issues/21471), the same failure on Gemma 4, where users quoting it were told "These are not bugs." That answer is right about the warning, which describes the heuristic doing what it was written to do. It doesn't say what the heuristic costs a model where `</s>` is text. Reading the warning as "the model file is broken, find another GGUF" leads nowhere: any conversion of this vocab gets the same override.

## What's really going on

In `src/llama-vocab.cpp`, while loading any vocab, llama.cpp walks the tokens and adds the ones whose text is on a list of end-of-turn spellings: `<|eot_id|>`, `<end_of_turn>`, `<|endoftext|>`, and, with a comment naming the model it was added for,

```cpp
|| t.first == "</s>"      // paddleocr
```

A matched token that isn't already a control token has its type overridden, which is the warning above. The match is on the string. It doesn't check the vocab's own token type or which model family is loading.

When this broke Gemma 4 in April, the fix ([#21492](https://github.com/ggml-org/llama.cpp/pull/21492), "remove `</s>` eog token if gemma4") added a workaround afterwards: if the end-of-generation list also contains `<|tool_response>`, take `</s>` back out. PLaMo has no `<|tool_response>`, so the workaround doesn't fire. One detail makes this harder to follow in the log. The `printing all EOG tokens` list is written *before* that workaround runs. On Gemma 4's vocab it still shows `212 '</s>'`, followed by the line removing it. The `print_info: EOG token` lines further down are the final list.

The open fix for PLaMo, [#29580](https://github.com/ggml-org/llama.cpp/pull/29580), is one line: skip the `</s>` match when the vocab type is PLaMo's. Built from the same commit with only that change:

```
I print_info: EOG token             = 2 '<|plamo:eos|>'
I print_info: EOG token             = 4 '<|plamo:op|>'

"Output this HTML exactly: <p>Price: <s>100</s> 80</p>"
  finish_reason "length"  ... 「Output this HTML exactly: <p>Price: <s>100</s> 80</p>」とあります。...
"次のHTMLをそのまま出力してください: <p>価格: <s>100円</s> 80円</p>"
  finish_reason "length"  ... <p>価格: <s>100円</s> 80円</p>」という内容です。...
```

A maintainer has since asked on the PR for the check to go into the Gemma 4 workaround block instead, keyed on `<|plamo:eos|>`. Either way, the string match stays and the exception is per model.

### Who else

The string match is general, so the question is which other models it catches. It only does harm when plain text tokenizes to the matched token. Gemma 3 also has a `</s>` entry that gets forced into the list, but plain text `</s>` comes out as `</`, `s`, `>` there, so the model has no ordinary way to emit it. All 19 vocabularies that llama.cpp ships for its tokenizer tests (Llama SPM and BPE, Qwen2 and Qwen3.5, Phi-3, Gemma 4, DeepSeek, Command-R, Falcon, GPT-2, StarCoder and others) passed the same check. On this evidence the exposure is PLaMo's, and any future vocab that keeps HTML tags as whole tokens.

## The fix

Build with the #29580 change until a fix is merged. It is one line in `src/llama-vocab.cpp`, the `</s>` entry of the end-of-turn list:

```cpp
|| (t.first == "</s>" && type != LLAMA_VOCAB_TYPE_PLAMO2) // paddleocr; normal in PLaMo2 and PLaMo3
```

Confirm it at load. `</s>` should be gone from the `print_info: EOG token` lines:

```bash
./build/bin/llama-tokenize -m plamo.gguf -p x -lv 4 2>&1 | grep 'print_info: EOG token'
```

If you can't rebuild, the requests themselves are what's left. Treat a `stop` from a PLaMo model as possibly truncated whenever the output could contain `</s>`: HTML strikethrough, and also SSML, where `<s>` marks a sentence. Don't reach for `ignore_eos`. In the server source it puts a minus-infinity bias on every token in the end-of-generation list, which bans the real end token along with `</s>`: the model can no longer stop, and can no longer write the tag either.

## The generalisable habit

`finish_reason: "stop"` means "a token on the stop list was sampled", and the stop list is assembled by the runtime, not declared by the model. When a runtime identifies special tokens by what they look like, a model whose ordinary text looks like that loses the text. The model gets no error, and nothing reaches the client. The checks that catch it are about the list, not the response. Print the final end-of-generation list for your model and build, then ask of each entry whether ordinary output can produce it. That is two commands, and it takes less time than finding out from a half-finished answer.

This is the same class of failure as [llama-cli exiting 0 when it cannot read your file](https://homelabpostmortem.com/2026/09/01/llama-cli-exits-0-when-it-cannot-read-your-file/): the status that should report the problem reports success, so the check has to be on the output itself.

The toolkit's `check-eog-text-tokens.sh` does the checks above with your `llama-tokenize`. It reads the final end-of-generation list, and for every entry the build forced into it by name, it tests whether plain text tokenizes to that token. On this model and build it flags 48202. With #29580 applied, and on Gemma 3 and all 19 bundled vocabularies, it passes.
