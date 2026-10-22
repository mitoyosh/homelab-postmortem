---
title: "llama-server's Responses API reports a reply cut off by max_output_tokens as completed, including a tool call with half its arguments"
date: 2026-10-20
excerpt: "On llama.cpp b11753, /v1/responses returned status completed with no incomplete_details for a reply that stopped at its 8-token limit mid-sentence, and for a tool call whose arguments were cut off at '{\"path\": \"/'. The same requests on /v1/chat/completions said finish_reason length. A Responses client has nothing in the reply that says it was truncated, except usage.output_tokens equalling the limit."
devto_title: "llama-server's Responses API marks truncated replies and tool calls as completed"
devto_tags: llm, selfhosted, ai, api
---

**TL;DR**: llama-server's OpenAI-compatible `/v1/responses` endpoint never reports a reply as cut off. On llama.cpp b11753, a request with `max_output_tokens: 8` came back with `"status": "completed"`, `incomplete_details: null` and the text `1 2 3 4 `, stopped mid-count. A tool call cut off by the limit came back as a `function_call` item with arguments `{"path": "/`, which is not valid JSON, and both the item and the response said `completed`. The streaming version ended with `response.completed` and never sent `function_call_arguments.done`. The same requests on `/v1/chat/completions` said `finish_reason: "length"`. A client that trusts `status`, which is how the Responses API is meant to be used, will treat half an answer as a whole one, or run a tool with broken arguments. The one signal left is `usage.output_tokens` equal to the limit you sent. Upstream: [ggml-org/llama.cpp#30773](https://github.com/ggml-org/llama.cpp/issues/30773).

## The symptom

A disposable LXC container, the b11753 release binary, `gemma-3-1b-it-Q4_K_M` and `Qwen3-0.6B-Q8_0`, `--jinja -c 4096`. A request that can't finish within its limit:

```
POST /v1/responses
{"model": "x", "input": "Count from 1 to 200, separated by spaces.", "max_output_tokens": 8}

{"status": "completed", "incomplete_details": null, "output_tokens": 8, "text": ["1 2 3 4 "]}
```

The same question with room to finish used 52 tokens and also said `completed`, so `status` is the same whether the reply ended or was cut. On the chat endpoint:

```
POST /v1/chat/completions   ... "max_tokens": 8
finish_reason= length completion_tokens= 8
```

With streaming, the last events of the 8-token request were:

```
response.content_part.done, response.output_item.done, response.completed status=completed incomplete_details=None
```

There is no `response.incomplete` event.

A tool call is where it matters most. One tool, `write_file(path, content)`, Qwen3-0.6B, `temperature: 0`, and `/no_think` in the prompt so the model calls the tool straight away:

```
responses limit=20:  status=completed usage.output_tokens=20 args='{"path": "/'
chat      limit=20:  finish_reason=length completion_tokens=20 tool_calls=[('write_file', '{"path": "/')]
responses limit=400: status=completed usage.output_tokens=89 args='{"path": "/tmp/poem.txt", "content": "Th...'
chat      limit=400: finish_reason=tool_calls completion_tokens=89
```

At a 20-token limit the Responses API returned a `function_call` item marked `completed` whose arguments end after `{"path": "/`. At 30 they ended after `"content": "`. Both endpoints produced the same truncated arguments; only the chat endpoint said so. In the stream there were five `response.function_call_arguments.delta` events, then `response.output_item.done` and `response.completed`. No `response.function_call_arguments.done`, and that event was also missing from a call that completed normally.

## Why it's easy to miss

Short limits are rare in interactive use, so most replies really are complete, and `completed` is the right answer most of the time. The ones that aren't are the long ones: a big file write, a long code edit, a model that thinks for a while first. Those are exactly the replies where an agent is about to do something with the output.

The model also isn't wrong. The text is what the model generated, and in the tool-call case the arguments are a correct prefix of a correct call. Nothing errors until the client tries to parse the arguments, and a lenient JSON parser or a retry loop can hide even that. When the call does fail, it looks like the model produced bad JSON, which small models are known for.

And the chat endpoint is fine. Anyone who checked `finish_reason` on `/v1/chat/completions` has seen `length` work. The Responses API is newer, it's what Codex CLI and other recent agent tools speak, and the only thing llama-server's README says about how it works is that it "works by converting Responses request into Chat Completions request."

## What's really going on

The conversion is only one way. The request is turned into a chat completion and generated normally, and the server knows the reply stopped at the limit, because the chat endpoint reports `length` from the same generation. When the result is turned back into a Responses object, in `tools/server/server-task.cpp`, the response `status` and the `status` of every output item (message, reasoning, function call) are written as the literal string `"completed"`. At the b11753 tag that is seven `{"status", "completed"}` entries across `to_json_oaicompat_resp()` and `to_json_oaicompat_resp_stream()`, the non-streaming and streaming builders. Neither reads the stop reason, and the string `incomplete` does not appear anywhere in the file. The Responses specification has `status: "incomplete"` with `incomplete_details.reason: "max_output_tokens"` for exactly this case; llama-server never produces it.

## The fix

There's no fix upstream yet; the issue has no replies or PR as of 20 October. On the client side:

- **Treat `usage.output_tokens == max_output_tokens` as cut off.** In every truncated reply here it was exactly the limit (8 of 8, 20 of 20), and in every complete one it was lower (52 of 400, 89 of 400). It's a heuristic: a reply that ends naturally on its last allowed token would look the same, which errs on the safe side.
- **Validate tool-call arguments before running anything.** A `function_call` whose arguments don't parse as JSON was cut off, whatever its status says.
- **Use `/v1/chat/completions` if your client can.** `finish_reason: "length"` is reported correctly there, for text and for tool calls.
- **Give agent requests a generous limit**, so the truncation case is rare in the first place.

The toolkit's `check-llama-responses-status.sh` sends one 8-token request to `/v1/responses` and one to `/v1/chat/completions`, and compares:

```
  /v1/responses        max_output_tokens=8: status='completed' incomplete_details=None output_tokens=8
  /v1/chat/completions max_tokens=8:        finish_reason='length'

http://127.0.0.1:18090: a reply cut off at max_output_tokens is reported as 'completed'.
```

It exits 1 there, 0 when a cut-off reply is reported as `incomplete`, and 2 when it can't tell.

## The generalisable habit

A status field is only useful if something can make it say no. When you rely on one, find out whether the implementation has a code path that ever produces a value other than success, and test the failure case on purpose: set a limit too small for the answer and look at what comes back. A field that is hard-coded to `completed` passes every test that only checks successful replies.

And when an API is implemented by translating to another one, check that the translation carries the failure signals back, not just the content. Here the information existed one layer down, in the chat endpoint's `finish_reason`, and was dropped on the way out.

This is the second place this month where llama-server's compatibility layers lose something on the way through: its Anthropic endpoint [ignores which tool you ask for and stops inside the model's reasoning](https://homelabpostmortem.com/2026/10/18/llama-server-anthropic-endpoint-ignores-tool-choice-and-stops-inside-reasoning/).

Ollama loses tool calls in a different way: [a call to a tool name that isn't in `tools` is dropped](https://homelabpostmortem.com/2026/10/22/ollama-drops-a-tool-call-to-a-name-not-in-tools/), and the reply comes back empty.
