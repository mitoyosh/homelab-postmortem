---
title: "llama-cli prints the error and exits 0. The same binary exits 1 when the model is missing."
date: 2026-09-01
excerpt: "A missing --image or --audio path is printed as an error and then reported as success. It is not that the exit status is unreliable in general: the same binary propagates a missing model correctly. One path prints and breaks, and run() has no failure path at all."
devto_tags: ai, linux, devops, bash
---

Point `llama-cli` at a file that isn't there:

```bash
$ llama-cli -m gemma-3-1b-it-Q4_K_M.gguf \
    --audio /tmp/does-not-exist.wav \
    -p test -n 1 --no-warmup --simple-io --single-turn
...
Error: file does not exist or cannot be opened: '/tmp/does-not-exist.wav'
...
$ echo $?
0
```

**It printed the error and returned success.** Both of those are true at the
same time, and only one of them is visible to the script that called it.

## It is not that the exit status is meaningless here

That was my first assumption and it is wrong, which matters, because "this tool
doesn't do exit codes properly" is a much less useful thing to know than what is
actually happening. Three controls, same binary, same machine:

```bash
# Missing media file
$ llama-cli -m model.gguf --audio /tmp/does-not-exist.wav ... ; echo $?
Error: file does not exist or cannot be opened: '/tmp/does-not-exist.wav'
0

# Missing image, to check this isn't audio-specific
$ llama-cli -m model.gguf --image /tmp/nope.png ... ; echo $?
Error: file does not exist or cannot be opened: '/tmp/nope.png'
0

# Same missing file, through llama-mtmd-cli instead
$ llama-mtmd-cli -m model.gguf --audio /tmp/does-not-exist.wav ... ; echo $?
1

# Missing *model*, through llama-cli
$ llama-cli -m /tmp/nope.gguf ... ; echo $?
gguf_init_from_file: failed to open GGUF file '/tmp/nope.gguf'
1
```

**The same binary returns 1 for a missing model and 0 for a missing media
file.** So the machinery to fail is present and works; one specific path does
not use it. `llama-mtmd-cli` returning 1 on the identical input rules out the
other easy explanation — this is not a limitation of what the media loader can
express upward.

## What the code actually does

From `tools/cli/cli-context.cpp` on master. The staging function reports failure
honestly and says nothing:

```cpp
bool cli_context::stage_media_file(const std::string & fname, const std::string & type) {
    std::ifstream file(fname, std::ios::binary);
    if (!file) {
        return false;
    }
```

Its caller — the loop that handles media given on the command line — prints the
message I saw, and then leaves the loop:

```cpp
for (auto & fname : params.image) {
    if (!stage_media_file(fname, media_type_from_ext(fname))) {
        ui::show_error(string_format("file does not exist or cannot be opened: '%s'", fname.c_str()));
        break;
    }
    ui::show_message(string_format("Loaded media from '%s'", fname.c_str()));
}
buffer = params.prompt;
```

**`break` ends the media loop and nothing else.** The next statement continues
into ordinary prompt handling, which is why the model still answered my prompt
in the run above — it answered it without the audio I asked for, having told me
so in a line that changed nothing.

And the function containing all this has exactly one exit:

```cpp
int cli_context::run() {
    ...
    return 0;   // the only return in the function
}
```

**There is no path through `run()` that returns non-zero.** Not "there is one
and this case misses it" — there isn't one.

## Where the upstream report and this disagree

[The issue](https://github.com/ggml-org/llama.cpp/issues/28095) — open,
`bug-unconfirmed`, no comments, no fix — attributes this to `run()` discarding
the return value of `generate_completion()`. That is a real defect: the function
is declared `bool`, and its caller does not look at the result.

**But it is not what fires here.** A missing file on the command line is handled
before generation starts, breaks out of the media loop, and never reaches that
call. Generation then runs normally and succeeds.

So there are **two independent routes to the same symptom** — a staging failure
that breaks without propagating, and a generation failure whose return value is
dropped — and they converge on a `run()` that cannot report failure either way.
Fixing only the one named in the report would leave the case in the report's own
reproduction command still returning 0.

## What I verified and what I didn't

Reproduced on **Linux x86_64**, build `b10703`, in a throwaway container, with a
**text-only** model — no multimodal model is needed, because the failure happens
while staging the file, before anything looks at what it contains. The upstream
report is from **Darwin arm64**, build `10706`. Different OS, different
architecture, different build, same behaviour.

I did **not** verify the generation-failure route by triggering it; I read it in
the source. I did not run the reporter's zero-byte-PNG cases. And I have not
checked whether any of this differs on macOS beyond taking the report at its
word.

## If you call this from a script

Until it is fixed, `llama-cli`'s exit status does not tell you whether your media
was loaded. Check the thing you actually care about instead:

```bash
out=$(llama-cli -m model.gguf --image "$img" -p "$prompt" ... 2>&1) || exit 1
if grep -q 'does not exist or cannot be opened' <<<"$out"; then
  echo "media failed to load" >&2
  exit 1
fi
```

Grepping output is a bad interface and I would rather not recommend it. It is
the only signal that is currently correct.

`llama-mtmd-cli` returns 1 on the same input, so if your use is multimodal
anyway, it is the better call today — not because it is a workaround, but
because it is the tool that reports what happened.

## The generalisable habit

The error text and the exit status came from two different places in the
program, and nothing keeps them consistent. `ui::show_error` is a print. `return
0` is a claim. A tool can do both in the same run, and every layer above it —
your shell, your `set -e`, your CI step, your retry loop — is reading only the
second one.

So the habit is narrow: **when you automate a tool, verify that its failure
actually reaches its exit status, using a case you know is broken.** Point it at
a file that does not exist and read `$?`. It takes one command, and it is the
only way to find out whether the thing your automation depends on is load-
bearing or decorative.

The wider version is about which artefact you trust. A message on the terminal
is written for a human who is watching. An exit status is the only thing a
program downstream can see. When those two disagree, the human sees a failure
and the machine sees success — and the pipeline keeps running on the machine's
version.
