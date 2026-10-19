<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->
# makac.dots

A [makac](https://github.com/jwdevantier/makac) package that turns makac into
a dotfiles manager — a chezmoi replacement: walk a tree of source files (with
`dots.lua` policy files for ignore/override/materialize rules) and converge the
result onto a target, host or SSH remote alike.

**Status: functional** — `dots:file`, `dots:link`, `dots:dir`, `dots:apply`,
`dots:diff` and `dots:prune` are implemented and tested on host and SSH
targets.

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
| `src`       | source file: relative to `root` when given, or absolute/`~`-prefixed (used as-is) |
| `root`      | tree root for `src`                                                |
| `absent`    | ensure the path is removed (never removes directories)             |
| `skip`      | do not manage this entry (skipped step)                            |
| `link`      | symlink entry — use `dots:link` (rejected here on purpose)         |
| `mode`      | `chmod` (shell-out on the target)                                  |
| `owner`     | `chown user:group` (shell-out)                                     |
| `renderer`  | `function(content) -> string`; its output is what is hashed/written|
| `override`  | overwrite a target file that was edited since deploy (default false: such user edits are never silently clobbered) |
| `reproduce` | source symlinks: `true` recreates the symlink, false dereferences  |
| `check`     | report would-change without writing                                |
| `target`    | makac target (default `makac.host`)                                |

Changed detection is content-hash based (`makac.fs.sha256`, portable); writes
are temp-then-move atomic.

### `dots:link` — stow-style symlinks, opt-in

`with = { dest = ..., link = "<string to store verbatim>", ... }`. A symlink
cannot carry `mode`/`owner`; a real node at `dest` is never replaced by a
symlink.

### `dots:dir` — managed directories

Ensure a **directory** exists with the desired attributes:
`with = { dest = ..., mode = "0700", owner = ..., skip = ..., check = ...,
target = ... }` — those are the ONLY valid keys (`content`/`src`/`link`/
`renderer`/`absent` are rejected: a directory has no bytes and pruning
removes only *empty* dirs via `rmdir`). The leaf is `mkdir -p`'d together
with any unmanaged gap; an existing non-directory node at `dest` is a loud
failure (never replaced). `mode`/`owner` apply on creation and on drift,
normally reached through `dots:apply` dispatch of the walk's
[`["."]`](#trees-and-dotslua) entries.

One special case, the **DEST-itself footgun**: a `["."]` entry in the
tree ROOT's dots.lua asks for mode/owner on the destination prefix itself —
usually `~`, the user's whole home. Applying that requires the explicit
acknowledgment `manage_dest_dir = true` on `dots:apply`; otherwise the entry
fails with a clear error naming the flag:

```lua
-- tree/dots.lua: manage the DESTINATION ITSELF — footgun!
return { ["."] = { mode = "0700" } }   -- chmod 0700 ~ — almost surely wrong

-- you must acknowledge this at the dots:apply call-site:
step { uses = "dots:apply", name = "d", with = {
  root = "tree", manage_dest_dir = true,
} }
```

Bare `dots:dir` calls (an explicit `dest`) need no gate — the explicit dest
IS the acknowledgment. `dots:diff` and check mode report the drift either
way (the gate protects writes, not visibility).

### `dots:apply` — the primary action

The normal way to use the package: point it at a source tree (see
[Trees and dots.lua](#trees-and-dotslua)) and it converges every
file in it:

```lua
local r = step { uses = "dots:apply", name = "dotfiles", with = {
  root = "tree",        -- source tree relative to the project root
  dest = "~",           -- destination prefix (default "~")
  override = false,     -- may user edits to deployed files be overwritten?
  -- manage_dest_dir = true,   -- REQUIRED to apply a root ["."] entry
                              -- (mode/owner on DEST itself — footgun!)
  -- target = my_ssh_target,  -- default makac.host
  -- check = true,       -- report would-change, write nothing
  -- quiet = true,       -- no per-entry failure chatter on stderr (frontends
                         -- that present out.failed themselves use this)
  -- strict = true,      -- abort the workflow if any file fails
} }
print("changed: " .. #r.out.changed, "failed: " .. #r.out.failed)
```

Inputs: `root` (a source tree to walk) **or** `files` (a pre-built list of
entry tables, the escape hatch). Giving both is an error, as is giving
neither.

Every entry becomes its own inner step (one `ok`/`changed`/`skipped`/
`failed` line per file), and per-file failures are **data, never an
abort**: the loop continues past conflicts and the result tells you what
happened:

```lua
r = {
  changed = bool,           -- true iff at least one entry changed
  out = {
    changed  = { "~/a.conf", ... },      -- entries that changed
    ok       = { "~/b.conf", ... },      -- already at the desired state
    failed   = { { path = ..., err = ... }, ... },  -- conflicts and errors
    skipped  = { "~/c.conf", ... },      -- entries with skip = true
    target_only = { "~/d.conf", ... },     -- user-edited target files, source
                                         -- unchanged: reported, never written
                                         -- (override = true would overwrite)
  },
  err = "...",              -- set ONLY with strict = true and failures present
}
```

Failure reasons are written to stderr as they happen (unless `quiet = true`)
— without the `step '...' (uses '...') failed:` ceremony: `out.failed[].err`
carries the action's own message. `check = true`
propagates to every entry — nothing is written, but conflicts still count
as failures (a conflict means the state cannot converge). Entries created
by the walk get their `src` resolved against `root` by the inner steps;
absolute or `~`-prefixed `src` values are used as-is.

**Override means "may I overwrite user edits" — nothing else.** Before
each file is applied, apply classifies it against the deployed snapshot and
the target file (`lib/classify.lua`):

- target untouched since deploy, source changed → **fast-forwarded**: applied
  even under `override = false` (there are no user edits to destroy)
- target edited, source unchanged → **target-only**: reported in `out.target_only`,
  never written; `override = true` overwrites the user edits (that is
  precisely what the flag means)
- both moved apart → **diverged**: a conflict (`out.failed`) unless
  `override = true`
- no snapshot entry exists → the classic 2-way compare: exists-and-differs
  is a conflict, exists-and-same is ok, missing is deployed

### `dots:diff` — drift reporting (never writes)

Same inputs as `dots:apply` (`root` **or** `files`, `dest`, `target`), same
walk and planning, but instead of converging it *reports* what differs.
Humans get a two-section report on stdout — unified diffs for content drift
(patch(1)-readable via the `a/<dest>` / `b/<dest>` labels), then one line
per file with mode/owner drift:

```
## contents
--- a/~/docs/gopass.md
+++ b/~/docs/gopass.md
@@ -5,8 +5,6 @@
 ...
## modes
MODE ~/.ssh/config: 777 -> 0600
```

Directory entries (`["."]`) never produce content diffs: drift on a
managed directory is reported as MODE/OWNER lines in the modes section.

Machines get the same in `out`: `entries` (full per-entry items with the
diff text), plus `differing` / `mode_drift` / `owner_drift` / `ok` /
`skipped` / `failed`
destination lists, and `out.drifted` (bool) says whether anything drifts.
`changed` is always **false** — reporting changes nothing (same convention
as makac's built-in `facts` action). New files diff
from `/dev/null`; `absent` entries diff toward it; symlink drift is a
one-line note. Nothing is ever written — including per-entry failures,
which land in `failed` as data, mirroring `dots:apply`.

### `dots:prune` — reconcile the snapshot store with the plan

When a file leaves the tree, its deployed snapshot entry remains — an
**orphan**. `dots:prune` walks `root` into the current plan and acts on the
orphans of its own tree. It is **non-interactive** (makac workflows never
block on stdin; the interactive frontend lives in makac.mydots):

```lua
local r = step { uses = "dots:prune", name = "prune", with = {
  root = "tree",          -- walked exactly like dots:apply
  dest = "~",             -- destination prefix (default "~")
  -- tree = "mydots",     -- owner id override; same precedence as apply
  policy = "report",      -- "report" (default) | "delete" | "forget"
  -- check = true,         -- like "report", whatever the policy
  -- strict = true,        -- abort the workflow if any orphan fails
} }
```

Policies:

- `report` — no mutation; everything is output (`would_delete`,
  `would_forget`).
- `delete` — remove the target node AND drop the snapshot entry. Drift (the
  target bytes differ from what was deployed — user edits) is **reported** in
  `out.deleted[]` but does not stop the delete: the policy was explicit.
  Orphaned **directories** are removed only when EMPTY (`rmdir` — recursion
  is deliberately impossible); a non-empty orphaned directory is reported in
  `out.skipped_dirs` and kept.
- `forget` — drop the snapshot entry only; the target file stays.

Orphans whose target node already **vanished** are auto-forgotten under any
mutating policy (nothing to delete; asking would be noise). Entries owned
by **foreign trees** are never touched — they are counted and logged
(`3 entries owned by 'bootstrap' — skipped`).

```lua
r = {
  changed = bool,           -- true iff something was deleted or forgotten
  out = {
    orphans   = { { relpath=..., meta=..., target_kind=<str|nil>, drifted=<bool> }, ... },
    vanished  = { "b.conf", ... },        -- target node gone (auto-forget)
    deleted   = { { relpath=..., drifted=<bool> }, ... },   -- policy=delete
    forgotten = { "c.conf", ... },        -- entry dropped, target left alone
    would_delete = { { relpath=..., drifted=<bool> }, ... },-- report/check
    would_forget = { "c.conf", ... },     -- report/check
    foreign   = { { tree="bootstrap", count=3 }, ... },   -- reported, never touched
    skipped_dirs = { "busyd", ... },       -- non-empty orphaned dirs, kept
    failed    = { { path=..., err=... }, ... },             -- data; strict turns it into err
  },
}
```

The delete-safety signal (`drifted`) comes from the deployed snapshot: the
target bytes are hashed and compared against what was last deployed, so prune
knows whether an orphan still carries user edits (for links: the target target
against the recorded one; for directories: the recorded mode/owner against
the target attrs). Orphan listing also notes `empty` for directory orphans.
The mechanism behind this (`lib/prune.lua`) is exported for frontends and
never prompts.

## Integration support (for frontends)

Interactive integration (push/pull/merge between the target machine and the
source tree) deliberately does NOT live in this package — makac.dots is
non-interactive throughout ("integrate"/"reconcile" are frontend verbs). What
it DOES provide is the complete mechanism frontend tooling (e.g. makac.mydots'
integrate and prune commands) builds on:

- the **deployed snapshot** (below) supplies the merge base per entry:
  what was last deployed, bytes and attrs;
- `lib/classify.lua` turns every plan entry into a 3-way state
  (`converged` / `ff` / `target-only` / `diverged` / `new` /
  `absent-pending`); hashes classify, bytes merge;
- `lib/merge3.lua` merges `base` (deployed) / `target` / `source` with
  `diff3 -m`, producing conflict-marked output with MANDATORY labels
  (`Untracked Changes` / `Old` / `New`), plus `validate_no_markers` (verify
  a user-resolved file is marker-free) and `parse_conflicts` (report
  conflict count/positions). Binary content is refused loudly. `diff3` is a
  **runner-side** dependency (POSIX/GNU diffutils) only workflows that call
  into `merge3` need — deployment itself never does.

The interactive side — opening `$EDITOR` over the marked file, deciding
pull-vs-push, prompting — belongs to the frontend, not here.

## Deployed snapshot

`dots:apply` records what it last deployed **on the target itself**, under
`<dest>/.makac/dots/snapshot/` (dest is the apply `dest` prefix, usually
`~`): one entry per managed path, named by the hash of its dest-relative
path. Each entry is a tiny header (strict magic line + one compact JSON
line carrying the owner tree, kind, mode/owner, and content hash) followed
by the deployed bytes verbatim, so later runs can distinguish "user edited
this target" from "the source changed" without host-side state. The store is
mode `0700`/`0600`; writes are atomic, skipped in check mode, and never
fail a step. Removals **drop** the entry — the store never keeps bytes for
a target path that is deliberately gone.

Each entry carries an **owner id** (`tree`), resolved once per apply:
`with.tree` > `$tree` in the tree's ROOT `dots.lua` > `basename(root)`.
Several projects may deploy into the same DEST; prune/integrate act only on
their own owner and report foreign entries. **Doc rule: one owner name per
DEST** — a foreign tree reusing your owner id is indistinguishable from
you, and no code can detect it (their prune would offer to delete your target
files).

Only `dots:apply` records — bare `dots:file`/`dots:link` calls (or `files=`
entries without `with.tree`, or with dests outside the dest prefix) deploy
fine but are **untracked**: no snapshot entry, hence no prune/integrate
coverage. Apply emits one log line per run when that happens.

## Trees and `dots.lua`

`dots:apply` walks a source tree (`lib/plan.lua`, also usable directly via
`require("pkgs/dots/plan")`). The walk is depth-first with names sorted, so
the entry list is deterministic:

- Each file yields an entry: `dest = <dest> .. "/" .. <relpath>` (call-site
  `dest` defaults to `~`), `src = <relpath>`, plus attributes from dots.lua.
- **Directories become managed when their dots.lua carries a `["."]`
  entry** for the directory itself — `mode`/`owner`/`skip` are the ONLY
  allowed keys (anything else, e.g. `renderer` or `absent`, is a loud walk
  error naming the file and key). Dir entries (`{ dir = true, ... }`) are
  emitted BEFORE their children (managed parents exist, with modes, before
  files land; the walk is depth-first), `$default_attrs` never fills them,
  and `dots:apply` dispatches them to `dots:dir`. A `["."]` in the tree
  ROOT's dots.lua manages DEST itself and requires
  `manage_dest_dir = true` on `dots:apply` (see `dots:dir`).
- **Empty directories ship nothing** — an unmanaged dir exists at the
  destination only as the parent of a managed file. Parent dirs are
  `mkdir -p`'d on write.
- `.git`, `.makac` and `dots.lua` are auto-ignored, everywhere.
- **Source symlinks are dereferenced**: the destination gets the resolved
  file content. A broken symlink is a loud walk error, unless the entry has
  `reproduce = true`, which ships it as a `link` entry carrying the stored
  target string. To create a symlink at the destination deliberately, write
  an explicit `{ link = "<target>" }` entry.

A directory may carry one `dots.lua`, which returns a table and is
the complete, self-contained policy **for that directory only** — no
inheritance, no merging across directories:

```lua
local d = dofile(PROJECT_DIR .. "/defaults.lua")   -- shared policy via dofile
return {
  -- ROOT dots.lua only: the tree's owner id for the deployed snapshot
  -- (one owner name per DEST; with.tree at the apply call-site wins):
  ["$tree"] = "mydots",

  -- per-file entries (keys are names in THIS directory):
  ["sshd_config"] = { owner = "root:root", mode = "0600" },

  -- attributes for files here with NO explicit entry (attributes only —
  -- absent/skip/override inside $default_attrs are an error):
  ["$default_attrs"]  = d,

  -- attrs for THIS DIRECTORY ITSELF (mode/owner/skip only):
  ["."]          = { mode = "0700" },

  -- globs relative to this directory: * one segment, ** across segments,
  -- "name/" a whole subtree (never descended into):
  ["$ignore"]   = { "*.bak", "secrets/", "**/.DS_Store" },

  -- which files here may replace a differing existing file at the
  -- destination (otherwise target edits are protected: see `override` on
  -- dots:apply/dots:file). A boolean applies to all files
  -- here. A function is called once per file with a table:
  --   file.name     basename ("init.lua")
  --   file.relpath  path within the tree ("nvim/init.lua")
  --   file.dest     destination as written ("~/nvim/init.lua")
  --   file.abspath  absolute host-side source path
  -- true = this file may overwrite, false = it may not. The example below
  -- says: only "*.local" files here may overwrite what is already installed:
  ["$override"] = function(file) return file.name:match("%.local$") ~= nil end,

  -- context for the functions below: a table (or function returning one),
  -- computed once per directory, passed as their 2nd argument:
  ["$ctx"]      = { theme = "dark" },

  -- a FUNCTION value is shorthand for { renderer = fn }: it is called with
  -- the file's bytes (+ $ctx) and returns the content (a string, or a table
  -- of attrs incl. "content"). With NO file of that name on disk it is a
  -- virtual entry: fn(nil, ctx) and its return value becomes the file.
  ["motto.txt"] = function(_, ctx) return "theme: " .. ctx.theme .. "\n" end,
}
```

Because functions receive `$ctx`, template helpers become shareable —
impossible with closures alone:

```lua
-- defaults.lua (outside the tree): a minimal {var} templating helper
M.tpl = function(content, ctx) return (content:gsub("{(%w+)}", ctx or {})) end

-- tree/.ssh/dots.lua
local d = dofile(PROJECT_DIR .. "/defaults.lua")
return {
  ["$ctx"]   = { identity = "jwd@example.com" },
  ["config"] = { mode = "0600", renderer = d.tpl }, -- tree file has {identity}
  ["known"]  = function(_, ctx) return "user=" .. ctx.identity end, -- virtual
}
```

Notes:

- An explicit entry wins over `$default_attrs`; `$default_attrs` fills gaps for unlisted
  files and never reaches into subdirectories. For function entries it fills
  the *gaps* of the returned attrs instead.
- A table entry naming a file that does not exist is a loud walk error —
  almost surely a typo.
- Override precedence: per-entry `override` > `$override` > the `dots:apply`
  call-site `with.override` > `false`. The walk bakes the resolved boolean
  into each entry.
- `$tree` names the tree's owner id for the deployed snapshot. It is
  recognized in the ROOT dots.lua only (elsewhere it is silently ignored,
  like any unknown `$` key); precedence at apply time is `with.tree` >
  `$tree` > `basename(root)`.
- Bare `require("defaults")` in a dots.lua is deliberately unsupported (it is
  `loadfile`'d from the user's tree, not a package module); use
  `dofile(PROJECT_DIR .. "/...")` as above.
- A broken dots.lua (syntax error, non-table return, raised predicate) fails
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

- `unapply` on top of the deployed snapshot (stow's `-D`, but
  correct and remote-capable); `dots:prune` already handles orphan removal.
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
