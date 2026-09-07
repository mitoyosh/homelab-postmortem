---
title: "vLLM accepts a LoRA adapter it has already decided not to apply anywhere, and answers every request with the base model instead."
devto_title: "vLLM accepts a LoRA it will never apply, and answers with the base model instead"
date: 2026-09-07
excerpt: "Restrict a deployment with --lora-target-modules and load an adapter whose modules fall outside that list, and nothing objects. The adapter loads, the LoRA kernels compile, and every response is the unmodified base model, byte for byte. The check that accepts an adapter and the check that applies it read different fields."
devto_tags: ai, vllm, llm, devops
---

**TL;DR**: `vllm serve --lora-target-modules qkv_proj` plus an adapter that only touches `down_proj` is a combination vLLM accepts. It loads the adapter, compiles the LoRA kernels, and then wraps zero layers with it — every request comes back as the unmodified base model, byte for byte, with no error, no rejection, and no warning that mentions `target_modules`. The acceptance path reads `supported_lora_modules`; the application path reads that **and** `lora_config.target_modules`. The second list is the one you set on the command line, and only one of the two checks has heard of it.

## The symptom

Same adapter file, same prompt, `temperature 0`, `seed 42`. The only thing that changes between these two runs is the deployment's allow-list.

```
--lora-target-modules down_proj      (overlaps the adapter)

  base : " Paris. It is the largest city in the world by population. It is
          located in the south of France. It is"
  lora : ":\nA. Paris\nB. London\nC. Rome\nD. Moscow\nAnswer:\n\nA\n\nWhich of the"
```

```
--lora-target-modules qkv_proj       (disjoint from the adapter)

  base : " Paris. It is the largest city in the world by population. It is
          located in the south of France. It is"
  lora : " Paris. It is the largest city in the world by population. It is
          located in the south of France. It is"
```

The second pair is byte-identical. The request carried a `LoRARequest`, it returned 200, and it was served by the base model.

Verified on vLLM 0.28.0, `Qwen/Qwen2.5-0.5B-Instruct`, an RTX 2070 under WSL2.

## It is not that the adapter failed to load

That was the first hypothesis and it is wrong, which matters, because "my adapter path was bad" sends you looking in a place where there is nothing to find. vLLM stands up the entire LoRA machinery for a request it is about to serve without any LoRA in it:

```
WARNING [jit_monitor.py:141] Triton kernel JIT compilation during inference: _lora_shrink_kernel
WARNING [jit_monitor.py:141] Triton kernel JIT compilation during inference: _lora_expand_kernel
```

Those two kernels *are* LoRA. A LoRA layer computes `y = Wx + B(Ax)`: shrink is `Ax`, projecting down to the adapter's rank, and expand is `B(...)`, projecting back up. Both were compiled, for this request, on the run that returned base-model output. The adapter was read, registered and activated. It was simply attached to nothing.

So the search space is not "why was my adapter rejected". Nothing was rejected.

## What's really going on

Two checks, and they do not read the same thing. From the installed 0.28.0, not from the report:

```python
>>> "supported_lora_modules" in inspect.getsource(WorkerLoRAManager._load_adapter)
True
>>> "target_modules" in inspect.getsource(WorkerLoRAManager._load_adapter)
False
```

The acceptance path validates the checkpoint against `supported_lora_modules` — the set of module types vLLM can wrap for this architecture at all. `qkv_proj`, `o_proj`, `gate_up_proj`, `down_proj` for a Qwen2 model. An adapter targeting `down_proj` passes, because `down_proj` is a thing vLLM knows how to wrap.

The application path asks a second question:

```python
def _match_target_modules(self, module_name: str) -> bool:
    if not is_supported_lora_module(module_name, self.supported_lora_modules):
        return False
    return is_in_target_modules(
        module_name,
        self.lora_config.target_modules,
        self.packed_modules_mapping,
    )
```

`lora_config.target_modules` is `--lora-target-modules`. It is consulted here and nowhere upstream of here. So the adapter is judged twice, against a permissive list and then a restrictive one, and **only the permissive judgement can produce a message.** By the time the restrictive one runs, the answer is not "reject this adapter" — it is "wrap this module: no", asked once per module, and every answer is no.

Zero wrapped modules is not an error state anywhere. It is just a loop that did nothing.

## Who this reaches, and who it does not

Not everyone, and the shape of who matters, because it explains why a bug this loud in its consequences is this quiet in the wild.

**If you never pass `--lora-target-modules`, you cannot hit this.** The allow-list then defaults to everything the architecture supports, so the restrictive list and the permissive list are the same list and the two checks agree. Most single-adapter deployments look like this.

**You hit it by deliberately narrowing the deployment** — restricting to `qkv_proj` to bound memory, say, or to keep a serving profile stable across adapters — and then loading an adapter someone else trained, whose modules you did not check against your own restriction. That is a multi-tenant, many-adapters shape. It is also exactly the shape where nobody is reading individual responses closely enough to notice they got the base model.

## The fix

Upstream has one in flight: [`vllm-project/vllm#55310`](https://github.com/vllm-project/vllm/pull/55310), "Reject adapters with no matching target modules", open and unmerged at the time of writing. Until it lands, nothing in vLLM will tell you.

**Check the two lists against each other before you deploy.** The adapter states its own in `adapter_config.json`:

```bash
python3 -c '
import json,sys
cfg = json.load(open(sys.argv[1] + "/adapter_config.json"))
adapter = set(cfg["target_modules"])
deployed = set(sys.argv[2].split(","))
print("adapter :", sorted(adapter))
print("deployed:", sorted(deployed))
print("overlap :", sorted(adapter & deployed) or "NONE — this adapter will be ignored")
' /path/to/adapter qkv_proj,o_proj
```

Note that packed modules make the comparison less obvious than it looks: an adapter naming `q_proj`, `k_proj` and `v_proj` overlaps a deployment naming `qkv_proj`, because vLLM fuses them. A plain string comparison will report a false alarm there.

**And confirm it end to end, once, with a prompt you know the answer to.** Send the same prompt with and without the `LoRARequest` at `temperature 0`:

```
identical output  ->  the adapter is doing nothing
different output  ->  it is applied
```

That is the only signal that cannot be faked by a mechanism that reports success. It costs two requests.

If you are building the adapter yourself to test this, know that `peft` initialises `lora_B` to zeros, so a freshly created, untrained adapter produces identical output **whether or not it is applied**. Mine had to be given non-zero `lora_B` deliberately, or the control would have proved nothing.

## The generalisable habit

The narrow lesson is about validation that runs before the decision it is supposed to guard. Accepting an adapter and applying an adapter were separated by a config field that only the second step could see, and only the first step had a voice. Any time a system says yes in one place and acts in another, the interesting question is not "does it validate?" but **"does the thing that validates know everything the thing that acts knows?"** Here it did not, by one field.

The wider one is about what counts as a control. My first instinct was to load the adapter, see base-model output, and call it reproduced. That would have been worthless: an adapter that does nothing when ignored also does nothing when applied, if it was never trained. The result only means something because the *same adapter file* changed the output under a different allow-list. **A negative result is evidence only after the positive one has been shown on the same setup** — otherwise you have measured your own test rig.

It is the same trap as [an Ollama tag that pulls and runs and has no working code in
it](https://homelabpostmortem.com/2026/09/07/ollama-library-quant-is-broken-not-the-quant-level/),
where the control had to run first to catch a broken harness. Both times the failing observation was
available immediately and agreed with the report, and both times it would have been the wrong reason.
