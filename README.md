<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->
# makac.dots

A [makac](https://github.com/jwdevantier/makac) package that turns makac into
a dotfiles manager — a chezmoi replacement: walk a tree of source files (with
`dots.lua` sidecars for ignore/override/materialize rules) and converge the
result onto a target, host or SSH remote alike.

**Status: functional** — `dots:file`, `dots:link` and `dots:apply` are
implemented and tested on host and SSH targets. See `design/main.md` for the
settled design (every behavior decision lives there) and `design/tree.md` for
the tree walk. Non-goals (by design): templating language, secret store,
backups, prune (the managed journal it will build on already exists).

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
| `dest`      | required; `~` expands on the target                                |
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
`design/tree.md`) or takes `with.files` (a list of entries), and issues one
non-fatal inner `dots:file`/`dots:link` step per entry: per-file failures are
data (`out.failed`), never an abort — unless `with.strict = true`. `changed`
is true iff any file changed; `with.check = true` reports without writing.
Extra fields: `dest` (default `~/`), `override` (call-site policy), `target`.

## Managed journal

Every path successfully written/removed/chmod'd is recorded under
`.makac/dots/<target>/managed` in the project's data dir (deduped, sorted;
journal writes are skipped in check mode and never fail a step). This is the
basis for a future `dots:prune`.

## Tests

```sh
makac tests/run.lua             # unit tests (pure/host-side parts)
makac tests/blackbox/run.lua    # black-box suites: host + ssh_real (jwd@workpc.lan)
                                # ssh_real self-skips when the remote is unreachable
makac doctor                    # health checks for this package
```
