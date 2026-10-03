---
title: "Ollama's OpenAI-compatible API replaces your model's temperature and top_p with 1.0. `ollama show` keeps printing the model's values."
date: 2026-09-29
excerpt: "A request to /v1/chat/completions that doesn't set temperature or top_p gets 1.0 for both, and that overrides the model's PARAMETER lines. qwen3:0.6b ships temperature 0.6 and top_p 0.95; llama-server ran it at 0.600/0.950 through /api/chat and at 1.000/1.000 through /v1. A Modelfile with temperature 0 gave one output across five seeds on /api/chat and five different outputs on /v1. /v1/completions also zeroes presence and frequency penalties. The three open fix PRs leave the /v1/completions temperature fallback in place."
devto_title: "Ollama's /v1 API replaces your model's temperature and top_p with 1.0 unless the client sends them"
devto_tags: ollama, llm, selfhosted, openai
---

**Update 2026-09-30.** Ollama v0.35.0 (released 2026-09-28) does not change this. Its `openai/openai.go` still sets `temperature` and `top_p` to 1.0 when a request leaves them out, in both the chat and the completions path, and still sends both penalties unconditionally on `/v1/completions`. All three fix PRs are still open. This was read from the v0.35.0 tag, not re-measured.

**TL;DR**: When a request to Ollama's OpenAI-compatible `/v1/chat/completions` or `/v1/completions` leaves out `temperature` or `top_p`, Ollama fills in `1.0` for each, and request values override the model's own `PARAMETER` lines. `ollama show --parameters` keeps printing the model's values. Many library models ship them: `qwen3:0.6b` has `temperature 0.6` and `top_p 0.95`, and with `OLLAMA_DEBUG=1` llama-server's own log showed it sampling at `temp = 0.600, top_p = 0.950` through `/api/chat` and `temp = 1.000, top_p = 1.000` through `/v1`. A Modelfile with `PARAMETER temperature 0` gave the same output for five different seeds through `/api/chat` and five different outputs through `/v1`. `/v1/completions` also sends `presence_penalty` and `frequency_penalty` as 0 every time. The behaviour has been in the code since v0.3.0 (July 2024) and is in 0.34.4. The most recent report says the temperature half is already fixed; the PR it cites is open, and between them the three open fix PRs leave the `/v1/completions` temperature fallback where it is. Send the values from the client, or use `/api/chat`. The toolkit's `check-ollama-v1-sampling.sh` lists the models at risk and can measure it on your server. Upstream: [ollama/ollama#17744](https://github.com/ollama/ollama/issues/17744), [#18690](https://github.com/ollama/ollama/issues/18690).

## The symptom

Debian 13 LXC, 6 cores, no GPU, Ollama 0.34.4 from the release tarball, `qwen2.5:0.5b` and three models built on it with one Modelfile each:

```
t0   PARAMETER temperature 0
tp   PARAMETER temperature 1   PARAMETER top_p 0.01
pp   PARAMETER presence_penalty 1.5   PARAMETER frequency_penalty 1.5
```

`ollama show --parameters t0` prints `temperature 0`. Then the same prompt ("Write a two-line poem about rain.") five times with seeds 1 to 5, counting distinct outputs:

```
t0  /api/chat                               distinct=1
t0  /v1/chat/completions (no temperature)   distinct=5
t0  /v1/chat/completions "temperature": 0   distinct=1

tp  /api/chat                               distinct=1
tp  /v1/chat/completions (no top_p)         distinct=5
tp  /v1/chat/completions "top_p": 0.01      distinct=1

qwen2.5:0.5b, no parameters, /api/chat      distinct=5   <- what temperature > 0 looks like
```

A model you set to deterministic is deterministic through Ollama's native API and random through the OpenAI one. Sending the value in the request brings it back.

That makes the effect visible, not the mechanism. Ollama's debug log does show the mechanism. With `OLLAMA_DEBUG=1`, the llama-server runner prints the sampler settings it was actually given for each request:

```
                                    temp    top_p   presence  frequency
t0          /api/chat               0.000   0.900   0.000     0.000
t0          /v1/chat/completions    1.000   1.000   0.000     0.000
tp          /api/chat               1.000   0.010   0.000     0.000
tp          /v1/chat/completions    1.000   1.000   0.000     0.000
pp          /api/generate           0.800   0.900   1.500     1.500
pp          /v1/chat/completions    1.000   1.000   1.500     1.500
pp          /v1/completions         1.000   1.000   0.000     0.000
```

