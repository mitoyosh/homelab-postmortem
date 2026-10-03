---
title: "vLLM serves a LoRA adapter that uses rank_pattern or alpha_pattern at the wrong scale, and says nothing"
date: 2026-10-03
excerpt: "PEFT scales each LoRA module by its own alpha / r, which rank_pattern and alpha_pattern can set per module. vLLM 0.30.0 reads one r and one lora_alpha and applies lora_alpha / r to everything. On an RTX 2070, an adapter with rank_pattern {q_proj: 4} came out 70 times further from PEFT than the same adapter without the pattern, and alpha_pattern alone did the same. Folding the scale into lora_B and dropping the pattern matched PEFT again."
devto_title: "vLLM ignores LoRA rank_pattern and alpha_pattern and serves the adapter at the wrong scale"
devto_tags: llm, vllm, lora, selfhosted
---

**TL;DR**: A PEFT LoRA adapter can give individual modules their own rank and alpha through `rank_pattern` and `alpha_pattern` in `adapter_config.json`, and PEFT scales each module by its own `alpha_m / r_m`. vLLM 0.30.0 reads `r` and `lora_alpha` only and applies `lora_alpha / r` to every module. The patterns are dropped without a warning. On an RTX 2070 under WSL2, with PEFT 0.21.2 and a small random Qwen3, an adapter with `rank_pattern = {"q_proj": 4}` gave prompt log-probabilities 0.0211 away from PEFT's on average, against 0.0003 for the same setup without a pattern. An adapter with only `alpha_pattern` set was off by 0.0168. Multiplying the affected modules' `lora_B` by the missing factor and clearing the pattern brought it back to 0.0003. The toolkit's `check-lora-patterns.py` reads an adapter's config and lists the modules vLLM will mis-scale, and by how much. Upstream report: [vllm-project/vllm#59799](https://github.com/vllm-project/vllm/issues/59799).

## The symptom

RTX 2070 (8 GB) on Windows 11, WSL2 Ubuntu, driver 591.86. vLLM 0.30.0 with torch 2.13.0+cu130, PEFT 0.21.2. The model is a randomly initialised two-layer Qwen3 (hidden size 256), so nothing has to be downloaded. The RTX 2070 has no bf16, so everything ran in fp16 (the report used bf16).

Four adapters on `q_proj` and `v_proj`, all `r=16`, `lora_alpha=32`, with `lora_B` scaled up so the adapter's effect stands well clear of fp16 noise. For each, PEFT's own prompt log-probabilities on four 48-token prompts are the reference, then vLLM serves the same adapter on the same base:

```
adapter                                   PEFT q_proj scale   mean |vLLM - PEFT|   max
none          no pattern                  2                   0.0003               0.0016
rank          rank_pattern {"q_proj": 4}  32/4   = 8          0.0211               0.1106
rank_folded   rank, q_proj lora_B x4,     2 (x4 in weights)   0.0003               0.0010
              rank_pattern {}
alpha         alpha_pattern {"q_proj":128} 128/16 = 8         0.0168               0.1046
```

The first row shows vLLM's LoRA path is fine: with no pattern it matches PEFT to within fp16 rounding. With a pattern on one module, the error is 70 times larger. The folded copy, which moves the factor PEFT applies into the weights themselves, matches again. `alpha_pattern` alone produces the same error, so this is about the scaling, not about the module having a different rank.

The vLLM log has nothing to say about any of it. No line in the run mentions `rank_pattern` or `alpha_pattern`.

## Why it's easy to miss

vLLM accepts the adapter. It already turns some adapters away: `_validate_features` refuses DoRA and `modules_to_save`, so an adapter that loads without complaint looks supported. The output is still the adapter's output, only weaker or stronger in the patterned modules than it was trained to be. Nothing about the generated text flags that. You would have to compare against PEFT, or measure the quality you trained for, to see it.

The patterns aren't exotic, either. The report points out that PEFT's own LoRA documentation recommends `rank_pattern` for mixture-of-experts models, giving each expert a smaller rank (`r // num_experts`), and points to vLLM for serving. The reporter measured the consequence on OLMoE-1B-7B: a held-out perplexity of 10.06 in PEFT and 11.28 in vLLM, against 13.09 for the base model. That means vLLM gave up about 40% of what the adapter had gained. Those numbers are the reporter's, from hardware this lab doesn't have. The direction and size of the effect match the small model here.

## What's really going on

`vllm/lora/peft_helper.py` in 0.30.0 defines the fields vLLM reads from `adapter_config.json`:

```python
r: int
lora_alpha: int
target_modules: list[str] | str
bias: ...
modules_to_save: list[str] | None = ...
use_rslora: bool = field(default=False)
use_dora: bool = field(default=False)
vllm_lora_scaling_factor: float = field(default=1.0)
```

and computes one scale from them:

```python
if self.use_rslora:
    self.vllm_lora_scaling_factor = self.lora_alpha / math.sqrt(self.r)
else:
    self.vllm_lora_scaling_factor = self.lora_alpha / self.r
```

There is no field for `rank_pattern` or `alpha_pattern`, and a code search of the repository finds no other reference to them. The rank of each module still comes out right, because it's taken from the tensor shapes in the safetensors file. Only the scale is shared, so any module whose pattern makes `alpha_m / r_m` differ from `lora_alpha / r` is scaled wrong by exactly that ratio. For `q_proj` above that is 8 against 2, a factor of 4.

Not every patterned adapter is affected. According to the report, PEFT's `save_as_lora` with a dynamic rank writes `r=1`, `lora_alpha=1` and the same value in both patterns for each module. Every module's scale is then 1, and vLLM gets it right by coincidence.

A fix is proposed in [#59801](https://github.com/vllm-project/vllm/pull/59801), which applies the scale per module. It is open and unmerged, and 0.30.0 is the current release.

## The fix

Until a release includes it, fold each affected module's scale correction into its `lora_B` and remove the patterns. The factor is PEFT's scale for that module divided by vLLM's, and `check-lora-patterns.py` prints it. For the adapter above it was 4 for `q_proj`. This is the fold the `rank_folded` row used, written to a new directory:

```python
import json, os
from safetensors.torch import load_file, save_file

sd = load_file("rank/adapter_model.safetensors")
sd = {k: v * 4 if "q_proj.lora_B" in k else v for k, v in sd.items()}   # 4 = (32/4) / (32/16)
os.makedirs("rank_folded")
save_file(sd, "rank_folded/adapter_model.safetensors")
cfg = json.load(open("rank/adapter_config.json"))
cfg["rank_pattern"] = {}
json.dump(cfg, open("rank_folded/adapter_config.json", "w"))
```

Two cautions:

- **Pattern keys are module-name patterns.** According to the report, PEFT matches a key against the end of the module path, so `q_proj` applies to every layer's `q_proj`, and a key like `layers.3.self_attn.q_proj` applies to one. Fold the tensors the key actually covers.
- **Don't just delete `alpha_pattern`.** That changes what PEFT does as well, and leaves vLLM where it was.

Run `check-lora-patterns.py` on the folded adapter afterwards. It should report every module as keeping `lora_alpha / r`.

## The generalisable habit

An adapter config is a set of instructions, and a loader that recognises only some of them will quietly carry out a different set. vLLM rejects some unsupported adapter features outright, and that makes it easy to assume that whatever it accepts, it supports. It doesn't follow. Before you trust a server to reproduce a training setup, compare one batch of its outputs against the training framework's on the same inputs. Here that took four prompts and a single number.

This is the second LoRA case on this site where vLLM accepts an adapter and serves something else. The first was [an adapter whose target modules it will never apply](https://homelabpostmortem.com/2026/09/07/vllm-accepts-a-lora-it-will-never-apply/). Its weight cache, which [can serve another checkpoint's weights](https://homelabpostmortem.com/2026/10/03/vllm-weight-cache-serves-another-checkpoints-weights/), is the same pattern one level down: a check that passes on less than it claims to check.

The toolkit's `check-lora-patterns.py` reads `adapter_config.json` files, or every one under a directory. For each module whose pattern changes its scale, it prints PEFT's scale, vLLM's, and the factor between them. It doesn't flag `save_as_lora`-style adapters whose patterns keep every scale equal.
