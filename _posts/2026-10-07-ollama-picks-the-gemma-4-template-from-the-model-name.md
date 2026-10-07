---
title: "Ollama picks the Gemma 4 prompt template from the model's name, so a copy of gemma4:12b is prompted as an e2b"
date: 2026-10-07
excerpt: "Ollama 0.35.1 resolves RENDERER gemma4 to the small (e2b/e4b) or large (12b and up) template by looking for a size in the model's name, then by parameter count, and the 12B counts as 11.9B. So ollama cp gemma4:12b mygemma, or a Modelfile FROM gemma4:12b saved under your own name, gets the small template, which leaves out the empty thought block when thinking is off. ollama show looks the same either way. On the 12B we measured, the model wrote the missing block itself and the answers barely changed; naming the renderer in the Modelfile fixes it."
devto_title: "Ollama picks the Gemma 4 prompt template from the model's name"
devto_tags: ollama, llm, selfhosted, gemma
---

**TL;DR**: Gemma 4 models in Ollama carry `RENDERER gemma4`, which Ollama 0.35.1 resolves per request to `gemma4-small` (the e2b/e4b template) or `gemma4-large` (12b, 26b, 31b). It decides by looking for `e2b`/`e4b` or `12b`/`26b`/`31b` in the model's name, and if there is none, by parameter count against 12 billion. The 12B counts as 11.9B. So `gemma4:12b` itself gets the large template, but `ollama cp gemma4:12b mygemma`, or a Modelfile `FROM gemma4:12b` with your system prompt saved as `assistant`, gets the small one. The difference is an empty thought block the large template adds when thinking is off. `ollama show` prints the same thing for both. On the 12B Q4_K_M we tested, the model wrote the missing block itself: four extra generated tokens, the same answers on five of six prompts, and the same answer with different formatting on the sixth. If you want the template the model was trained with, put `RENDERER gemma4-large` in the Modelfile. The toolkit's `check-gemma4-renderer.sh` lists which of your models resolve to which. Upstream report: [ollama/ollama#18824](https://github.com/ollama/ollama/issues/18824).

## The symptom

Debian 13 LXC, CPU only, Ollama 0.35.1 (the current release) from the release tarball, `gemma4:12b` from the library (8.0 GB; `ollama show` says 11.9B parameters, `RENDERER gemma4`). The report used a third-party GGUF and the request below: "Hello", `think: false`, `num_predict: 1`, read `prompt_eval_count`. The same weights under different names:

```
gemma4:12b                                        think:false 14   think:true 17
ollama cp gemma4:12b mygemma                      think:false 10   think:true 17
FROM gemma4:12b, saved as assistant               think:false 10   think:true 17
FROM gemma4:12b, saved as assistant-12b           think:false 14   think:true 17
FROM gemma4:12b, saved as assistant:12b           think:false 14   think:true 17
FROM gemma4:12b + RENDERER gemma4-large           think:false 14   think:true 17
FROM gemma4:12b + SYSTEM + num_ctx, as helper     think:false 21   think:true 23
same Modelfile, saved as helper-12b               think:false 25   think:true 23
```

Four tokens go missing whenever the name has no size in it, including on a plain `ollama cp`. With thinking on, every variant gets the same prompt. The report says the official library tag is fine because its name contains `12b`. That is true of the tag, but not of anything derived from it under another name, which is the usual thing to do with a library model once you add a system prompt.

## Why it's easy to miss

Nothing you can look at shows it. `ollama show assistant` and `ollama show gemma4:12b` print the same model block, and `ollama show --modelfile` says `RENDERER gemma4` for both. The resolution happens per request and isn't logged.

It only matters with thinking off. A request without a `think` field, including everything through `/v1/chat/completions`, ran with thinking on for this model, and both templates produced the same prompt there.

And the answers are nearly the same, as below, so a quick look at the output won't show a difference.

## What's really going on

`server/renderer_resolution.go` in 0.35.1:

```go
func resolveGemma4Renderer(m *Model) string {
    ...
    if renderer, ok := gemma4RendererFromName(m.ShortName); ok {
        return renderer
    }
    if renderer, ok := gemma4RendererFromName(m.Name); ok {
        return renderer
    }
    if parameterCount, ok := parseHumanParameterCount(m.Config.ModelType); ok {
        return gemma4RendererForParameterCount(parameterCount)
    }
    return gemma4RendererSmall
}
```

`gemma4RendererFromName` is a substring check: `e2b` or `e4b` gives small, `12b`, `26b` or `31b` gives large. `ShortName` and `Name` are the name you asked for (`n.DisplayShortest()` and `n.String()` in `GetModel`), tag included, so `assistant:12b` counts. A copy or a derived model keeps the base model's config, `RENDERER gemma4` and `model_type` `11.9B` included, under the new name. With no size in the name, the count decides, and `gemma4LargeMinParameterCount` is exactly 12,000,000,000.

The two renderers are the same code with one flag:

```go
case "gemma4", "gemma4-small":
    return &Gemma4Renderer{useImgTags: RenderImgTags}
case "gemma4-large":
    return &Gemma4Renderer{useImgTags: RenderImgTags, emptyBlockOnNothink: true}
```

With `emptyBlockOnNothink`, the generation prompt ends `<|turn>model\n<|channel>thought\n<channel|>` when thinking is off: an empty thought block. The report compared 50 rendered prompts with Google's chat template for the 12B and found the large renderer identical on all 50 and the small one missing this block on all 50. Without it, the prompt stops at `<|turn>model\n`. Those are the four tokens.

## What it does to the answers

The report says it did not measure the effect on outputs. Six prompts, `think: false`, temperature 0, `assistant` (small) against `assistant-12b` (large):

```
17 * 23?                  small eval   8  '391'                 large eval   4  '391'
capital of Australia?     small eval   7  'Canberra'            large eval   3  'Canberra'
bat and ball              small eval 207  '...**$0.05**...'     large eval 205  '...**$0.05**...'
one sentence on autumn    small eval  25  identical             large eval  21
three primes over 50      small eval  34  identical             large eval  30
'good morning' in French  small eval  33  identical             large eval  29
```

Five answers are identical, with four more generated tokens on the small side. The bat-and-ball answer is the same answer with a bolded heading on one side and not the other. To see where the four tokens go, the two prompts, written out by hand as the renderers build them, were sent straight to the llama-server process Ollama runs for the model:

```
small prompt   raw tokens: '<|channel>' 'thought' '\n' '<channel|>' '3' '9' '1'
large prompt   raw tokens: '3' '9' '1'
```

The model writes the empty block itself, and Ollama's Gemma 4 parser removes it before the reply goes out. With a JSON schema in `format` and thinking off, the model can't write the block, since the grammar applies from the first token. The answers still had the same values (`391`, `Canberra`, `0.05`, `53, 59, and 61`, `Bonjour`), with different whitespace, and the bat-and-ball one came back as `"The ball costs $0.05."` instead of `"0.05"`.

So on this model and these prompts, the cost is a few tokens and some formatting drift. That is one quantisation of one size on six prompts, not a quality evaluation. A smaller quantisation, a long multi-turn chat or a different task may react differently to a prompt the model wasn't trained on. The point is that whether it gets that prompt depends on what you named it.

## The fix

Name the renderer in the Modelfile. An explicit `gemma4-large` is used as is, whatever the model is called:

```
FROM helper
RENDERER gemma4-large
PARSER gemma4
```

Re-created that way, `helper` (system prompt and `num_ctx 8192` kept) went from 21 to 25 prompt tokens, the same as `helper-12b`.

Putting `12b` in the name also works, but it is a substring match: a name containing both `e4b` and `12b` resolves to small, because `e2b`/`e4b` is checked first. Setting the renderer doesn't depend on that.

To find affected models, `check-gemma4-renderer.sh` reads `/api/tags` and `/api/show` and applies the same rules without loading anything. On the eight models above it marked `assistant`, `helper` and `mygemma` as resolving to the small template and the others as large, which matches the measured token counts.

## The generalisable habit

When a tool picks behaviour from a name, a copy is a different thing. `ollama cp` and `FROM` look like they produce the same model under another label, and for the weights and the config they do. But anything resolved from the label at request time is decided again for the copy, and the closer the model sits to a threshold, here 11.9B against 12B, the more likely that decision changes. The way to see it is to measure something the decision affects, here the prompt token count, on the original and the copy.

The template also decides [what a Gemma 4 model does with your JSON schema when thinking is on](https://homelabpostmortem.com/2026/10/05/ollama-thinking-model-skips-your-json-schema-when-it-answers-directly/), which is the other side of the same `<|channel>` block.
