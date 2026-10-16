# Git worktrees inside a workspace: dynamic indexing redoes its work for every copy

Tools that run coding agents in parallel give each agent its own git worktree, and some put those
worktrees inside the repository. Claude Code, for example, uses `<repo>/.claude/worktrees/<name>`.
It does not gitignore that folder; [its docs](https://code.claude.com/docs/en/worktrees) suggest
you do. When the repository is open in an editor, each worktree is a full copy of it inside the
workspace, and every `Project.toml` in that copy is another environment.

With dynamic indexing on, JuliaWorkspaces launches an indexing child process for each environment
in each copy, even when the copy is the commit just indexed. A new worktree has no
`Manifest.toml` (it is usually gitignored), so each of its environments is "an environment
without a manifest (only a child can produce it)". In the repository below, 3 worktrees cost 12
Julia processes, 3 to 5 minutes of CPU, and a peak of 4 to 6 GB. The symbol store ends up with no
package it did not already have.

Three settings avoid it today, and each gives something up:

| setting | worktree cost | gives up | available |
| --- | --- | --- | --- |
| `.claude/worktrees/` in `.gitignore` or `.git/info/exclude` | none | the worktrees are no longer part of the workspace; each repository (or each clone) needs the rule | `main` (julia-vscode/JuliaWorkspaces.jl#353, julia-vscode/LanguageServer.jl#1485), pre-release extension 1.250.1; not stable 1.249.2 |
| `julia.enableWorkspaceEnvironmentResolution = false` | none | no environment without a manifest is resolved, in the main checkout either | `main` and stable 1.249.2 |
| `julia.enableDynamicIndexing = false` | none | no local indexing anywhere | always |

LanguageServer re-reads ignore rules when a `.gitignore` changes, but it does not watch
`.git/info/exclude`, so a rule added there applies after the language server restarts.

What we would like is **dynamic indexing that does not repeat itself**. When an environment
resolves to what the workspace has already indexed, such as the same commit checked out again, it
should reuse that work and not launch another child. Worktrees could then stay in the workspace
with indexing on, without the ignore rule.

## Reproduce

```bash
julia +1.12 mwe.jl
julia +1.13 mwe.jl
```

[`mwe.jl`](mwe.jl) needs git and network access (General registry and
`symbolcache.julialang.net`). It takes about 20 minutes on an empty depot, most of that installing
and precompiling, and 4 to 6 minutes after that. Packages go into the default depot, which
indexing children always use. Options: `--worktrees N` (default 3), `--rev REV` (JuliaWorkspaces
revision, default `main`), `--scenarios a,b`, `--work DIR`. The memory column needs Linux
(`/proc`).

What it does:

1. Adds JuliaWorkspaces at `--rev` from GitHub to a new environment.
2. Builds a small git repository: a package `Demo` with no dependencies, plus `docs/` (Documenter,
   and `Demo` through `[sources]`), `benchmark/` (BenchmarkTools, DataFrames) and `examples/`
   (JSON3, StaticArrays). `Manifest.toml` is gitignored, and every environment is instantiated, as
   in a developer's checkout.
3. For each scenario, in a new copy of the repository, with an empty symbol store and in a
   process of its own:
   - **startup**: opens the repository as a workspace folder, as the language server does, and
     waits until dynamic indexing has nothing left to do;
   - **worktrees**: runs `git worktree add --detach .claude/worktrees/agent-<hex> HEAD` once per
     worktree. It adds each new folder the way the language server handles a "folder created" file
     watcher event (walked with the workspace folder's git ignore rules), then waits again.

Every scenario uses the language server's defaults: `DynamicIndexingOnly` with at most 4 children
at a time. It also turns on `symbolcache_download` (the `julia.symbolCacheDownload` opt-in), so
startup is served from the cloud cache where it can be.

| scenario | setting |
| --- | --- |
| `default` | none |
| `gitignored` | `.claude/worktrees/` in the repository's `.gitignore` |
| `no-env-resolution` | `julia.enableWorkspaceEnvironmentResolution = false` |
| `dynamic-off` | `julia.enableDynamicIndexing = false` |

## Results

JuliaWorkspaces `main` at 3332231 (the version in extension 1.250.1), stock Julia from juliaup,
empty depot, Linux, 16 cores, 27 GB, 2026-10-17.

Julia 1.12.7:

| scenario | phase | indexing children | skipped | children CPU (s) | time to idle (s) | peak memory (GB) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| default | startup | 0 | 0 | 2 | 14 | 1.3 |
| default | worktrees | **12** | 0 | **276** | 71 | **5.8** |
| gitignored | startup | 0 | 0 | 2 | 16 | 1.2 |
| gitignored | worktrees | 0 | 0 | 0 | 0 | 1.1 |
| no-env-resolution | startup | 0 | 0 | 2 | 16 | 1.3 |
| no-env-resolution | worktrees | 0 | 0 | 0 | 0 | 1.1 |
| dynamic-off | startup | 0 | 0 | 1 | 13 | 1.3 |
| dynamic-off | worktrees | 0 | 12 | 0 | 3 | 1.3 |

Julia 1.13.2:

| scenario | phase | indexing children | skipped | children CPU (s) | time to idle (s) | peak memory (GB) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| default | startup | 3 | 0 | 41 | 23 | 3.3 |
| default | worktrees | **12** | 0 | **168** | 45 | **3.7** |
| gitignored | startup | 3 | 0 | 42 | 23 | 3.3 |
| gitignored | worktrees | 0 | 0 | 0 | 1 | 0.7 |
| no-env-resolution | startup | 3 | 0 | 43 | 23 | 3.3 |
| no-env-resolution | worktrees | 0 | 0 | 0 | 1 | 0.7 |
| dynamic-off | startup | 0 | 3 | 1 | 9 | 0.9 |
| dynamic-off | worktrees | 0 | 12 | 0 | 2 | 0.9 |

- **Each worktree launches 4 children**: one "creating a standalone project" for the package and
  one "resolving an environment without a manifest" for each of `docs/`, `benchmark/` and
  `examples/`. They produce nothing new. After them the store holds the same files, except that on
  1.12 the entry for `Demo` itself was rewritten.
- **Memory peaks at 4 to 6 GB**, held down only by the limit of 4 children at a time. Further
  worktrees queue behind that limit.
- **Startup on 1.13** needs 3 children because the cloud cache lacks some 1.13 packages ("14 not
  available in cloud cache"). With dynamic indexing off those packages stay without symbols, the 3
  skipped items.
- **The same run with the version in the stable extension** (851b0e0, Julia 1.12.7) differs in
  one place. `gitignored` launches the same 12 children as `default` (285 s of CPU, 5.2 GB), because
  that version does not read git ignore rules. `no-env-resolution` launches none there either.

Columns:

- **indexing children**: children launched in that phase (`Spawning indexing child process` log lines).
- **skipped**: work items that would have needed a child, with dynamic indexing off.
- **children CPU**: CPU time of the child processes that ended in that phase
  (`getrusage(RUSAGE_CHILDREN)`). At startup it includes a check of about one second that the
  workspace runs on the child Julia.
- **time to idle**: until dynamic indexing has nothing left to do.
- **peak memory**: highest PSS summed over the workspace process and all its children. PSS counts
  pages that processes share (sysimage, package images) once.
