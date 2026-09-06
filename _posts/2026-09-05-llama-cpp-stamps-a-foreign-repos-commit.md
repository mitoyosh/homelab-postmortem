---
title: "llama-cli reports a commit hash that is not in llama.cpp. It belongs to whatever repository you unpacked the source inside."
date: 2026-09-05
excerpt: "A release tarball extracted anywhere inside an unrelated git work tree makes CMake stamp that repository's HEAD into the binary. Configure exits 0 with no warning, the dirty flag stays silent because untracked files are not diffs, and the obvious override fixes llama's copy of the value while leaving ggml's wrong."
devto_tags: cmake, ai, linux, devops
---

**TL;DR**: `cmake/build-info.cmake` runs `git rev-parse --short HEAD` with `WORKING_DIRECTORY` set to the source directory and accepts the result if the command succeeded. Git searches *upward*, so a release tarball unpacked anywhere inside an unrelated git work tree gets that repository's HEAD stamped into the binary, `llama-config.cmake`, and `ggml-config.cmake`. Nothing warns: configure exits 0, and the `-dirty` suffix never fires because the entire source tree is untracked and untracked files are not diffs. `-DLLAMA_BUILD_COMMIT=` looks like the fix and only half is — `ggml/CMakeLists.txt` runs its own unguarded probe and overwrites it, and `-DGGML_BUILD_COMMIT=` is ignored.

## The symptom

Built from the `b10816` release tarball, on Debian 13, CMake 3.31.6, GCC 14.2.0:

```bash
$ ./llama-cli --version
version: 0.4.0-dev (build 1, commit 00621a7)
built with GNU 14.2.0 for Linux x86_64
```

That is a well-formed seven-character hash in the field where a well-formed
seven-character hash belongs. It is not a llama.cpp commit:

```bash
$ gh api repos/ggml-org/llama.cpp/commits/00621a7
No commit found for SHA: 00621a7 (HTTP 422)
```

`00621a7` is the HEAD of a repository I created two directories up, with one
empty commit, whose commit message is "totally unrelated repo, not llama.cpp".
The build found it, believed it, and printed it with no hedging.

The tag actually being built, `b10816`, is commit `427291b`. That value appears
nowhere in the build.

## Reproducing it takes three commands and no compiler

The whole thing is decided during `cmake` configure. You do not have to build
anything to see it:

```bash
mkdir -p /tmp/demo/outer && cd /tmp/demo/outer
git init -q . && git commit -q --allow-empty -m "totally unrelated repo"
git rev-parse --short HEAD          # -> 00621a7

curl -sSL https://github.com/ggml-org/llama.cpp/archive/refs/tags/b10816.tar.gz | tar xz
cmake -S llama.cpp-b10816 -B build -DGGML_CUDA=OFF -DLLAMA_CURL=OFF >/dev/null
grep LLAMA_COMMIT build/src/llama-version.h
```

```
#define LLAMA_COMMIT  "00621a7"
```

Configure exits 0. There is no warning in the output.

## It is not that build info is unreliable in general

That was worth checking before writing any of this down, because "the commit
field is junk" is a much less useful thing to know than what is actually
happening. Three builds, same tarball where applicable, same machine, same
CMake:

```
source                                    LLAMA_COMMIT   BUILD_NUMBER
tarball, inside an unrelated git repo     "00621a7"      1
tarball, not inside any git repo          "unknown"      0
real git clone of the b10816 tag          "427291b"      1
```

**The honest case and the correct case both work. Only the middle situation
lies, and it is the only one of the three that lies confidently.** With no git
repository anywhere above it, the build says `unknown` — which is exactly the
right answer and is impossible to misread. With a real clone it says
`427291b`, which is right. The failure needs a git repository that exists, is
readable, and has nothing to do with the source.

Note the third column, because it removes the tell you would hope for. A
legitimate shallow clone reports `BUILD_NUMBER 1` too — `git rev-list --count
HEAD` on a `--depth 1` clone is 1. So "the build number looks too small" is not
evidence of anything.

## Why nothing catches it

**The dirty flag is structurally blind to this case.** `ggml/CMakeLists.txt`
checks whether the tree is modified and appends `-dirty` if so. That check is
the one thing in the build that could plausibly notice that the source does not
belong to the repository being credited. It cannot:

```bash
$ git status --porcelain llama.cpp-b10816
?? llama.cpp-b10816/

$ git -C llama.cpp-b10816 diff-index --quiet HEAD -- . ; echo $?
0
```

Exit 0 means clean. The source tree shares **zero** files with the repository
whose commit is about to be stamped on it, and the modification check reports
no modifications — because untracked files are not diffs. A tree with nothing
in common reads as pristine, so the hash goes out unqualified.

**The wrong value does not stay in the binary.** It is written into the CMake
package files that downstream projects consume after `make install`:

```bash
$ grep BUILD_COMMIT build/llama-config.cmake build/ggml/ggml-config.cmake
build/llama-config.cmake:set(LLAMA_BUILD_COMMIT 00621a7)
build/ggml/ggml-config.cmake:set(GGML_BUILD_COMMIT "00621a7")
```

Anything that later does `find_package(llama)` inherits the claim.

## What's really going on

`cmake/build-info.cmake` asks git a question from inside the source directory
and accepts any answer that came back successfully:

```cmake
execute_process(
    COMMAND ${GIT_EXECUTABLE} rev-parse --short HEAD
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    OUTPUT_VARIABLE HEAD
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE RES
)
if (RES EQUAL 0)
    set(BUILD_COMMIT ${HEAD})
endif()
```

