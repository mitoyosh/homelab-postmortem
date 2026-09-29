---
title: "Ollama 0.34 logs your OLLAMA_GPU_OVERHEAD reservation as applied. The llama-server that places the layers never receives it."
date: 2026-09-28
excerpt: "Ollama 0.34 runs GGUF models through a bundled llama-server, and with the default num_gpu the layer placement is llama-server's --fit, which keeps its own 1 GiB margin. OLLAMA_GPU_OVERHEAD is read, printed, and subtracted in the scheduler's log line, then not passed on. On an 8 GB RTX 2070 a 6 GiB reservation logged available=543 MiB and left 5051 MiB free, the same as no reservation. LLAMA_ARG_FIT_TARGET=6144 held it. A reservation larger than the card wraps around and raises the default context instead."
devto_title: "Ollama 0.34 logs OLLAMA_GPU_OVERHEAD as applied, but llama-server never receives it"
devto_tags: ollama, llm, selfhosted, gpu
---

**TL;DR**: Since Ollama moved GGUF models onto a bundled `llama-server`, the default `num_gpu` means Ollama passes no `-ngl` and lets llama-server's `--fit` decide how many layers go on the GPU. `--fit` keeps its own free-memory margin, `LLAMA_ARG_FIT_TARGET`, 1024 MiB by default. `OLLAMA_GPU_OVERHEAD` is read, printed in the `server config` line, and subtracted in the scheduler's `gpu memory ... available=` line, but nothing passes it to llama-server. On an RTX 2070 (8 GB) with Ollama 0.34.4 and `qwen2.5:3b`, a 6 GiB reservation logged `available="543.0 MiB"` and then loaded all 37 layers, leaving 5051 MiB free, against 5059 MiB with no reservation at all. `LLAMA_ARG_FIT_TARGET=6144` did hold it: 14 of 37 layers on the GPU, 6139 MiB free. Separately, a reservation larger than the card makes Ollama compute "total VRAM minus overhead" as a wrapped-around unsigned number, and the default context goes *up*: 4096 to 32768 tokens, 1.1 GB more VRAM. Set the reservation as `LLAMA_ARG_FIT_TARGET` instead: it is in MiB, and it replaces llama-server's 1024 MiB margin, so add 1024 to it. The toolkit's `check-ollama-gpu-overhead.sh` compares the reservation against free VRAM with the model loaded. Upstream report: [ollama/ollama#18679](https://github.com/ollama/ollama/issues/18679).

## The symptom

`OLLAMA_GPU_OVERHEAD` exists for sharing a GPU: reserve some VRAM for the desktop, a game, or another service, and let Ollama plan around what is left. The report that led here said that on 0.34.4 the variable no longer changed how much VRAM stayed free. The reporter had not posted measurements, so here are some.

Windows 11, RTX 2070 8 GB (driver 591.86), Ollama 0.34.4 from the release zip, `qwen2.5:3b` (a text model, 1.9 GB). Each arm is a fresh `ollama serve` with only the variables shown, then `ollama run qwen2.5:3b "..."`, `ollama ps`, and `nvidia-smi`. With nothing loaded, 780 MiB was in use and 7227 MiB free:

```
arm                              ollama ps           layers on GPU   free with model loaded
no variables                     100% GPU            37/37           5059 MiB
OLLAMA_GPU_OVERHEAD=6442450944   100% GPU            37/37           5051 MiB
LLAMA_ARG_FIT_TARGET=6144        58%/42% CPU/GPU     14/37           6139 MiB
```

Six GiB reserved, five GiB free, and the placement identical to not setting it.

The Linux build of 0.34.4, run under WSL2 on the same card, gave the same result: `100% GPU` and 5051 MiB free with the 6 GiB reservation.

## Why it's easy to miss

Everything you can check without measuring says the reservation is in effect. The arm with `OLLAMA_GPU_OVERHEAD` set logs, at startup:

```
msg="server config" env="map[... OLLAMA_GPU_OVERHEAD:6442450944 ...]"
msg="vram-based default context" total_vram="2.0 GiB" default_num_ctx=4096
```

and, at load time:

```
msg="gpu memory" id=0 library=CUDA available="543.0 MiB" free="7.0 GiB" minimum="457.0 MiB" overhead="6.0 GiB"
```

The value was parsed, the total was reduced by it, and the scheduler printed an available figure with it taken off. Two lines later, llama-server makes its own decision against its own number:

```
common_params_fit_impl: projected to use 2059 MiB of device memory vs. 7144 MiB of free device memory
common_params_fit_impl: will leave 5084 >= 1024 MiB of free device memory, no changes needed
load_tensors: offloaded 37/37 layers to GPU
```

Those `fit` lines are byte-for-byte the same as in the arm with no variables.

Searching for the symptom leads somewhere else. The most visible thread is [ollama/ollama#12223](https://github.com/ollama/ollama/issues/12223), "OLLAMA_GPU_OVERHEAD is not respected", closed as completed. That one was a Windows `set OLLAMA_GPU_OVERHEAD = ...` with spaces around the `=`, which defines a variable with a different name. Its log showed `OLLAMA_GPU_OVERHEAD:0`, and it predates the llama-server runner. Here the log shows the right value. The "check your syntax" answer does not apply.

## What's really going on

In the 0.34.4 source (`llm/llama_server.go`), Ollama only passes `-ngl` when you set `num_gpu` yourself:

```go
if launch.opts.NumGPU > 0 {
    params = append(params, "-ngl", strconv.Itoa(launch.opts.NumGPU))
} else if launch.opts.NumGPU == 0 {
    params = append(params, "-ngl", "0")
}
// NumGPU == -1 (default): don't pass -ngl, let llama-server auto-detect
```

The logged command line confirms it: `-c 4096 -np 1 ... --flash-attn auto -b 512 -ub 512`, no `-ngl`. With no layer count, llama-server's `--fit` chooses one that leaves `LLAMA_ARG_FIT_TARGET` MiB free. Ollama sets that variable in one case only, for models with a vision projector, to the projector's size plus 1 GiB. For a text model it is not set, and llama-server uses its default of 1024 MiB.

The reservation is subtracted in `server/sched.go`, into a local variable that goes to the log:

```go
available := gpu.FreeMemory - envconfig.GpuOverhead() - gpu.MinimumMemory()
...
slog.Info("gpu memory", ..., "available", format.HumanBytes2(available), ...)
gpuIDs, err := llama.Load(req.ctx, systemInfo, loadGpus, requireFull)
```

`available` is not passed to `Load`, and the llama-server runner's `Load` does not look at free memory at all. It waits for llama-server to come up and returns every GPU's ID. `GpuOverhead` does not appear anywhere in `llm/llama_server.go`.

The source reading alone doesn't prove that `--fit` is the thing deciding placement, which is what the third arm is for. Setting `LLAMA_ARG_FIT_TARGET=6144` changed the outcome from 37 layers to 14, and the free VRAM followed. The knob that works is the one Ollama doesn't set.

### A reservation larger than the card makes it worse

The startup line that picks the default context computes, in `server/routes.go`:

```go
totalVRAM += gpu.TotalMemory - envconfig.GpuOverhead()
```

Both are unsigned 64-bit. If the reservation is larger than the card, the subtraction wraps around to a number near 2^64. With `OLLAMA_GPU_OVERHEAD` set to 16 GiB on the 8 GB card:

```
msg="vram-based default context" total_vram="17179869176.0 GiB" default_num_ctx=262144
msg="gpu memory" ... available="0 B" free="7.0 GiB" minimum="457.0 MiB" overhead="16.0 GiB"
common_params_fit_impl: will leave 3940 >= 1024 MiB of free device memory, no changes needed
llama_kv_cache: size = 1152.00 MiB ( 32768 cells, ...)

NAME          SIZE      PROCESSOR    CONTEXT
qwen2.5:3b    3.4 GB    100% GPU     32768
```

The top context tier, 262144, was capped by the model's own limit at 32768. The KV cache went from 144 MiB to 1152 MiB and free VRAM dropped to 3907 MiB, so asking for more headroom got you 1.1 GB less of it. The reservation is per GPU, so one way to end up here is a value carried over from a machine with a bigger card.

The one real effect a sane `OLLAMA_GPU_OVERHEAD` has on this runner comes from the same line: it lowers the VRAM figure used to pick the default context tier (4096 below 23 GiB, 32768 below 47 GiB, 262144 above). That is from reading the source. On an 8 GB card every value lands in the 4096 tier, so it was not observable here.

## The fix

Reserve the space where llama-server reads it. `LLAMA_ARG_FIT_TARGET` is in **MiB**, where `OLLAMA_GPU_OVERHEAD` is in bytes, and it *replaces* llama-server's default 1024 MiB margin rather than adding to it. With a target of 6144 the measured free VRAM was 6139 MiB, 5 MiB short, because the target is checked against llama-server's projection of its own use, not against what the driver reports afterwards. The 1024 MiB default leaves room for that kind of gap. To reserve 6 GiB and keep the slack, set it to the reservation plus 1024:

```
LLAMA_ARG_FIT_TARGET=7168
```

On an 8 GB card that is a test setting rather than a useful one. With 7168 on the Linux build, fit put 0 of 37 layers on the GPU and 7023 MiB stayed free. The reservation held, and it left no room for the model.

It goes wherever `OLLAMA_GPU_OVERHEAD` goes now, in the environment `ollama serve` starts with. Ollama's FAQ gives the steps for its own variables, and they apply unchanged: `systemctl edit ollama.service` and an `Environment="LLAMA_ARG_FIT_TARGET=7168"` line under `[Service]` on Linux, a user environment variable followed by quitting and restarting the tray app on Windows. The measurement above started `ollama serve` directly with the variable set, and not through either of those. Whichever way you start it, the process's own `server config` line shows whether the value arrived. In the third arm it read `LLAMA_ARG_FIT_TARGET:6144`.

Then check the one number that matters. Load the model and look at free VRAM, not the log:

```bash
ollama run qwen2.5:3b ""
ollama ps
nvidia-smi --query-gpu=memory.free --format=csv
```

Two caveats:

- **Vision models.** When Ollama sets `LLAMA_ARG_FIT_TARGET` itself, it adds the projector's size plus 1 GiB. When the variable is already in the environment, it leaves your value alone, so the projector eats into your reservation. Add the projector's size plus 1 GiB yourself.
- **Leaving `OLLAMA_GPU_OVERHEAD` set** does nothing to placement, but it still lowers the default context tier on large cards and wraps around if it exceeds the card. If it only exists to reserve VRAM, remove it.

A fix is proposed in [ollama/ollama#18680](https://github.com/ollama/ollama/pull/18680). It sets `LLAMA_ARG_FIT_TARGET` to the reservation in MiB, plus the projector margin for vision models. As its diff reads, that value also replaces the 1024 MiB default. A reservation smaller than 1 GiB would then give a smaller target than setting none, so on a model that has to be squeezed it can leave *less* free VRAM. That is from reading the patch, which was not built here. The patch changes `llm/` only, so the context-default wraparound in `routes.go` is not part of it. As of this writing it is open and unreviewed, and 0.34.4 is the latest release.

## The generalisable habit

A log line that prints a value computed from your setting is a statement of what the program meant to do. Here the variable was parsed, displayed, and used in arithmetic for log lines and a context default, and none of that reached the component that decides. When a setting exists to produce a physical outcome, like free VRAM, free disk, or an open port, measure that outcome with and without it. Run a positive control too: one change you know should move the measurement. Without the `LLAMA_ARG_FIT_TARGET` arm, "free VRAM didn't change" could just as well have meant this model fits either way. With it, the measurement was shown to be able to move, and the reservation still didn't move it.

The same reading applies to llama-server's own options: [`--cache-ram -1` is documented as "no limit"](https://homelabpostmortem.com/2026/09/24/llama-server-cache-ram-minus-one-is-not-no-limit/) and behaves as something else. In both cases, only a measurement of what the setting was supposed to change showed the gap. A day later the same program showed the other half of it: [`ollama show` prints a model's temperature and top_p, and the OpenAI-compatible API replaces both with 1.0](https://homelabpostmortem.com/2026/09/29/ollama-openai-api-replaces-your-model-temperature-with-1/) unless the client sends them.

The toolkit's `check-ollama-gpu-overhead.sh` reads `OLLAMA_GPU_OVERHEAD` and `LLAMA_ARG_FIT_TARGET` from the running `ollama serve` and its llama-server child. With a model loaded, it compares the reservation against measured free VRAM. It also flags a value that isn't a plain byte count, which Ollama logs as invalid and replaces with 0, and one that is larger than the card.
