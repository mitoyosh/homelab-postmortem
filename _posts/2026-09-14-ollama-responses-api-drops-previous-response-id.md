---
title: "Ollama's Responses API accepts previous_response_id, returns 200 and \"completed\", and starts every turn from nothing."
date: 2026-09-14
excerpt: "Plant a secret word in turn 1, ask for it in turn 2 with previous_response_id, and the model guesses. The request costs exactly as many input tokens as a request with no history at all — 41 and 41 — while sending the full conversation costs 68 and gets the word right. The request struct in Ollama has no such field; the decoder drops it; every response carries previous_response_id: null with a source comment reading 'Not supported'. Codex-style tool loops that depend on it get a stateless conversation and no error."
devto_title: "Ollama's Responses API accepts previous_response_id, returns 200, and forgets the whole conversation"
devto_tags: ollama, llm, ai, devops
---

**TL;DR**: send `previous_response_id` to Ollama's `/v1/responses` and it is accepted, the reply is HTTP 200 with `"status": "completed"` and `"error": null`, and the model has never seen the previous turn. A request that carries `previous_response_id` costs the same number of input tokens as a request that carries no history — 41 and 41 on this box — and produces the same kind of answer. Sending the full history instead costs 68 and works. The reason is in the source: the request struct has no `previous_response_id` field, so the JSON decoder throws it away, and the response struct sets it to `nil` with the comment `// Not supported`. The bug report that led here, an empty completion from a hosted model after a tool call, is what a bare `function_call_output` with no context looks like when the backend has nothing to say about it.

## The symptom

Ollama 0.34.0, Debian 13, CPU only, `qwen2.5:1.5b`. The Responses API, which is the OpenAI-compatible endpoint Codex and similar clients use. Turn 1 plants something the model could not guess:

```
POST /v1/responses
{"model": "qwen2.5:1.5b",
 "input": "My secret word is PINEAPPLE. Remember it. Reply with just OK."}

→ 200  status: completed   input_tokens: 45   "OK"
```

Turn 2 continues the conversation the way the API is documented to work, by referencing the previous response:

```
{"model": "qwen2.5:1.5b",
 "previous_response_id": "resp_578667",
 "input": "What is my secret word? Reply with just the word."}

→ 200  status: completed   error: null   input_tokens: 41   "password"
```

`password`. Now two controls. The same question with the full history sent in the request body:

```
input: [user: "My secret word is PINEAPPLE…", assistant: "OK", user: "What is my secret word?…"]

→ 200   input_tokens: 68   "PINEAPPLE"
```

And the same question with no history at all, just the bare turn-2 text:

```
input: "What is my secret word? Reply with just the word."

→ 200   input_tokens: 41   "password"
```

The `previous_response_id` request and the no-history request cost the same 41 input tokens and produce the same guess. The model was shown the same thing both times: nothing but the question.

The same holds through `/api/codex/v1/responses`, the proxy path that `ollama launch codex` sets up for Codex Desktop. 41 tokens, a guess (`Qwen`, this time), `completed`.

## Why this is easy to miss

Nothing fails. The response is not an error, not `incomplete`, not empty. It is a well-formed completed response with a plausible answer in it. A conversation client that sends `previous_response_id` gets a reply to every turn; the replies are just to a different conversation than the one it thinks it is having — one that starts fresh every time.

With a tool-calling loop the shape is worse and more specific. Turn 1: the model emits a `function_call`. The client runs the tool and sends back only what the protocol says to send back — `previous_response_id` plus a `function_call_output`:

```
turn 1   "Call the check tool once, then reply exactly DONE."   → function_call    input_tokens 144
turn 2   previous_response_id + function_call_output "test passed"
         → 200  completed  "The test passed successfully! Is there anything
           else you need help with?"                              input_tokens 144
control  full history, no previous_response_id
         → 200  completed  "DONE"                                 input_tokens 179
```

