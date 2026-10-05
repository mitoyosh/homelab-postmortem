---
title: "On one of Ollama's two chat paths, your JSON schema's keys are re-sorted alphabetically, and the model fills the fields in the wrong order"
date: 2026-10-03
excerpt: "Ollama 0.35 sends models without a usable Go template through a native llama-server chat path that decodes the response schema into a Go map and re-encodes it, which sorts the keys. With OLLAMA_GO_TEMPLATE=false, a schema declaring zeta_colour then alpha_animal came back alpha_animal first, and Gemma 3 1B put the colour in the animal field. The four models tested on default settings kept the declared order. The open fix kept it on the native path too; naming keys so alphabetical order is the intended order works today."
devto_title: "Ollama's native chat path re-sorts your JSON schema keys alphabetically"
devto_tags: ollama, llm, selfhosted, json
---

**TL;DR**: Ollama 0.35 runs chat through one of two paths. Models it renders with a Go `TEMPLATE` hand your `format` / `response_format` schema to llama-server as written. Models on the "native" path go through `llamaServerChatResponseFormat()`, which decodes the schema into a Go `map[string]any` and encodes it again. Go writes map keys in alphabetical order, and llama-server's grammar enforces the order it receives. A model takes the native path when it has no renderer, parser or usable Go template, when its GGUF chat template is preferred over the Go one, or when the server runs with `OLLAMA_GO_TEMPLATE=false`. With that setting, a schema declaring `zeta_colour` then `alpha_animal` came back as `{"alpha_animal": "blue", "zeta_colour": "zebra"}` from Gemma 3 1B: valid against the schema, HTTP 200, and the colour in the animal field. The four models tested on default settings, including two `hf.co` imports, kept the declared order. The open fix, [ollama/ollama#18721](https://github.com/ollama/ollama/pull/18721), kept it on the native path too. Until a release includes it, name keys so their alphabetical order is the order you want. The toolkit's `check-ollama-schema-order.sh` tests each model on your server. Upstream report: [ollama/ollama#18717](https://github.com/ollama/ollama/issues/18717).

## The symptom

Debian 13 LXC, CPU only, Ollama 0.35.1 (the current release) from the release tarball. One schema, whose declared order is the reverse of alphabetical order:

```json
{"type": "object",
 "properties": {"zeta_colour": {"type": "string"}, "alpha_animal": {"type": "string"}},
 "required": ["zeta_colour", "alpha_animal"]}
```

sent with "Name a colour and an animal." at temperature 0, through `/api/chat` (`format`) and `/v1/chat/completions` (`response_format`). Both endpoints gave the same answer wherever both returned one. `qwen3:0.6b` is a thinking model and only reasoned within the token limit on `/v1`, so its line is from `/api/chat` with `think: false`.

On the default server, all four models kept the declared order:

```
plain (FROM gemma-3-1b-it-Q4_K_M.gguf)          {"zeta_colour": "blue", "alpha_animal": "zebra"}
hf.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF      { "zeta_colour": "blue", "alpha_animal": "lion" }
hf.co/LiquidAI/LFM2-350M-GGUF                   {"zeta_colour": "red", "alpha_animal": "lion"}
qwen3:0.6b (library)                            { "zeta_colour": "green", "alpha_animal": "lion" }
```

The same server restarted with `OLLAMA_GO_TEMPLATE=false`:

```
plain (FROM gemma-3-1b-it-Q4_K_M.gguf)          { "alpha_animal" : "blue", "zeta_colour" : "zebra" }
hf.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF      { "alpha_animal": "red", "zeta_colour": "red" }
hf.co/LiquidAI/LFM2-350M-GGUF                   {   "alpha_animal": "Blue",   "zeta_colour": "Blue" }
```

The keys are in alphabetical order, and Gemma's answers are in the wrong fields. The model was answering "a colour and an animal" in the order the question asked, while the grammar made it fill in `alpha_animal` first. So "blue" went into the animal field and "zebra" into the colour field. The JSON is valid against the schema, nothing reports an error, and a client that reads fields by name gets wrong data.

The report itself came from 0.35.0 with a local model created `FROM` another, and says 0.33.2 behaved the same way.

## Why it's easy to miss

Most of the time it doesn't happen. All four models above took the other path on a default install, including two pulled straight from Hugging Face. So the usual test, sending a schema and looking at the output, comes back clean, and the bug only shows up for a particular model or server setting.

When it does happen, nothing looks wrong. JSON objects are unordered as far as most parsers care, and every field is present and valid. The cost is in what the order was for. A common structured-output pattern declares `reasoning` before `answer` so the model works something out before it commits to an answer. Sorted alphabetically, `answer` comes first. The request and the response both look normal, and the only symptom is worse answers. The swapped fields above are the visible version of the same thing.

It is also a regression of something fixed before. In December 2024, [#8002](https://github.com/ollama/ollama/pull/8002) ("preserve field order in user-defined JSON schemas") closed the same complaint. The llama-server runner brought back the step that loses the order.

## What's really going on

`llm/llama_server.go` in 0.35.1 builds the native chat request's `response_format` like this:

```go
func llamaServerChatResponseFormat(format json.RawMessage) (map[string]any, error) {
    ...
        var schema map[string]any
        if err := json.Unmarshal(format, &schema); err != nil { ... }
        return map[string]any{
            "type": "json_schema",
            "json_schema": map[string]any{ ..., "schema": schema },
        }, nil
```

Unmarshalling into a `map[string]any` throws the order away, and `encoding/json` writes map keys sorted. The same function and the same `var schema map[string]any` are in v0.30.0 (released 2026-05-13) and v0.32.0. The other path, used for models with a Go template, keeps the schema as `json.RawMessage` (`lsReq.JsonSchema = req.Format`) and passes it on unchanged.

Which path a model takes is decided in `server/routes.go`:

```go
func chatModeForModel(m *Model) chatExecutionMode {
    if m.IsMLX() || usesOllamaRenderedChat(m) {
        return chatExecutionModeRendered
    }
    return chatExecutionModeNative
}
```

`usesOllamaRenderedChat` is true when the model has a renderer, a parser or the harmony format, or when `shouldUseGoTemplate` is true. That in turn is true when the model has a Go template, `OLLAMA_GO_TEMPLATE` is not false, and Ollama hasn't decided to prefer the GGUF's own chat template. It prefers that template when the GGUF template supports more than the Go one, tool calling for example. `ollama create` from a bare GGUF and the `hf.co` pulls tested here all came with a Go template, which is why they kept the order. That leaves three ways onto the native path: a model with no Go template at all, a model whose GGUF template wins, and a server running with `OLLAMA_GO_TEMPLATE=false`. Only the last was reproduced here.

The open fix, [#18721](https://github.com/ollama/ollama/pull/18721), passes the trimmed raw bytes through as `json.RawMessage` instead of the decoded map. Built from 0.35.1 with that change, on the same `OLLAMA_GO_TEMPLATE=false` server:

```
plain (FROM gemma-3-1b-it-Q4_K_M.gguf)          { "zeta_colour": "blue", "alpha_animal": "dolphin"}
hf.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF      { "zeta_colour": "Blue", "alpha_animal": "Bluebird" }
```

The declared order is back, and Gemma's colour and animal are in the right fields.

## The fix

Until a release includes #18721, make the order you want and alphabetical order the same, and declare the keys in that order too. That way both paths produce it:

```json
{"type": "object",
 "properties": {"a_colour": {"type": "string"}, "b_animal": {"type": "string"}},
 "required": ["a_colour", "b_animal"]}
```

On the stock native path that gave `{"a_colour": "blue", "b_animal": "lion"}` from Gemma and `{"a_colour": "Red", "b_animal": "Red fox"}` from Qwen2.5. For the reasoning pattern that means `a_reasoning`, `b_answer`, and so on.

To find out whether a model is affected, send it a two-key schema in reverse-alphabetical order and see which key comes out first. That takes one request and doesn't depend on reading Ollama's routing rules correctly. If you have set `OLLAMA_GO_TEMPLATE=false`, assume every model without a renderer is affected.

## The generalisable habit

When a layer sits between your client and the engine, check whether it passes your request through or rebuilds it. A layer that decodes a structure into its own types and encodes it again keeps only what those types can represent. Here a Go map can't represent key order, so the order was gone before llama-server saw the schema. The test for that is a request that only means something if a property survives the trip: two keys declared in reverse alphabetical order, compared against the output.

This is the second time in a week that Ollama's translation into llama-server rewrote part of a request without saying so. The [OpenAI-compatible API fills in temperature and top_p as 1.0](https://homelabpostmortem.com/2026/09/29/ollama-openai-api-replaces-your-model-temperature-with-1/) when the client leaves them out. Both times the reply was valid and well formed.

A third turned up two days later: with `think` enabled, [a model that answers without thinking isn't held to the schema at all](https://homelabpostmortem.com/2026/10/05/ollama-thinking-model-skips-your-json-schema-when-it-answers-directly/).

The toolkit's `check-ollama-schema-order.sh` sends that two-key schema to each installed model, or the ones you name, and reports which kept the order. It also reads `OLLAMA_GO_TEMPLATE` from the running server's environment.