The guard is `RES EQUAL 0` — *did git succeed anywhere* — and git's search for a
repository walks up the directory tree until it finds one or hits a mount
point. There is no check that the repository it found contains these files, is
named llama.cpp, or has ever heard of them. Extracting a tarball two levels
below someone else's `.git` is enough.

This is reported upstream as
[`ggml-org/llama.cpp#28397`](https://github.com/ggml-org/llama.cpp/issues/28397),
opened 2026-09-04 with a real-world case: the Arch AUR `llama.cpp-cuda` package
builds inside the cloned packaging repository, so two published versions
credited the *packaging* repo's commits. As of this writing the issue is open
with no comments and nothing referencing it.

## The fix, and the half of it that looks like the whole

The obvious move is the documented override. `CMakeLists.txt` guards both
values with `if (NOT DEFINED ...)`, so passing them on the command line wins:

```bash
cmake -S llama.cpp-b10816 -B build -DLLAMA_BUILD_COMMIT=427291b -DLLAMA_BUILD_NUMBER=10816
```

Check it and it worked:

```bash
$ grep LLAMA_COMMIT build/src/llama-version.h
#define LLAMA_COMMIT  "427291b"
$ grep BUILD_COMMIT build/llama-config.cmake
set(LLAMA_BUILD_COMMIT 427291b)
```

**Now check the other header.**

```bash
$ grep GGML_COMMIT build/ggml/src/ggml-version.h
#define GGML_COMMIT  "00621a7"
```

Still the foreign repository. `CMakeLists.txt` does pass the corrected value
down as `GGML_BUILD_COMMIT` immediately before `add_subdirectory(ggml)` — and
then `ggml/CMakeLists.txt` runs its own probe, which has no `if (NOT DEFINED)`
guard at all, and assigns straight over the top of it:

```cmake
find_program(GIT_EXE NAMES git git.exe NO_CMAKE_FIND_ROOT_PATH)
if(GIT_EXE)
    execute_process(COMMAND ${GIT_EXE} rev-parse --short HEAD
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        OUTPUT_VARIABLE GGML_BUILD_COMMIT
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
```

There is no command-line escape from it either. Passing the variable directly
is silently discarded, because the `execute_process` result is a normal
variable that shadows the cache entry:

```bash
$ cmake -S llama.cpp-b10816 -B build -DGGML_BUILD_COMMIT=427291b 2>&1 | grep 'ggml commit'
-- ggml commit:  00621a7
```

CMake prints the wrong value to the terminal, as a status line, in the middle
of a configure run nobody reads to the end.

**What works is denying the upward search.** Give the extracted source its own
repository, so git stops there instead of reaching the stranger:

```bash
git -C llama.cpp-b10816 init -q
cmake -S llama.cpp-b10816 -B build -DGGML_CUDA=OFF -DLLAMA_CURL=OFF >/dev/null
```

```
#define LLAMA_COMMIT  "unknown"
#define GGML_COMMIT   "unknown"
```

A fresh repository has no `HEAD` to resolve, so both probes fail and both fall
back to their honest default. `unknown` is not a cosmetic loss — it is the
correct statement about a tarball, and it is the value you would have got by
building in a directory that was not inside anyone's repository in the first
place. Moving the source tree out from under the foreign `.git` does the same
thing and is better when you control the layout.

If you package llama.cpp, use both: `git init` the extracted tree *and* pass
`-DLLAMA_BUILD_COMMIT` with the real hash. The first stops ggml lying, the
second gives llama the true value.

To find out whether any of this applies to a build you already shipped, ask
your binary and then ask upstream:

```bash
COMMIT=$(./llama-cli --version 2>&1 | sed -n 's/.*commit \([0-9a-f]*\).*/\1/p')
git ls-remote https://github.com/ggml-org/llama.cpp.git | grep -q "^$COMMIT" \
  || echo "reported commit $COMMIT is not in llama.cpp"
```

## The generalisable habit

The narrow lesson is about provenance derived from ambient state. A build that
reports *what it is* by looking at its surroundings will report whatever the
surroundings say, and directory nesting is not a statement of identity. The
check that was missing is one line — does the repository git found actually
track these files — and it is missing in both probes.

The wider one is the reason this took longer than the reproduction did.
Overriding `LLAMA_BUILD_COMMIT` produces two pieces of evidence that the fix
worked, in the two places you would naturally look, and a third file that is
still wrong. If the habit is "apply the fix, check the field, move on", this
ends with a build that is half-corrected and believed to be corrected —
which is worse than the original, because now there is a memory of having
handled it. The same shape as [a journald drop-in that is correct and still
does nothing until you flush](https://homelabpostmortem.com/2026/08/18/trixie-journald-volatile-logs/):
**the fix being real is not the same as the fix being complete, and only the
second one is worth anything.**

And it is the second time in a week that this project's build and CLI have
reported success in a field that was not true —
[`llama-cli` prints a file error and exits 0](https://homelabpostmortem.com/2026/09/01/llama-cli-exits-0-when-it-cannot-read-your-file/)
is the same failure at runtime. When you report a bug upstream, the first thing
you are asked for is `--version` output. It is worth knowing that the line can
be confidently, specifically wrong.

The same shape shows up two days later in the artifact rather than the build
metadata: [an Ollama tag that pulls and runs and streams fluent text with no
working code in
it](https://homelabpostmortem.com/2026/09/07/ollama-library-quant-is-broken-not-the-quant-level/),
where every surrounding signal — verified download, correct file size, normal
token rate, HTTP 200 — reports success and only the content is wrong.
