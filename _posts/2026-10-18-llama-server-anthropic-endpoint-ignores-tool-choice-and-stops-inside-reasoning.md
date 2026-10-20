---
title: "llama-server's Anthropic endpoint ignores which tool you ask for, and its stop sequences fire inside the model's reasoning"
date: 2026-10-18
excerpt: "On llama.cpp b11717 with Qwen3-0.6B, /v1/messages accepted tool_choice {type: tool, name: get_time} and {type: none} and the model called get_weather both times, with no error or log line. stop_sequences were matched against the model's thinking too: a stop string it wrote while reasoning ended the reply with only a thinking block, and stop_reason said end_turn. Both matter to Claude Code pointed at a local model."
devto_title: "llama-server's Anthropic API ignores tool_choice and stops inside reasoning"
devto_tags: llm, selfhosted, ai, api
---

**TL;DR**: llama-server's Anthropic-compatible `/v1/messages` endpoint accepts two request controls and doesn't apply them. A forced tool, `tool_choice: {"type": "tool", "name": "get_time"}`, is treated as "call some tool": with `get_weather` and `get_time` available and a weather question, the model called `get_weather`. `tool_choice: {"type": "none"}` is not applied at all, and the model called `get_weather` again. No error, no log line. Separately, `stop_sequences` are matched against the model's reasoning as well as its answer, so a reasoning model that writes the stop string while thinking ends the request before it answers: only a `thinking` block comes back, and `stop_reason` is `end_turn` while `stop_sequence` names the match. Both observed on llama.cpp b11717 with Qwen3-0.6B. The stop behaviour has the same shape as a vLLM report filed on 16 October, [vllm-project/vllm#62085](https://github.com/vllm-project/vllm/issues/62085), where it breaks Claude Code's auto mode. I found no llama.cpp report of either.

## The symptom

A disposable LXC container, the b11717 release binary, `Qwen3-0.6B-Q8_0.gguf`:

```
llama-server -m Qwen3-0.6B-Q8_0.gguf --jinja -c 4096 --port 18090
```

### tool_choice

Two tools, `get_weather(city)` and `get_time(city)`, the user message "What is the weather in Vienna?", `temperature: 0`, every documented `tool_choice` form:

```
anthropic tool_choice=null: ([('tool_use', 'get_weather', '{"city": "Vienna"}')], 'tool_use')
anthropic tool_choice={"type": "auto"}: ([('tool_use', 'get_weather', '{"city": "Vienna"}')], 'tool_use')
anthropic tool_choice={"type": "any"}: ([('tool_use', 'get_weather', '{"city": "Vienna"}')], 'tool_use')
anthropic tool_choice={"type": "tool", "name": "get_time"}: ([('tool_use', 'get_weather', '{"city": "Vienna"}')], 'tool_use')
anthropic tool_choice={"type": "tool", "name": "get_weather"}: ([('tool_use', 'get_weather', '{"city": "Vienna"}')], 'tool_use')
anthropic tool_choice={"type": "none"}: ([('tool_use', 'get_weather', '{"city": "Vienna"}')], 'tool_use')
```

All six came back with `stop_reason: tool_use` and the same call. Asking for `get_time` by name changed nothing, and neither did `none`. The server log had no line for any of them.

