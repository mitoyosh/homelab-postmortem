---
title: "Ollama drops a tool call to a name that isn't in tools, and returns an empty reply with an eval_count"
date: 2026-10-22
excerpt: "On Ollama 0.40.8 with qwen3:0.6b, a system prompt that tells the model to call lookup_order, with only get_time in tools, gave 8 of 8 replies with no content and no tool_calls, each with eval_count 25. The raw generation for the same prompt was a well-formed tool call to lookup_order, 25 tokens. With lookup_order listed, 8 of 8 replies were the call. Ollama's generic tool parser keeps unmatched calls in its buffer and never returns them."
devto_title: "Ollama drops tool calls to names not in tools and returns an empty reply"
devto_tags: ollama, llm, ai, selfhosted
---

**TL;DR**: When a model served by Ollama calls a function that isn't in the request's `tools` list, Ollama drops the call. The reply has no `content` and no `tool_calls`, but an `eval_count` above zero, so tokens were generated and then discarded. On Ollama 0.40.8 with `qwen3:0.6b`, a system prompt saying to call `lookup_order`, with only `get_time` in `tools`, gave 8 of 8 empty replies, each with `eval_count` 25. Generating the same prompt raw produced `<tool_call>{"name": "lookup_order", "arguments": {"order_id": "48213"}}</tool_call>`, also 25 tokens. With `lookup_order` added to `tools`, 8 of 8 replies were that call. It happens in the generic, template-based tool parser that Ollama uses for models without a dedicated parser, which includes the library `qwen3`. The client-side fix is to list every tool the model may name. Upstream: [ollama/ollama#19187](https://github.com/ollama/ollama/issues/19187).

## The symptom

A disposable LXC container, Ollama 0.40.8 from the GitHub release, CPU, `qwen3:0.6b` from the Ollama library. Ollama's log shows which path the model takes:

```
msg="template selection" model=registry.ollama.ai/library/qwen3:0.6b selected=go_template renderer="" parser=""
```

so tool calls are parsed by the generic parser built from the chat template.

The request, to `/api/chat` with `stream: false` and `think: false`:

```
system: You are a shop assistant. To answer questions about an order, always call the lookup_order
        tool with the order id. Never answer order questions from memory.
user:   What is the status of order 48213?
```

Eight runs each (seeds 0 to 7, temperature 0.7), with two `tools` lists:

```
qwen3:0.6b tools=[get_time] (lookup_order not listed): EMPTY x8  eval_count of EMPTY: [25, 25, 25, 25, 25, 25]
qwen3:0.6b tools=[get_time, lookup_order]: tool_call lookup_order x8
```

`EMPTY` means `content` was an empty string and there was no `tool_calls` field. The OpenAI-compatible endpoint did the same: `finish_reason` `stop`, empty `content`, `tool_calls` null.

To see what the model actually generated, the same conversation went through `/api/generate` with `raw: true` and a prompt written out by hand following the model's template, with `get_time` as the only tool:

```
raw seed 0: eval_count=25 '<tool_call>\n{"name": "lookup_order", "arguments": {"order_id": "48213"}}\n</tool_call>'
raw seed 1: eval_count=25 '<tool_call>\n{"name": "lookup_order", "arguments": {"order_id": "48213"}}\n</tool_call>'
raw seed 2: eval_count=25 '<tool_call>\n{"name": "lookup_order", "arguments": {"order_id": "48213"}}\n</tool_call>'
```

A complete, well-formed call, 25 tokens, the same count as the empty replies.

## Why it's easy to miss

An empty reply looks like the model's fault. Small models do sometimes return nothing, and a client that gets an empty assistant message usually retries or shows nothing, without logging that tokens were generated. Only `eval_count` says the model produced something.

Calling a tool that isn't listed sounds like an edge case, but it comes up in ordinary agent setups. Tools that are loaded on demand, tools named in another tool's description or in the system prompt, a tool list trimmed per request to save context, or a model that remembers a tool from earlier in the conversation. The report came from an app where the unlisted tool was offered on demand; 28 of 32 replays of its real requests came back empty.

And there's no signal on the server either: no warning, no `done_reason`, nothing in the log about a discarded call.

## What's really going on

Ollama's generic tool parser (`tools/tools.go` at v0.40.8) watches the output for the template's tool-call tag, here `<tool_call>`. Once the tag appears, the parser switches to tool-calling mode and holds everything after it in a buffer. It then looks for one of the names in the request's `tools` at the start of that buffer (`findTool`); a name that isn't in the list matches nothing, so no call is produced. For tags other than `{` or `[` the parser never decides it's finished, and at the end of the reply `Content()` returns an empty string unless the tag is `{` or `[`. So the buffered text, which is the entire tool call, is neither returned as a call nor passed through as content.

That matches every observation above: the tag and the call were generated (the raw output), the tokens were counted (`eval_count` 25), and nothing came out.

## The fix

There's no fix upstream yet; the issue had no reply as of 22 October.

**List every tool the model may call.** With `lookup_order` listed, every reply here was the call. The reporter found that entries with empty parameter schemas were enough (30 of 32 calls came back); here the listed tool had a full schema. If tools are loaded on demand, include their names up front and load the implementation when the call arrives.

**Treat an empty reply with `eval_count > 0` as a dropped call**, not as "the model said nothing". Log it, and retry with the full tool list.

The toolkit's `check-ollama-dropped-tool-calls.sh` runs this probe against a model on your server: first with `lookup_order` listed, to check the model calls tools at all, then without it:

```
  control, lookup_order listed:     ['call:lookup_order', 'call:lookup_order', 'call:lookup_order', 'call:lookup_order']
  probe, lookup_order not listed:   ['EMPTY(eval_count 25)', 'EMPTY(eval_count 25)', 'EMPTY(eval_count 25)', 'EMPTY(eval_count 25)']

4 of 4 replies came back empty: the model called an unlisted tool and Ollama dropped the call.
```

It exits 1 there, 0 when the unlisted call comes back as a call or as text, and 2 when the model doesn't call tools at all (`gemma3:270m` returned HTTP 400 for a request with tools).

## The generalisable habit

Check that a parser has a path for input it doesn't recognise. A parser that only knows how to emit the things it can match will, on anything else, either fail loudly or drop it, and dropping is the worse of the two because nothing downstream can tell. The question to ask of any structured-output layer is: what comes out when the model writes something valid that isn't on the list?

And count what was generated, not just what was returned. `eval_count` against an empty reply is the whole diagnosis here, and it's sitting in every response.

The Responses API in llama-server has a related gap in the other direction, [returning a cut-off tool call as completed](https://homelabpostmortem.com/2026/10/20/llama-server-responses-api-reports-a-cut-off-reply-as-completed/).
