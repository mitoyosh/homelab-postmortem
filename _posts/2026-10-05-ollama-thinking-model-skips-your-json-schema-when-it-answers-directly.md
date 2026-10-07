---
title: "With think enabled, Ollama only enforces your JSON schema after the model has thought, so a direct answer comes back as plain text"
date: 2026-10-05
excerpt: "Since 0.34.4, Ollama applies format on a thinking model as one grammar: free text until the thinking block closes, then the schema. The grammar lets the response end before the closing, so when Gemma 4 skips thinking and answers straight away, nothing constrains it. On gemma4:e2b, every direct answer came back as bare text like 391 or Paris with HTTP 200, and every answer that thought first matched the schema. The open fix made all of them match, by steering the model into thinking first."
devto_title: "Ollama skips your JSON schema when a thinking model answers without thinking"
devto_tags: ollama, llm, selfhosted, json
---

**TL;DR**: Since 0.34.4, Ollama applies a `format` schema on a thinking model as a single grammar: anything until the thinking block closes, then the schema. That grammar also allows the response to end before the closing, and it treats everything up to the closing as thinking. So when a model like Gemma 4 decides not to think and answers straight away, its answer is "text before the closing" and nothing constrains it. On `gemma4:e2b` with `think: true` and a one-field schema, every answer that skipped thinking came back as bare text (`391`, `Paris`) with HTTP 200 and nothing in the log. Every answer that thought first matched the schema. With `think: false` the reply had the right shape every time. The open fix, [ollama/ollama#18783](https://github.com/ollama/ollama/pull/18783), made all 16 replayed requests match the schema, though not by constraining the direct answer: the model thought first every time instead. Until a release includes it, validate `format` replies in the client. The toolkit's `check-ollama-format-think.sh` tells you whether a model on your server does this. Upstream report: [ollama/ollama#18774](https://github.com/ollama/ollama/issues/18774).

## The symptom

Debian 13 LXC, CPU only, Ollama 0.35.1 (the current release) from the release tarball, `gemma4:e2b` from the library. The report used `gemma4:e4b`; the smaller model is what a CPU-only LXC runs at a usable speed. The schema asks for one string field:

```json
{"type": "object",
 "properties": {"answer": {"type": "string"}},
 "required": ["answer"]}
```

The report's request on `/api/chat` at temperature 0, with seeds 1 and 2, then with `think: false`:

```
{"think": true,  "eval_count": 4,   "thinking_chars": 0,   "content": "391"}
{"think": true,  "eval_count": 248, "thinking_chars": 607, "content": "{\n  \"answer\": \">391\"\n}"}
{"think": false, "eval_count": 11,  "thinking_chars": 0,   "content": "{ \"answer\": \")\"\n}"}
```

The first line is the bug. `391` parses as JSON, but it is a number, not an object with an `answer` field. The request returned HTTP 200 with `done_reason: "stop"` after four tokens, so it didn't run out of tokens. The second line is the same request with a different seed: the model thought first, and the reply has the right shape. `/api/generate` gave the same results.

To see how often it happens, three prompts went out eight times each at the default temperature, seeds 0 to 7, on `/api/chat`:

```
"What is 17 * 23? Answer with the number."   thought 5, valid 5    direct 3, valid 0   ("391")
"What is the capital of France? One word."   thought 3, valid 3    direct 5, valid 0   ("Paris")
"Is 91 prime? Answer yes or no."             thought 8, valid 8    direct 0
```

How often the model skips thinking depends on the question, but the result once it does is the same: 16 of 16 replies that thought first matched the schema, and 8 of 8 that skipped thinking didn't. In the report's `think: false` control, three requests on each endpoint at temperature 0, every reply had the right shape.

## Why it's easy to miss

Whether you see it depends on the question. A test prompt that makes the model reason, which is what most people reach for when trying out a thinking model, never shows it. The prime question above went through thinking all eight times. The questions that trigger it are short and easy, which is also what most structured-output calls look like: classify this, extract that, yes or no.

Nothing reports it either. The status is 200, `done_reason` is `stop`, and the server log has no line about the format. A reply that is only a word or a number can even look like a parsing problem on the client side.

`think: false` working makes it look like `think: true` is just unsupported with `format`. It isn't: with thinking enabled the schema is enforced, but only on the part of the reply after the thinking.

## What's really going on

[#18479](https://github.com/ollama/ollama/pull/18479) ("apply structured outputs in a single pass on thinking models", merged 2026-09-22, first released in 0.34.4) made the format and the thinking one grammar. In `llm/llama_server.go` in 0.35.1, when the model's parser reports a thinking-close string and the request has a format, the schema is converted to a grammar and wrapped:

```go
if len(req.ThinkingClose) > 0 && (lsReq.Grammar != "" || lsReq.JsonSchema != nil) {
    ...
    lsReq.Grammar = thinkingGrammar(req.ThinkingClose, lsReq.Grammar)
}
```

The docstring of `thinkingGrammar` in `llm/gbnf.go` says what that wrapper allows:

```go
// thinkingGrammar returns a grammar that leaves the text before any of the
// closings unconstrained, then constrains what follows the first complete
// closing to the root of the format grammar. The response may end before any
// closing.
```

Gemma 4 opens thinking with `<|channel>` and closes it with `<channel|>`, and its parser reports `<channel|>` as the closing whenever thinking is enabled. The grammar assumes the response starts inside the thinking block. When the model starts with `<|channel>`, that holds: everything up to `<channel|>` is free, and the schema applies after it. When the model skips thinking and writes `391` followed by end of sequence, the grammar sees text before any closing, followed by an end the grammar allows. Nothing in it says the answer itself has to match the schema.

The #18479 description acknowledges the limitation: "A model that answers without thinking stays unconstrained."

With `think: false` the parser reports no closing, so the schema grammar is applied on its own from the first token, which is why that control always has the right shape.

## What the open fix does

[#18783](https://github.com/ollama/ollama/pull/18783) adds the opening string. For a model whose response can begin in content, the grammar becomes "either the schema, or `<|channel>`, then free thinking, then a required `<channel|>`, then the schema". The thinking branch can no longer end before the closing.

The PR head (`4121ed65`) and its merge base (`42e911bc`) were built in the same LXC, and each build got the eight prompt and seed pairs that had answered directly in the run above, on both endpoints:

```
                         0.35.1      merge base    PR #18783
answered directly        15 of 16    15 of 16      0 of 16
  ... schema violated    15          15            -
thought first            1           1             16
  ... schema matched     1           1             16
eval_count, direct       2 to 4      2 to 4        -
eval_count, thought      155         155           112 to 267
```

The one request that thought on 0.35.1 and the merge base (17 × 23, seed 1, `/api/chat`) had answered directly in the earlier run; at the default temperature the same seed doesn't always take the same branch. The merge base behaved exactly like the release.

On the PR build every request matched the schema. None of them was a constrained direct answer, though. The grammar no longer allows `Paris` as a first token, and of the two things it does allow, the start of the JSON object or `<|channel>`, the model picked `<|channel>` every time and thought for 260 to 634 characters. A capital-of-France call that took 2 tokens now takes about 113. That is a fair trade for getting the shape you asked for, but on a CPU box it is roughly fifty times the tokens for the questions that used to be the cheapest.

The fix also does nothing for what goes inside the field. Across the builds, the 17 × 23 answers that went through thinking came back as `"$391"`, `">391"`, `"))391"` and `")), "`. That is this small model under a grammar, not the bug, but it means a reply that matches the schema still needs checking.

## The fix

Until a release includes #18783:

- **Validate the reply against the schema in the client.** A reply that fails validation and has an empty `thinking` field is this case. On 0.35.1 every reply that thought first had the right shape, so a retry that lands in thinking will too; on prompts the model always answers directly, a retry won't help.
- **Send `think: false` for calls where you need the shape and don't need the thinking.** It had the right shape every time here. On `gemma4:e2b` the content was poor (`")"`, and in the report `"\\text{391}"`), so check whether your model's answers survive it.

Either way, don't assume that `format` guarantees the shape just because the request succeeded. With thinking enabled, it only covers the part of the reply after the thinking.

## The generalisable habit

When a constraint is applied to "the part after X", find out what happens when X never appears. Here the constraint was written for responses that begin with thinking, and a response with no thinking at all fell through it. The test is the input that skips the step: a question easy enough that the model answers it straight away.

It is the second structured-output gap in Ollama 0.35 here in a week. On one of its two chat paths, [your schema's keys are re-sorted alphabetically](https://homelabpostmortem.com/2026/10/03/ollama-native-chat-path-sorts-your-json-schema-keys/) before the grammar sees them. Both times the reply was HTTP 200 and nothing in the log said anything was wrong.

Which template a Gemma 4 model gets in the first place depends on [what the model is called](https://homelabpostmortem.com/2026/10/07/ollama-picks-the-gemma-4-template-from-the-model-name/): a copy of `gemma4:12b` under a name without `12b` is prompted with the e2b/e4b template.

The toolkit's `check-ollama-format-think.sh` sends a few short prompts to a model with `think: true` and a schema, and reports how many replies skipped thinking and how many of those broke the schema.