The penalties show up in the output too. At `temperature 0` with the prompt "Repeat the word apple twenty times", `pp` through `/api/generate` degrades into `AppleappleAPPLEAPEAPPLE...` after five words, as a 1.5 penalty should make it. Through `/v1/completions` it prints twenty clean `apple`s, the same as the model without penalties. Sending `"presence_penalty": 1.5, "frequency_penalty": 1.5` in the request brings the degradation back.

### It is not only your own Modelfiles

The same parameters come with library models. Their registry manifests (read on 2026-09-29) carry:

```
qwen3:8b          temperature 0.6   top_p 0.95   top_k 20
qwen3.5:9b        temperature 1     top_p 0.95   top_k 20   presence_penalty 1.5
qwen3-coder:30b   temperature 0.7   top_p 0.8    top_k 20
deepseek-r1:8b    temperature 0.6   top_p 0.95
magistral:24b     temperature 0.7   top_p 0.95
gemma3:4b         temperature 1     top_p 0.95   top_k 64
gemma4:e4b        temperature 1     top_p 0.95   top_k 64
gpt-oss:20b       temperature 1
llama3.1:8b, llama3.2:3b, mistral:7b, phi4:14b   (none)
```

These are the values the model publishers recommend. `qwen3:0.6b` has the same parameters as `qwen3:8b`, so it was pulled into the same container:

```
ollama show --parameters qwen3:0.6b   temperature 0.6  top_p 0.95  top_k 20
/api/chat                             temp = 0.600  top_p = 0.950  top_k = 20
/v1/chat/completions                  temp = 1.000  top_p = 1.000  top_k = 20
/v1/chat/completions + both values    temp = 0.600  top_p = 0.950  top_k = 20
```

`top_k` survives. Only the fields with a fallback are replaced. Anyone pointing an OpenAI SDK, an agent framework or an editor extension at Ollama without setting `temperature` gets Qwen3 and DeepSeek-R1 at 1.0/1.0 instead of the recommended 0.6/0.95, and nothing in Ollama's output says so.

## Why it's easy to miss

Nothing fails. The output is fluent at either temperature, and a single response gives no way to tell which settings produced it. The one place a user would check, `ollama show --parameters`, prints the model's values, which are exactly the ones not in use.

The documentation doesn't close the gap. Ollama's OpenAI-compatibility page does not say what happens to a field a request leaves out, or how a Modelfile's parameters interact with `/v1`. The natural reading of "configure the model, point the client at it" is that the model's configuration applies. For `top_k`, `min_p` and `repeat_penalty` it does, which makes the two fields where it doesn't harder to suspect.