The turn-2 reply is friendly, on-topic, and wrong: the instruction was to say `DONE`, and the model never saw it. It saw a tool result arrive from nowhere and did its best. That is the local-model version. The [upstream report](https://github.com/ollama/ollama/issues/18419) that started this used a hosted `:cloud` model through the same Codex proxy and got, for the same bare `function_call_output`, an empty `output_text` with `input_tokens: 0` — which Codex Desktop then read as a cleanly finished turn. **That exact symptom did not reproduce here with a local model**, and I did not test a hosted one. What did reproduce is the thing underneath it: the context is gone, and what the backend does with a context-free tool result is up to the backend.

## What is really going on

`openai/responses.go`, Ollama 0.34.0. The request type:

```go
type ResponsesRequest struct {
    Model        string
    Input        json.RawMessage
    Instructions *string
    Tools        []ResponsesTool
    ...
    // no PreviousResponseID field
}
```

Go's `encoding/json` ignores keys that have no matching field unless `DisallowUnknownFields` is set. It is not set. `previous_response_id` is discarded at decode, before any handler sees it.

The response type, on the other hand, does know the field exists:

```go
PreviousResponseID *string `json:"previous_response_id"`
...
PreviousResponseID: nil, // Not supported
```

So every response carries `"previous_response_id": null`. That is the one honest signal in the whole exchange, and it is a field no client reads back — OpenAI's implementation echoes the id you sent, so there is nothing to check. The feature request to implement it, [`ollama/ollama#15954`](https://github.com/ollama/ollama/issues/15954), has been open since May.

A note on the Codex path, because it is easy to get wrong. `/api/codex/v1/responses` is not a separate implementation. It is a router: a request whose model appears in `~/.codex/ollama-launch-codex-routing.json` is forwarded to Ollama's own `/v1/responses`; any other model is forwarded to OpenAI. On a fresh install with no routing file the endpoint answers `503 read Codex Ollama model catalog … no such file`, which is not the bug, it is just `ollama launch codex` not having run. Write a one-line catalog by hand and the proxy routes a local model exactly as it would a hosted one — and drops `previous_response_id` exactly the same way, because the drop happens downstream.

## The fix

Nothing in Ollama restores the state, so the client has to stop expecting it to. Send the full conversation on every turn:

```json
{"model": "qwen2.5:1.5b",
 "input": [
   {"role": "user", "content": "…turn 1…"},
   {"role": "assistant", "content": "…turn 1 reply…"},
   {"type": "function_call", "call_id": "call_x", "name": "check", "arguments": "{}"},
   {"type": "function_call_output", "call_id": "call_x", "output": "test passed"}
 ]}
```

That is the 68-token / 179-token control above, and it works on both paths. Most OpenAI-compatible clients already do this; the ones that do not are the ones built against the Responses API's stateful mode — Codex being the prominent case, which is why the upstream report came from Codex Desktop.

**Check before you trust a Responses server with state.** It takes four requests:

```python
import json, secrets, urllib.request
URL, MODEL = "http://127.0.0.1:11434/v1/responses", "qwen2.5:1.5b"
def post(b):
    r = urllib.request.Request(URL, data=json.dumps(b).encode(), headers={"content-type":"application/json"})
    return json.load(urllib.request.urlopen(r))
def text(d): return " ".join(c["text"] for o in d["output"] if o["type"]=="message" for c in o["content"])
word = "".join(secrets.choice("BCDFGHJKLMNPQRSTVWXZ") for _ in range(7))
plant, ask = f"My secret word is {word}. Reply with just OK.", "What is my secret word? Reply with just the word."
r1 = post({"model": MODEL, "input": plant, "stream": False})
r2 = post({"model": MODEL, "previous_response_id": r1["id"], "input": ask, "stream": False})
r4 = post({"model": MODEL, "input": ask, "stream": False})
print(word, "| via id:", r2["usage"]["input_tokens"], repr(text(r2)), "| no history:", r4["usage"]["input_tokens"], repr(text(r4)))
```

```
LNLPFVF | via id: 41 'Unlimited possibilities' | no history: 41 'Password'
```

If the id-referencing request costs the same as the bare one and does not know the word, the server is not keeping state, whatever the status field says. The toolkit's `check-responses-state.sh` runs this with a full-history control as well, so a model too small to remember the word is reported as unknown rather than as a pass or a fail.

## The generalisable habit

The narrow one: **a status of `completed` describes the request the server processed, which may not be the request you sent.** Here the server processed "what is my secret word?" and completed it perfectly. The `previous_response_id` was not rejected, not warned about, not `incomplete_details`-ed. It was not there by the time anything could have complained.

The wider one is about controls that cost nothing. The token count did all the work in this diagnosis. Two requests that should have carried different amounts of context cost the same, and one that should have carried the same as the first cost more. That number is in every response, it is exact, and it does not depend on interpreting model output. When a stateful API might be stateless, count the tokens before reading the words. It is the same move as [holding the prompt fixed and removing the constraint to see whether the bytes change](https://homelabpostmortem.com/2026/09/12/llama-server-ignores-the-response-format-its-readme-shows/): find the one number that has to move if the feature is real, and watch whether it moves.
