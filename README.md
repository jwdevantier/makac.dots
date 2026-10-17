<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->
# makac.dots

A [makac](https://github.com/jwdevantier/makac) package that turns makac into
a dotfiles manager — a chezmoi replacement: walk a tree of source files (with
`dots.lua` sidecars for ignore/override/materialize rules) and converge the
result onto a target, host or SSH remote alike.

**Status: functional** — `dots:file`, `dots:link` and `dots:apply` are
implemented and tested on host and SSH targets.

- makac: <https://github.com/jwdevantier/makac>
- makac documentation: <https://jwdevantier.github.io/makac/>

## Quickstart

See `workflows/example.lua`, which applies the sample tree in this repo to a
scratch destination:

```sh
makac workflows/example.lua            # dest defaults to /tmp/makac-dots-example-$USER
makac workflows/example.lua /tmp/demo  # or any destination
```

The first run reports every file `changed`; the second is a no-op — the
workflow prints a stable `SUMMARY changed=N failed=N` line.

To use the package from your own project, pin it in `makac_project.lua`
(filesystem fetcher for local development, or fetchgit with a rev):

```lua
return {
  inputs = { dots = { fetcher = "filesystem", with = { path = "/path/to/makac.dots" } } },
  packages = { dots = "dots" },
}
```

## Actions

### `dots:file` — the primitive

Ensure the node at `dest` matches an entry; `err` is set on failure.
Entry fields (`with`):

| field       | meaning                                                            |
|-------------|-------------------------------------------------------------------|
| `dest`      | required — must be `~`, `~/...` or absolute; `~` means the **target** session's `$HOME`. Relative dests, `~user` and `..` segments are rejected |
| `content`   | inline file content (exclusive with `src`)                         |
| `src`       | source file, relative to `root` when given                         |
| `root`      | tree root for `src`                                                |
| `absent`    | ensure the path is removed (never removes directories)             |
| `skip`      | do not manage this entry (skipped step)                            |
| `link`      | symlink entry — use `dots:link` (rejected here on purpose)         |
| `mode`      | `chmod` (shell-out on the target)                                  |
| `owner`     | `chown user:group` (shell-out)                                     |
| `renderer`  | `function(content) -> string`; its output is what is hashed/written|
| `override`  | replace an existing differing file when true (default false: conflict) |
| `reproduce` | source symlinks: `true` recreates the symlink, false dereferences  |
| `check`     | report would-change without writing                                |
| `target`    | makac target (default `makac.host`)                                |

Changed detection is content-hash based (`makac.fs.sha256`, portable); writes
are temp-then-move atomic.

### `dots:link` — stow-style symlinks, opt-in

`with = { dest = ..., link = "<string to store verbatim>", ... }`. A symlink
cannot carry `mode`/`owner`; a real node at `dest` is never replaced by a
symlink.

### `dots:apply` — the primary action

Walks `with.root` (a source tree with `dots.lua` sidecars — see
[Trees and sidecars](#trees-and-dotslua-sidecars) below) or takes `with.files` (a list of entries), and issues one
non-fatal inner `dots:file`/`dots:link` step per entry: per-file failures are
data (`out.failed`), never an abort — unless `with.strict = true`. `changed`
is true iff any file changed; `with.check = true` reports without writing.
Extra fields: `dest` (default `~/`), `override` (call-site policy), `target`.

## Managed journal

Every path successfully written/removed/chmod'd is recorded under
`.makac/dots/<target>/managed` in the project's data dir (deduped, sorted;
journal writes are skipped in check mode and never fail a step). This is the
basis for a future `dots:prune`.

## Trees and `dots.lua` sidecars

`dots:apply` walks a source tree (`lib/plan.lua`, also usable directly via
`require("pkgs/dots/plan")`; `tree.md`'s rules are implemented and tested
there). The walk is depth-first with names sorted, so the entry list is
deterministic:

- Each file yields an entry: `dest = <dest> .. "/" .. <relpath>` (call-site
  `dest` defaults to `~`), `src = <relpath>`, plus sidecar attributes.
- **Empty directories ship nothing** — a dir exists at the destination only
  as the parent of a managed file. Parent dirs are `mkdir -p`'d on write.
- `.git`, `.makac` and `dots.lua` are auto-ignored, everywhere.
- **Source symlinks are dereferenced**: the destination gets the resolved
  file content. A broken symlink is a loud walk error, unless the entry has
  `reproduce = true`, which ships it as a `link` entry carrying the stored
  target string. To create a symlink at the destination deliberately, write
  an explicit `{ link = "<target>" }` entry.

A directory may carry one `dots.lua` sidecar, which returns a table and is
the complete, self-contained policy **for that directory only** — no
inheritance, no merging across directories:

```lua
local d = dofile(PROJECT_DIR .. "/defaults.lua")   -- shared policy via dofile
return {
  -- per-file entries (keys are names in THIS directory):
  ["sshd_config"] = { owner = "root:root", mode = "0600" },

  -- attributes for files here with NO explicit entry (attributes only —
  -- absent/skip/override inside $default_attrs are an error):
  ["$default_attrs"]  = d,

  -- globs relative to this directory: * one segment, ** across segments,
  -- "name/" a whole subtree (never descended into):
  ["$ignore"]   = { "*.bak", "secrets/", "**/.DS_Store" },

  -- which files here may replace a differing existing file:
  -- a boolean, or function(name) -> bool
  ["$override"] = function(name) return name:match("%.local$") ~= nil end,
}
```

Notes:

- An explicit entry wins over `$default_attrs`; `$default_attrs` fills gaps for unlisted
  files and never reaches into subdirectories.
- Override precedence: per-entry `override` > `$override` > the `dots:apply`
  call-site `with.override` > `false`. The walk bakes the resolved boolean
  into each entry.
- Bare `require("defaults")` in a sidecar is deliberately unsupported (a
  sidecar is `loadfile`'d from the user's tree, not a package module); use
  `dofile(PROJECT_DIR .. "/...")` as above.
- A broken sidecar (syntax error, non-table return, raised predicate) fails
  the walk loudly; nothing is silently skipped. Walk errors raise from
  `plan.tree` and surface as the `dots:apply` step's failure.

## Rationale

Why it works this way, condensed:

- **Materialize (copy, possibly rendered) is the default; linking is
  opt-in.** Copying is the only portable realization across the target
  abstraction (a symlink's target is only valid where it exists — rarely on
  a remote), supports rendering/modes, and content-hash comparison makes
  `changed` exact. The stow ergonomic is preserved: drop a file into the
  tree, re-run, see it reported `changed`.
- **One code path serves host and SSH.** Every destination-side operation
  goes through the target interface (`run`/`put`/`get`); only host-side
  scratch (temp files, reading `src`, hashing) uses `makac.fs`. There is no
  separate local path to build or test; the `ssh_real` suite includes a
  differential case asserting the host and SSH trees come out identical.
- **`~` is resolved against the target, not the shell.** The transports are
  argv-based (exec, ssh argv, scp) with paths passed quoted, so no tilde
  expansion ever happens implicitly; the actions probe the target session's
  `$HOME` once and concatenate. Hence: relative dests would silently mean
  the runner's cwd on host but the login `$HOME` over SSH — so they are
  rejected outright.
- **A renderer is data, not a service:** `function(content) -> string`, full
  stop. Everything else (env, facts) is captured by the closure. The
  rendered output is what gets hashed, so inputs need no manifest — and a
  nondeterministic input shows up as spurious `changed`, which is the
  feature working. Keep render inputs explicit and stable
  (see `workflows/defaults.lua`).
- **No backups on `override = true`.** `override = false` is the default, so
  destroying a file is always deliberate; the repository history already
  holds the managed version.
- **`$ignore` is separate from `.gitignore`.** `.gitignore` keeps a file out
  of git but not off disk (editor backups, `.DS_Store`); the walk must not
  ship those.

## Potential future work

- `dots:prune` / `unapply` on top of the managed journal (stow's `-D`, but
  correct and remote-capable).
- A `secret = true` entry flag: force `0600` and redact content from step
  names/messages/`out`. Not a secret store — fetching stays delegated to the
  workflow (env vars, `pass`, sops, age).
- A `target.kind == "host"` fast path for hashing (today's path is fully
  target-agnostic and pays a fetch-then-hash per file, host included).

## Tests

```sh
makac tests/run.lua             # unit tests (pure/host-side parts)
makac tests/blackbox/run.lua    # black-box suites: host + ssh_real (jwd@workpc.lan)
                                # ssh_real self-skips when the remote is unreachable
makac doctor                    # health checks for this package
```
