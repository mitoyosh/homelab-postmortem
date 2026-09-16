---
title: "Ollama's gemma4 renderer never shows the model a tool parameter named type, description, required, properties or nullable — it stays in the required list, and the model makes a value up."
date: 2026-09-16
excerpt: "Same tool schema, temperature 0, only the parameter renamed. Called kind, the model returns the enum value urgent_A7 — a string that exists only in the parameter's definition. Called type, it returns \"urgent\": a plausible value that fails schema validation, produced by a model that was told the parameter is required and never shown what it is. The Go renderer ported a Jinja macro's filter_keys=false argument as an unconditional filter. Twelve lines fix it; renaming the parameter works today."
devto_title: "Ollama's gemma4 renderer silently drops tool parameters named type or description, and the model invents a value"
devto_tags: ollama, llm, ai, debugging
---

**TL;DR**: define a tool for a gemma4 model in Ollama with a parameter whose *name* is `type`, `description`, `properties`, `required` or `nullable`, and the model is never shown that parameter's definition. It is still listed under `required:[…]` in the rendered declaration, so the model knows it must supply something and has no idea what. On `gemma4:e2b` at temperature 0 the result is an invented value — `"type": "urgent"` for a parameter whose only legal values are `urgent_A7` and `routine_B3` — and on the reporter's `gemma4:26b` it is an omitted argument. HTTP 200, nothing in the log. The cause is a Go port of the reference Jinja template that dropped one argument: the template's `format_parameters` macro takes `filter_keys=false` and filters schema keywords in exactly one call site; the Go `writeSchemaProperties` filters unconditionally and serves all four. Twelve lines restore the argument, and the same request then returns `urgent_A7`. Until that lands, rename the parameter.

## The symptom

