---
title: "The Laya checkpoint still ships a 0.1 temperature. laya clamps it when it loads; an ONNX port that reads the file does not, and its 15-option answers come back 0.88 sure when they are wrong."
date: 2026-09-26
excerpt: "Laya's English checkpoint carries a softmax temperature of 0.1006 for choice questions with 11 or more options, which sharpens the logits about ten times. laya fixed it on 2026-09-21 by clamping temperatures to [0.5, 5] at load time, but the file on the Hub still says 0.1006, and anything that reads the file directly inherits it. edgejev, built from the English checkpoint, reproduced laya-with-the-raw-value exactly: on 20 fifteen-option questions its confidence on wrong answers averaged 0.877 against 0.569 for laya as shipped, and at a 0.9 threshold 10 of 14 wrong answers passed instead of 3. Accuracy was identical. Setting the value to 0.5 in edgejev.json made the two match to four decimals."
devto_title: "Laya's 0.1 temperature is clamped at load, not in the file, so an ONNX port inherits it"
devto_tags: ai, llm, machinelearning, python
---

**TL;DR**: Laya, one of the open "System One" decision models that appeared after TypeSafe's Jev, returns typed answers with calibrated probabilities, and the calibration is a set of per-bucket softmax temperatures stored in the checkpoint's `rl_agent_config.json`. In the English checkpoint the bucket for `choice` questions with 11 or more options is `0.10058`, which multiplies the logits by about ten; a 0.24 top probability comes out as 0.99. laya fixed this in 0.3.5 (2026-09-21) by clamping every temperature to [0.5, 5.0] **when it loads a checkpoint**, and it warns about it. The file on the Hub still carries `0.10058`. [edgejev](https://github.com/yzfly/edgejev), an ONNX runtime for Laya, copies the temperatures out of that file at build time and applies them as they are. Built from the English checkpoint, its probabilities matched laya-with-the-raw-value-put-back to four decimals on 20 fifteen-option questions: the answers were the same as laya's, and the confidence on the wrong ones averaged **0.877 instead of 0.569**. At a 0.9 threshold, **10 of 14 wrong answers passed instead of 3.** edgejev's *default* build uses the multilingual checkpoint, which has no temperatures, and is not affected. Setting the one value to 0.5 in `edgejev.json` made edgejev match laya exactly. The toolkit's `check-decision-temperatures.sh` lists every out-of-range temperature in a Hugging Face cache or an edgejev build.

## The symptom

A Debian 13 container on CPU, laya 0.3.20 and edgejev 0.3.2 in the same virtualenv, and the English checkpoint `convaiinnovations/laya` from the Hub. Loading it with laya prints a warning to stderr — nowhere else:

```
RuntimeWarning: laya: this checkpoint ships invalid temperatures or values outside [0.5, 5];
using choice:11+=0.10058280825614929 -> 0.5. Treat confidence from the affected entries as uncalibrated.
```

The file it is talking about:

```
$ python3 -c 'import json; print(json.load(open("rl_agent_config.json"))["temperature_by_options"])'
{'choice:3-5': 1.7601518630981445, 'choice:6-10': 1.0000158548355103, 'score:3-5': 1.2514300346374512,
 'noul:2': 1.983399510383606, 'choice:11+': 0.10058280825614929, 'choice:2': 1.9063563346862793}
```

Then an edgejev build from the same checkpoint, in fp32 so quantisation is out of the picture, and the same file inside it:

```
$ edgejev build --backend laya --model convaiinnovations/laya --precision fp32 --out ej-en-fp32
$ python3 -c 'import json; print(json.load(open("ej-en-fp32/edgejev.json"))["temperature_by_options"])'
{'choice:3-5': 1.7601518630981445, 'choice:6-10': 1.0000158548355103, 'score:3-5': 1.2514300346374512,
 'noul:2': 1.983399510383606, 'choice:11+': 0.10058280825614929, 'choice:2': 1.9063563346862793}
```

The build does print laya's warning once — line 3 of 32, between the ONNX exporter's own warnings about axis names — because it loads the checkpoint through laya. Then it writes `0.10058` anyway. Nothing is printed at inference.

To see what that does, twenty `choice` questions with fifteen options each and a known answer: seven "which city is this about" from a landmark, seven months described indirectly, six arithmetic questions bucketed into ranges. They are deliberately not easy, because the question is how confident the model is when it is wrong. Three arms: laya as shipped (clamped to 0.5), laya with `choice:11+` put back to `0.10058` (what laya did before 0.3.5), and edgejev built from the English checkpoint. A few rows:

```
truth       | laya, shipped      | laya, raw 0.1006   | edgejev
Prague      | Prague    0.724    | Prague    0.994    | Prague    0.994
Lisbon      | Madrid    0.485 ✗  | Madrid    0.914 ✗  | Madrid    0.914 ✗
June        | autumn    0.461 ✗  | autumn    0.919 ✗  | autumn    0.919 ✗
30-39       | 40-49     0.153 ✗  | 40-49     0.635 ✗  | 40-49     0.635 ✗
1000+       | 0-9       0.471 ✗  | 0-9       0.999 ✗  | 0-9       0.999 ✗
```

And all twenty:

```
                          accuracy   mean top prob   |conf - acc|   mean top prob when wrong (n=14)
laya, shipped (0.5)         0.30         0.639          0.339            0.569
laya, raw 0.1006            0.30         0.911          0.611            0.877
edgejev, English fp32       0.30         0.911          0.611            0.877

max |p_edgejev - p_laya_raw|     over every option of every question: 0.0000
max |p_edgejev - p_laya_shipped| over every option of every question: 0.6905
```

Same answers everywhere, so accuracy does not move. What moves is the number anyone would use to decide whether to trust the answer. At a threshold of 0.9, laya as shipped would have acted on 3 of 6 correct answers and 3 of 14 wrong ones; edgejev on all 6 correct and 10 of the 14 wrong.

## Why this is easy to miss

The answers are the same. Any test that checks what the model picks — which is every test anyone writes first — passes.

The one place the problem is announced is a Python `RuntimeWarning` emitted by laya itself, and only when laya loads the checkpoint. The edgejev build loads it through laya, so the warning does scroll past — once, in 32 lines of export output — and then the raw value is written into `edgejev.json` anyway, because the warning is about what laya's `Agent` will use, not what the file says. After the build, nothing on the inference path knows there was ever a warning. An HTTP client of either runtime gets a JSON number and no hint.

And the value is only wrong in one bucket. Ten or fewer options, `score`, `noul`: all within range. A test suite built on the README examples, which use three-option questions, never touches it.

There is also a false comfort in the other direction. laya's own clamp does not make the 11+ bucket calibrated; 0.5 still doubles the logits. On these questions laya as shipped averaged 0.639 confidence at 0.30 accuracy. The clamp stops the worst of it. It does not make the numbers trustworthy, and laya's warning says as much ("treat confidence from the affected entries as uncalibrated").

## What is really going on

The fix and the data live in different places. laya's `Agent` reads `temperature_by_options` from the checkpoint config and passes each value through `clamp_temperature` (`TEMP_MIN = 0.5`, `TEMP_MAX = 5.0`, in `laya/common.py`), storing the clamped value on the agent; the unclamped one stays in `cfg`. The Hub file was not changed. So the fix exists only for code that goes through laya's `Agent` at inference time.

edgejev's build step does load the checkpoint with laya, but it takes the temperatures from `cfg`:

```python
"temperature_by_options": cfg.get("temperature_by_options", {}),
```

and its runtime applies them directly, `softmax(logits / max(1e-3, scale))`, with no range check. The result is bit-for-bit laya-before-0.3.5, which is what the 0.0000 above says.

edgejev's default build is a different checkpoint: `--backend laya` without `--model` uses `convaiinnovations/laya-multilingual`, whose config has no per-bucket temperatures at all (`{}`, and `[1.0, 1.0, 1.0]` globally). That build is not sharpened by 10x — its probabilities are a plain softmax, uncalibrated in the ordinary way — and this post does not apply to it. You get the English checkpoint only by asking for it.

The same inheritance applies to any other runtime that reads the file. [receptron/laya#10](https://github.com/receptron/laya/issues/10) reports the same ~0.98–1.00 confidence on 13–15-option questions from the Node/ONNX runtime; that one was not tested here.

## The fix

**For an edgejev build from the English checkpoint**, set the one value to what laya applies and leave the model alone:

```bash
python3 - ej-en-fp32/edgejev.json <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
c["temperature_by_options"]["choice:11+"] = 0.5
json.dump(c, open(p, "w"), indent=2)
PY
```

On the same twenty questions that made edgejev's probabilities match laya-as-shipped to four decimals (`max |p_edgejev - p_laya_shipped| = 0.0000`). Or build from `laya-multilingual`, the default, if its languages and accuracy suit you.

**For any runtime that reads Laya's config**, check what it will actually use rather than what the upstream library does. The toolkit's `check-decision-temperatures.sh` walks a directory — the Hugging Face cache by default — and lists every temperature outside [0.5, 5.0] in `rl_agent_config.json` and `edgejev.json` files:

```
  Laya checkpoint: …/models--convaiinnovations--laya/snapshots/55cf4c4…/rl_agent_config.json
    OUT OF RANGE  choice:11+ = 0.1006  (sane range [0.5, 5.0], sharpens logits 9.9x)
  Laya checkpoint: …/models--convaiinnovations--laya-multilingual/snapshots/e4e9ddf…/rl_agent_config.json
    no per-bucket temperatures (probabilities are uncalibrated softmax, not sharpened)
  edgejev build: /root/ej-en-fp32/edgejev.json
    OUT OF RANGE  choice:11+ = 0.1006  (sane range [0.5, 5.0], sharpens logits 9.9x)
```

It exits 1 when it finds one, reads JSON only, and never loads a model. After the 0.5 edit above, the same build reports `OK (6 bucket temperatures, all within [0.5, 5.0])`.

**Whatever the runtime, measure before you threshold.** Even at 0.5 the 11+ bucket was over-confident here by 0.34. If an action depends on "confidence above X", put twenty of your own questions with known answers through it first and look at the confidence on the ones it gets wrong.

## The generalisable habit

**A fix applied when data is loaded only fixes the loader.** laya's clamp is correct and it shipped quickly, but it lives in the code path that reads the file, and the file still says 0.1006. Every other reader of that file — an exporter, a port to another runtime, a script that inspects the config — gets the old behaviour with no warning, because the warning is also in the loader. When you are downstream of a fix, check which of the two it changed, and if it was the loader, find out whether you use that loader. The same pattern — the value in the file is not the value in effect — made [`--cache-ram -1` mean something other than its label](https://homelabpostmortem.com/2026/09/24/llama-server-cache-ram-minus-one-is-not-no-limit/); there the translation happened in the server, and anyone reading the flag's help text got the wrong idea.

**Test the number you act on, not the answer.** A decision model's pitch is the probability. A test suite that checks only the argmax will pass through any calibration bug, including this one — every answer here was identical across all three arms.

The same goes for the instrument that reads the number. With speculative decoding on, [llama-server's logprobs are placeholders](https://homelabpostmortem.com/2026/10/06/llama-server-speculative-decoding-returns-placeholder-logprobs/) that say every token was certain, while the text stays normal.