The issue tracker is misleading too. [#17744](https://github.com/ollama/ollama/issues/17744) (temperature, opened 2026-08-14) is open with no maintainer response, and so is its fix, [#17763](https://github.com/ollama/ollama/pull/17763). The newest report, [#18690](https://github.com/ollama/ollama/issues/18690) (top_p, 2026-09-28), describes it as "the same bug class as #17744 (`temperature`), fixed by #17763 — that PR removed only the temperature fallback". Someone reading #18690 today comes away thinking temperature is already fixed. It is not merged, and 0.34.4 has the fallback.

## What's really going on

`openai/openai.go` translates an OpenAI request into Ollama's native one. In 0.34.4, the chat path (`FromChatRequest`):

```go
if r.Temperature != nil {
    options["temperature"] = *r.Temperature
} else {
    options["temperature"] = 1.0
}
...
if r.TopP != nil {
    options["top_p"] = *r.TopP
} else {
    options["top_p"] = 1.0
}
```

The completions path (`FromCompleteRequest`) has the same two fallbacks, and also:

```go
options["frequency_penalty"] = r.FrequencyPenalty
options["presence_penalty"] = r.PresencePenalty
```

unconditionally, where both fields are plain `float32` and so 0 when absent. The chat path only sets the penalties when the request has them, which is why `pp` kept its penalties on `/v1/chat/completions`.

From there it is an ordinary native request, and a request option beats a model parameter, as it should on `/api/chat`. The translation layer has made "the client didn't say" into "the client said 1.0". The same fallbacks are in the v0.3.0 source from July 2024, where `temperature` was additionally multiplied by 2.

To check that these lines are the whole story, the four fallbacks were removed from the 0.34.4 source (the two `else` branches in each function, and the penalties made conditional) and the server rebuilt. Same container, same models, same requests:

```
                                    temp    top_p   presence  frequency
t0          /v1/chat/completions    0.000   0.900   0.000     0.000
tp          /v1/chat/completions    1.000   0.010   0.000     0.000
pp          /v1/completions         0.800   0.900   1.500     1.500
qwen3:0.6b  /v1/chat/completions    0.600   0.950   0.000     0.000
qwen3:0.6b  /v1/completions         0.600   0.950   0.000     0.000
qwen2.5:0.5b /v1/chat (no params)   0.800   0.900   0.000     0.000
```

Every model got its own values. The last line is the one behaviour change a fix brings: a model with no parameters now gets Ollama's defaults (0.8/0.9) through `/v1` instead of OpenAI's (1.0/1.0), the same as it always did through `/api/chat`.

### What the open fixes cover

Three PRs are open, all unreviewed:

- [#17763](https://github.com/ollama/ollama/pull/17763) removes the `temperature` fallback in the chat path.
- [#18691](https://github.com/ollama/ollama/pull/18691) removes the `top_p` fallback in the chat path.
- [#18694](https://github.com/ollama/ollama/pull/18694) makes `top_p` and both penalties optional in the completions path.

Read together, none of them touches `options["temperature"] = 1.0` in `FromCompleteRequest`. If all three merge as they stand, `/v1/completions` will still replace a model's temperature. That is from reading the diffs, not from building them.

## The fix

Until a release changes this, the model's parameters only apply through `/v1` if the client sends them. Read them with `ollama show --parameters <model>` and put `temperature` and `top_p` in the client's configuration or in each request. With the OpenAI Python SDK:

```python
client.chat.completions.create(
    model="qwen3:8b",
    messages=messages,
    temperature=0.6,   # from `ollama show --parameters qwen3:8b`
    top_p=0.95,
)
```

For `/v1/completions`, also send `presence_penalty` and `frequency_penalty` if the model has them (`qwen3.5` ships `presence_penalty 1.5`).

If the client cannot send them, the other option is Ollama's native `/api/chat`, which honours the model's parameters. A client that sends its own `temperature` on every request is a different case: there the Modelfile value was never going to apply, and it is the client's setting to change.

Check the one number that matters. Start the server with `OLLAMA_DEBUG=1`, send a request the way your client does, and read the `sampler params` block the runner logs for it:

```
slot launch_slot_: id  0 | task -1 | sampler params:
        repeat_last_n = 64, repeat_penalty = 1.000, frequency_penalty = 0.000, presence_penalty = 0.000
        top_k = 20, top_p = 1.000, min_p = 0.000, ... temp = 1.000
```

## The generalisable habit

`ollama show --parameters` answers "what did the model author configure", and it gets read as the answer to "what will my requests use". The two only coincide on one of Ollama's two APIs. When a layer translates one protocol into another, the question is what it does with a field the caller left out. "Absent" and "set to the protocol's default" are different requests, and a translation layer can quietly turn one into the other. The way to find out is to read the values at the component that uses them, here llama-server's sampler log, rather than the configuration that should have produced them.

It is the same gap as [the day before](https://homelabpostmortem.com/2026/09/28/ollama-gpu-overhead-is-logged-but-never-reaches-llama-server/), in the same program: Ollama printed a VRAM reservation in its log that never reached the runner. In both cases, the value on display is the configured one and the value in effect is somewhere else. Four days later the same translation layer turned up again, rewriting the schema instead of the sampling: [on Ollama's native chat path a JSON schema's keys are re-sorted alphabetically](https://homelabpostmortem.com/2026/10/03/ollama-native-chat-path-sorts-your-json-schema-keys/), and the model fills the fields in that order.

The toolkit's `check-ollama-v1-sampling.sh` lists the installed models whose `temperature`, `top_p` or penalties `/v1` would replace. With `--probe <model>` it measures this server: at two seeds, it sends the same `/v1` request with the model's values twice (to confirm the server is deterministic per seed) and once without them. On 0.34.4 all three probed models came back `OVERRIDDEN`, and on the rebuilt server `HONOURED`, so it will tell you when an upgrade has fixed it.