Ollama 0.33.3, Debian 13, CPU only, `gemma4:e2b`. The tool is the one from [ollama/ollama#18468](https://github.com/ollama/ollama/issues/18468): a ticket creator with two required string parameters, one of which has an enum. The user message is `Open an urgent ticket titled 'Water leak'.` Temperature 0, `think: false`, two runs each. The only thing that changes between requests is the name of the second parameter.

```
"parameters": {"type": "object", "required": ["title", "<name>"],
  "properties": {"title":  {"type": "string", "description": "Ticket title"},
                 "<name>": {"type": "string", "description": "Priority code",
                            "enum": ["urgent_A7", "routine_B3"]}}}
```

```
kind         run1  {"kind":"urgent_A7","title":"Water leak"}
kind         run2  {"kind":"urgent_A7","title":"Water leak"}
type         run1  {"title":"Water leak","type":"urgent"}
type         run2  {"title":"Water leak","type":"urgent"}
description  run1  {"description":"Urgent water leak.","title":"Water leak"}
description  run2  {"description":"Urgent water leak.","title":"Water leak"}
```

`urgent_A7` is a string that appears nowhere in the prompt except inside the parameter's definition. When the parameter is called `kind`, the model produces it every time. When the same definition is called `type`, the model produces `urgent` — the word from the user's sentence — and when it is called `description`, a sentence. It is filling a slot it was told exists with whatever the name suggests, because the definition that would have told it otherwise was never in the prompt.

The reporter, on `gemma4:26b`, saw the argument left out entirely instead. A bigger model declines to guess; a smaller one guesses. Both are downstream of the same missing text.

## Why this is easy to miss

Nothing fails. The request is accepted, the response is 200, the tool call is well-formed JSON with the right function name, and one of its two arguments is correct. If your tool handler validates against the schema, you get a validation error on the *model's* output and start debugging the model: prompt wording, temperature, whether gemma4 is any good at function calling. The reporter's numbers were 1 ticket created out of 14 attempts with 35 schema-validation failures, all on a required parameter called `description`, and it took renaming the parameter to find out the model had never seen it.

If your handler does not validate, you get `"type": "urgent"` stored somewhere as a priority code, and you find out later.

The names involved are not exotic. `type` is the most natural name for a categorical field. `description` is what you call the free-text field on a ticket, an event, a product. JSON Schema has no rule against property names that happen to be schema keywords — they live in a different namespace, inside `properties`, and every validator handles them correctly. This renderer does not.

Ollama has no debug setting that prints the rendered prompt, so the declaration the model actually receives is not observable from outside the process. The only ways to see it are to read the renderer or to run it.

## What is really going on

Ollama renders gemma4 prompts in Go, in `model/renderers/gemma4.go`, and checks that renderer against the model's reference Jinja template in `model/renderers/testdata/`. The template's parameter macro looks like this:

{% raw %}
```
{%- macro format_parameters(properties, required, filter_keys=false) -%}
    {%- set standard_keys = ['description', 'type', 'properties', 'required', 'nullable'] -%}
    {%- for key, value in properties | dictsort -%}
        {%- if not filter_keys or key not in standard_keys -%}
            {{ key }}:{
```
{% endraw %}

`filter_keys` defaults to false, and the macro is called four times. Three of them pass nothing — top-level parameters, nested object properties, array items — because in those calls the keys are parameter names. One call passes `filter_keys=true`: the branch where an object has no `properties` map and the macro walks the object's own keys, where `type` and `description` really are schema keywords and must not be rendered as if they were parameters.

The Go port has the same four call sites and the same skip list. It does not have the argument:

```go
func (r *Gemma4Renderer) writeSchemaProperties(sb *strings.Builder, props map[string]any) {
	…
	for _, name := range keys {
		if isSchemaStandardKey(name) {
			continue
		}
```

So the one-branch filter became an every-branch filter. A same-package test that calls `Render` with the ticket tool and prints the declaration shows the consequence directly, on 0.33.3 (gemma4's `<|"|>` quote token shown as `"`):

```
kind        properties:{kind:{description:"Priority code",enum:["urgent_A7","routine_B3"],type:"STRING"},title:{…}}  required:["title","kind"]
type        properties:{title:{…}}                                                                                   required:["title","type"]
description properties:{title:{…}}                                                                                   required:["title","description"]
properties  properties:{title:{…}}                                                                                   required:["title","properties"]
required    properties:{title:{…}}                                                                                   required:["title","required"]
nullable    properties:{title:{…}}                                                                                   required:["title","nullable"]
typo        properties:{title:{…},typo:{description:"Priority code",enum:[…],type:"STRING"}}                          required:["title","typo"]
```

The `required` list is written by a different function that does not filter, which is why the name survives there. The model is told "you must supply `type`" by one line and shown no `type` by the other. `typo` is in the table as a control: it is not on the list, so it renders. The problem is the five words, not anything about the schema.

The existing reference tests in the package all pass with this behaviour and all still pass after the fix below, which means none of them ever used a parameter named after a keyword. That is why the port shipped.

Upstream `main` at `a43fad18` (2026-09-15) has the same code.

## The fix

Two, in order of when you can have them.

**Today: rename the parameter.** This is the whole workaround and it is enough — the runs above with `kind` are the fixed state. If the name is part of an external contract you cannot change, map it in your tool handler: declare `kind` to the model, translate to `type` before you call the real function.

The toolkit's `check-tool-param-names.sh` finds every colliding name in a tool definition file, including nested objects and array items, and prints the JSON path of each:

```
$ ./check-tool-param-names.sh tools.json
tools.json: 3 colliding parameter name(s)
  create_ticket.parameters.properties.type
  create_ticket.parameters.properties.meta.properties.description
  create_ticket.parameters.properties.meta.properties.tags.items.properties.required
```

It also has a live mode, `--probe http://host:11434 --model gemma4:e2b`, which sends the ticket request twice — `kind` as the control, then `type` — and reports FAIL when the `type` call does not carry the enum value. The control is there because a model that cannot make tool calls at all would otherwise look like a renderer bug; that case is reported as UNKNOWN, not as a pass or a fail.

**Upstream: put the argument back.** The change that mirrors the template is a `filterKeys bool` on `writeSchemaProperties`, passed `true` at the one call site where the object itself is being walked and `false` at the other three:

```diff
-func (r *Gemma4Renderer) writeSchemaProperties(sb *strings.Builder, props map[string]any) {
+func (r *Gemma4Renderer) writeSchemaProperties(sb *strings.Builder, props map[string]any, filterKeys bool) {
 	…
-		if isSchemaStandardKey(name) {
+		if filterKeys && isSchemaStandardKey(name) {
 			continue
 		}
```

Twelve changed lines in total. With that applied, the same-package test renders all seven names, the package's existing tests still pass, and a Go binary rebuilt from the `v0.33.3` tag with the patch — dropped in over the stock one, same runner libraries — answers the same requests differently:

```
type         run1  {"title":"Water leak","type":"urgent_A7"}
type         run2  {"title":"Water leak","type":"urgent_A7"}
description  run1  {"description":"urgent_A7","title":"Water leak"}
description  run2  {"description":"urgent_A7","title":"Water leak"}
```

That is a one-variable change producing the enum value where the unpatched binary produced a guess, so the mechanism is not in doubt. The probe script reports OK against the patched server and FAIL against the stock one.

One thing this session did not test: nested object parameters and array items end to end with a model. The code reads the same way for those paths — they call the same function with the same unconditional filter, and the static test confirms the top-level case only — but the E2E runs here were top-level parameters.

## The generalisable habit

When a template is ported from one language to another, the arguments with default values are the ones that go missing, because at every call site that uses the default the port looks complete. `format_parameters(properties, required, filter_keys=false)` has three call sites that never mention `filter_keys` and one that does. A port that reads the three and generalises gets the filter wrong; a port that reads the one and generalises gets it wrong the other way; only a port that carries the parameter gets all four right. The test suite did not catch it because the test cases were written from the same three call sites.

This is the third post here where a local-model server accepted a request, returned 200, and quietly did something other than what the request said — [llama-server's README `response_format`](https://homelabpostmortem.com/2026/09/12/llama-server-ignores-the-response-format-its-readme-shows/) and [Ollama's `previous_response_id`](https://homelabpostmortem.com/2026/09/14/ollama-responses-api-drops-previous-response-id/) are the other two. The common thread is that the thing being dropped is a *name*: a JSON key the server does not read, a request field the struct does not have, a parameter the renderer decides is not a parameter. Names are the cheapest thing to get wrong and the last thing a 200 will tell you about. When a model is "bad at" something that depends on it having seen a specific piece of text, the first question is whether it saw the text — and for a renderer with no debug output, the only way to answer that is to render it yourself.
