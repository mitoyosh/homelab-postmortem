---
title: "llama-server accepts the json_schema form its own README documents, returns 200, and generates as if you had sent no response_format at all."
date: 2026-09-12
excerpt: "Send {\"type\":\"json_schema\",\"schema\":{...}} — the example on the server README — and the reply is byte-identical to sending no response_format. The parser's json_schema branch only ever reads json_schema.schema, the 2025 fix addressed that nested form alone, and the README example predates it. Every structured answer you got this way was the model cooperating, not the server enforcing."
devto_title: "llama-server ignores the response_format its own README shows, and returns 200"
devto_tags: llm, ai, devops, python
---

**TL;DR**: `tools/server/README.md` gives `{"type": "json_schema", "schema": {...}}` as an example of schema-constrained output. On a build from this week the reply to that form is **byte-identical** to the reply when you send no `response_format` at all — same SHA-256, same 248 characters of prose. HTTP 200, nothing in the log. The `json_schema` branch of the request parser reads only `response_format.json_schema.schema`; a `schema` sitting directly under `response_format` is never consulted in that branch. The March 2025 fix that people cite for this fixed the *nested* form and never touched this one, and the README example was already there when it merged. Two other forms constrain correctly and are the workaround.

## The symptom

llama.cpp `b10868` (commit `304665fe7`, released 2026-09-09), the official Linux x64 binary, on Debian 13, CPU only. Model is `gemma-3-1b-it-Q4_K_M`, small enough that the whole experiment takes a minute. One prompt, one schema, `temperature 0`, `seed 42`, four ways of asking:

```
prompt   What is 2+2? Explain your reasoning in a few sentences.
schema   {"type":"object","properties":{"answer":{"type":"integer"}},
          "required":["answer"],"additionalProperties":false}
```

The prompt is chosen to produce prose if nothing stops it. The schema allows exactly one integer field and nothing else. Here is what came back, hashed:

```
                                                         sha256        result
no response_format                                       5dc606573325  free text
{"type":"json_object","schema":{...}}                    72241d50124b  {"answer": 4}
{"type":"json_schema","schema":{...}}         [README]   5dc606573325  free text
{"type":"json_schema","json_schema":{"schema":{...}}}    72241d50124b  {"answer": 4}
```

Two hashes for four requests. The README form did not produce *worse* structured output, or partially constrained output. It produced the control, to the byte:

```
2 + 2 equals 4. This is a fundamental mathematical concept that relies on
basic addition – combining two individual units to create a combined unit
with a value of four. It's a core principle used in …
```

Every request returned HTTP 200. The server log for the four of them is four ordinary `launch_slot_` / `print_timing` / `release` triples with nothing about a schema, a grammar, or an empty anything.

## Why this is easy to miss

You would not notice, because models cooperate. Ask a capable model for JSON in the prompt and it usually gives you JSON, so a `response_format` that does nothing looks like a `response_format` that works — right up to the request where the model decides to add a sentence of explanation, or a trailing comma, or a field you did not ask for, and something downstream falls over. At that point the natural question is "why is the model misbehaving?" and not "was the constraint ever applied?", because the server has been answering 200 the whole time.