The OpenAI-compatible endpoint on the same server has its own version of this, already reported upstream ([llama.cpp#30369](https://github.com/ggml-org/llama.cpp/issues/30369)): the named-function form `{"type": "function", "function": {"name": "get_time"}}` produced `get_weather`, and this time the log said so:

```
W Wrong type supplied for parameter 'tool_choice', using default value: [json.exception.type_error.302] type must be string, but is object
```

With `tool_choice: "none"` on that endpoint, no tool call was parsed, but the model still wrote one, and it arrived as text in `content`: `'<tool_call>\n{"name": "get_weather", "arguments": {...'`.

### stop_sequences

A question that makes Qwen3 think first, with a stop string that shows up in its reasoning. `temperature: 0.6`, two seeds, both endpoints:

```
stop='answer should be' seed 1 OpenAI finish=stop content='' reasoning_len=1639 tail='...7 is the only number that can divide it. Therefore, the '
   Anthropic stop_reason=end_turn stop_sequence='answer should be' blocks=[('thinking', 807, '...7 is indeed a prime number. Therefore, the ')]
stop='prime' seed 1 OpenAI finish=stop content='' reasoning_len=42 tail='Okay, so the question is asking if 7 is a '
   Anthropic stop_reason=end_turn stop_sequence='prime' blocks=[('thinking', 40, 'Okay, so the question is whether 7 is a ')]
```

Seed 2 gave the same shape. The reasoning stops right before the stop string, the answer is empty (OpenAI) or absent (Anthropic, a single `thinking` block and no `text` block), and the request reports a normal finish. Without a stop string the same request answered `<block>yes</block>` after about 1,660 characters of reasoning.

On the Anthropic endpoint the reply also contradicts itself: `stop_sequence` says which sequence matched, while `stop_reason` says `end_turn` instead of `stop_sequence`. That happened in the other case too, when the stop string `</block>` cut the visible answer.

## Why it's easy to miss

Every reply is well-formed. A tool call that is the wrong tool is still a valid tool call, and with only one tool defined, or a model that happens to pick the forced tool anyway, the bug is invisible. `get_weather` was also the right answer to the question here, so the forced-tool test only shows the bug because the forced tool was deliberately the wrong one.

The stop case looks like the model's fault. An empty answer with `finish_reason: stop` reads as "the model decided it was done", and small reasoning models do sometimes ramble and stop oddly. The only clue is that the reasoning ends mid-sentence exactly where the stop string would have started.

Both matter most for agent tools pointed at a local server. Claude Code can be pointed at any Anthropic-compatible endpoint. According to vllm#62085 its auto mode sends a classifier request with `stop_sequences: ["</block>"]`. In my runs Qwen3 never wrote `</block>` inside its reasoning, so I didn't see that exact request fail here. But any stop string a model can write while thinking will do it.

## What's really going on

For `tool_choice`, llama-server converts the Anthropic request to its OpenAI-style internal form (`tools/server/server-chat.cpp`). Reading that conversion in the source (master and b10703), `{"type": "tool", "name": ...}` becomes OpenAI `"required"` and the name is dropped, and `{"type": "none"}` has no mapping, so the default `"auto"` stays. "Required" means "call one of the tools", which the model did, and nothing tells it which one. The results above match that: `any` and the named forms behave identically.

For stop strings, the server checks them in `process_token` against the slot's whole generated text (`find_stopping_strings(slot.generated.text, ...)` in `tools/server/server-context.cpp`). The split into reasoning and answer happens later, when the reply is built. So a stop string is found wherever it appears in the generated text, including the reasoning section, and the reply is then built from whatever was generated before it.

Whether the Anthropic API defines `stop_sequences` to apply to thinking is a fair question I haven't settled. But an empty answer is clearly not what a client asking for a stop sequence wants, and a reply with `stop_sequence` set should have `stop_reason: "stop_sequence"`.

## The fix

There's no server setting for either one. What helps on the client side:

- **tool_choice**: don't rely on forcing a tool through `/v1/messages`. If a step needs one specific tool, send only that tool in `tools` for that request, with `{"type": "any"}`; since `any` does work as "call some tool", that should force it, though it wasn't tested here. To prevent tool calls, leave `tools` out of the request instead of sending `{"type": "none"}`.
- **stop_sequences with a reasoning model**: pick stop strings the model won't write while thinking, such as a closing tag of your own format, or turn reasoning off for requests that depend on a stop string. With llama-server, `--reasoning-budget 0` turns it off server-wide. That wasn't tested in this run.
- **Detect it**: treat a reply with no text block (or empty `content`) plus a set `stop_sequence` as this failure, not as an empty answer, and retry without the stop string.

The toolkit's `check-llama-anthropic-controls.sh` sends four small requests to a server and reports each control. Against this server:

```
  IGNORED  tool_choice {type: tool, name: get_time} -> called ['get_weather']
  IGNORED  tool_choice {type: none} -> called ['get_weather']
  MATCHED IN REASONING  stop_sequences ['prime'] ended the reply inside thinking: blocks ['thinking'], stop_reason 'end_turn', stop_sequence 'prime'
  note     stop_sequence is 'prime' but stop_reason is 'end_turn'
```

exit 1. With a model that doesn't call tools or doesn't reason (gemma-3-1b here), it says the tests are inconclusive and exits 2 rather than passing.

## The generalisable habit

A compatibility layer is a translation, and translations lose things silently. When a server says it speaks another vendor's API, test the parameters you actually depend on, and design the test so the right answer is different from the default: force the tool the model wouldn't pick on its own, and choose a stop string the model will write where you don't want it to stop. A test where the correct behaviour and the broken one give the same output proves nothing.

The same pattern of a control being accepted and then quietly overridden by the model's reasoning came up with Ollama: [a thinking model skipped the JSON schema when it answered directly](https://homelabpostmortem.com/2026/10/05/ollama-thinking-model-skips-your-json-schema-when-it-answers-directly/).