The second false trail is the issue tracker. Search for this and you find [`#10732`](https://github.com/ggml-org/llama.cpp/issues/10732) ("server provides structured output for `json_object`, but not for `json_schema`", December 2024) and, next to it, [`#11988`](https://github.com/ggml-org/llama.cpp/issues/11988), closed as completed in March 2025 with a merged fix, [`#12168`](https://github.com/ggml-org/llama.cpp/pull/12168), and a reporter confirming "the issue is not present in the new `b4820`." That reads like the end of the story. It is not, and the reason is in the diff.

## What is really going on

This is the request parser, `tools/server/server-common.cpp`, as shipped in `b10868`:

```cpp
if (response_type == "json_object") {
    json_schema = json_value(response_format, "schema", json::object());
} else if (response_type == "json_schema") {
    auto schema_wrapper = json_value(response_format, "json_schema", json::object());
    json_schema = json_value(schema_wrapper, "schema", json::object());
} else if (!response_type.empty() && response_type != "text") {
    throw std::invalid_argument(...);
}
```

The `json_object` branch reads `response_format.schema`. The `json_schema` branch reads `response_format.json_schema.schema` and only that. Send `{"type":"json_schema","schema":{...}}` and `schema_wrapper` defaults to `{}`, `json_schema` defaults to `{}`, and generation proceeds with an empty schema — which is to say, no grammar. No branch throws, because the type was recognised.

Now the 2025 fix. This is the whole of what [`#12168`](https://github.com/ggml-org/llama.cpp/pull/12168) changed in that function:

```diff
-            json json_schema = json_value(response_format, "json_schema", json::object());
-            json_schema = json_value(json_schema, "schema", json::object());
+            auto schema_wrapper = json_value(response_format, "json_schema", json::object());
+            json_schema = json_value(schema_wrapper, "schema", json::object());
```

A shadowed variable. The inner `json_schema` was hiding the outer one, so the nested wrapper form silently did nothing. The fix un-shadowed it, the nested form started working, the test it added uses the nested form, and the issue closed. **The top-level form was not part of that bug and not part of that fix.** It has not regressed; on this code path it has never worked.

And the README already showed it. At the merge commit of `#12168`, `examples/server/README.md` line 1076 read:

> The `response_format` parameter supports both plain JSON output (e.g. `{"type": "json_object"}`) and schema-constrained JSON (e.g. `{"type": "json_object", "schema": {...}}` or `{"type": "json_schema", "schema": {...}}`)

The same sentence is at `tools/server/README.md` line 1316 today. Eighteen months of a documented example that the parser does not read, sitting one clause away from a documented example that it does.

There is a pull request that fixes it, [`#28697`](https://github.com/ggml-org/llama.cpp/pull/28697), which adds a fallback to `response_format.schema` when the wrapper is absent. As of this writing it is open with no reviews. I built its branch (`48f9bfd`) on the same machine and ran the same four requests: the README form now hashes `72241d50124b`, identical to the two forms that already worked, and those two are unchanged. The patch does what it says.

## The fix

Until that merges, use either of the two forms that do constrain on this build. Both were verified above with the same hash:

```json
{"type": "json_object", "schema": { ... }}
```

```json
{"type": "json_schema", "json_schema": {"name": "x", "schema": { ... }}}
```

The second is the OpenAI wrapper shape and is what most client libraries emit, which is probably why this has survived so long — the people who would hit it are the ones who read the README and wrote the request by hand.

**Check the server you actually run, not the one in the docs.** Four requests, compared by hash, is the whole test, and it takes seconds against any running `llama-server`:

```python
import json, hashlib, urllib.request
S = {"type":"object","properties":{"answer":{"type":"integer"}},"required":["answer"],"additionalProperties":False}
forms = {
  "none":        None,
  "json_object": {"type":"json_object","schema":S},
  "readme":      {"type":"json_schema","schema":S},
  "openai":      {"type":"json_schema","json_schema":{"name":"x","schema":S}},
}
for name, rf in forms.items():
    body = {"messages":[{"role":"user","content":"What is 2+2? Explain your reasoning in a few sentences."}],
            "temperature":0,"seed":42,"max_tokens":200}
    if rf: body["response_format"] = rf
    req = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions",
            data=json.dumps(body).encode(), headers={"content-type":"application/json"})
    c = json.loads(urllib.request.urlopen(req).read())["choices"][0]["message"]["content"]
    print(f"{name:12} {hashlib.sha256(c.encode()).hexdigest()[:12]}  {c[:40]!r}")
```

Output on `b10868`, gemma-3-1b:

```
none         5dc606573325  '2 + 2 equals 4. This is a fundamental ma'
json_object  72241d50124b  '{\n \t \t \t \t \t \t \t \t \t \t"answer": 4\n \t \t \t'
readme       5dc606573325  '2 + 2 equals 4. This is a fundamental ma'
openai       72241d50124b  '{\n \t \t \t \t \t \t \t \t \t \t"answer": 4\n \t \t \t'
```

If any form with a schema hashes the same as `null`, that form is not being enforced on your build. The toolkit's `check-llama-response-format.sh` does exactly this, with the control checked first so a model that happens to answer in JSON unprompted cannot fake a pass.

## The generalisable habit

The narrow one: **a fix for a sibling form is not a fix for your form.** `#12168` was real, was merged, and was confirmed by the person who reported it. It also had nothing to do with the request shape the README shows. When a closed issue seems to cover your case, read the diff and find your exact input in it; if it is not there, the issue was about something else that happened to share a title.

The wider one is about what "it worked" is evidence of. A structured response from a model can mean the server constrained the output, or it can mean the model produced it unconstrained because you asked nicely — and from the outside those are the same bytes. The only way to tell them apart is to hold the prompt fixed and *remove* the constraint: if the output does not change, there was no constraint. That is the same move as [running the control before the suspect](https://homelabpostmortem.com/2026/09/07/ollama-library-quant-is-broken-not-the-quant-level/) and the same shape as [an adapter that is accepted and applied to zero layers](https://homelabpostmortem.com/2026/09/07/vllm-accepts-a-lora-it-will-never-apply/): the system reports that it did what you asked, and the output looks right, and neither of those is the thing you needed to know.
