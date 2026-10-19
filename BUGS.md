<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# BUGS / sharp edges (UNCOMMITTED working notes)

Portability of target-side shell-outs in `lib/materialize.lua`. Everything
below concerns **commands run on the target** (host or SSH). Verified only
against GNU/Linux (NixOS) so far; macOS and the BSDs ship a different
userland and several of these calls will fail or misbehave there.

Legend: GNU = GNU coreutils (Linux). BSD = FreeBSD userland. macOS = the
older BSD-derived userland macOS ships (POSIX.1-2024 features missing).

## BUG-001: `stat -c` is GNU-only (HIGH)

`remote_mode` / `remote_owner` shell out to `stat -c %a` / `stat -c %U:%G`.
BSD/macOS `stat(1)` has no `-c`; the equivalents are:

| want        | GNU            | BSD/macOS            |
|-------------|----------------|----------------------|
| octal mode  | `stat -c %a`   | `stat -f %Lp`        |
| user:group  | `stat -c %U:%G`| `stat -f %Su:%Sg`    |

(Same argv shape otherwise; `%Lp` prints e.g. `644` — `mode_eq` already
normalizes, so no parsing change needed.)

Any file entry carrying `mode` or `owner` errors against a BSD/macOS target.

## BUG-002: `ln -sfn` — `-n` is not portable (MEDIUM)

`materialize.symlink(force=true)` runs `ln -sfn`. The no-dereference flag:
GNU = `-n`; FreeBSD = also `-n`; **macOS = `-h`** (no `-n`).

Suggested fix: avoid the flag entirely. The force path is only taken when we
KNOW dest is an existing symlink, so `rm -f <dest> && ln -s <link> <dest>` is
fully portable. Cost: a small gap where dest is missing (rm then ln instead
of one rename-ish op) — irrelevant for dotfiles, but note it.

## BUG-003: `--` end-of-options assumption (LOW-MEDIUM)

Almost every target command passes `--` (`mkdir -p --`, `mv -f --`, `rm -f
--`, `chmod --`, `chown --`, `ln -s --`). POSIX.1-2024 mandates it; FreeBSD
largely supports it; **older macOS utilities are spotty** (e.g. some userland
tools reject `--`).

Mitigating factor: dest paths are always *absolute* after `resolve` (`/...`
or `~/` expanded to `/...`), so a path can never begin with `-` — the guard
is nearly dead code for path arguments. The one real case is the `ln` link
*target* string, which is user data and could start with `-`.

Suggested fix: probe `--` support once per target (see "Fix strategy" below),
or drop `--` everywhere except the `ln` link-target argument.

## BUG-004: `health.lua` probes the wrong side (LOW)

`makac doctor` checks HOST-side prerequisites and documents the strategy, but
the tools that must exist (`mkdir`, `mv`, `chmod`, `chown`, `ln`, `rm`,
`test`/`sh`) run on the TARGET. A broken/incapable target is only discovered
at apply time, as per-file failures.

Suggested fix: when a workflow uses targets, add a "target capabilities"
check driven by the same probe as BUG-001's fix.

## BUG-005: host-side temp handling assumes GNU coreutils (LOW, host-only)

`remote_sha256` / `write_file` clean up temp files with `rm -f` via
`makac.exec` on the HOST, and `plan.lua` uses `readlink --`. Host-side so it
only matters if the machine running makac is macOS/BSD — `rm -f` is POSIX
(fine), `readlink --` drops the `--` on BSD (macOS readlink has no `--`).
Trivial fixes; just not done.

The same caveat covers the *runner-side* tools the report/merge machinery
execs host-side — `lib/diff.lua` (`diff -u`, `rm -f <tmp>`), `lib/merge3.lua`
(`diff3 -m -L ...` with labeled markers, `rm -f -- <tmp>`). `diff`/`diff3`
are GNU diffutils here; macOS ships them but older BSD `diff3` label output
could differ. None of these touch a target; `lib/merge3.lua` additionally
probes for `diff3` first and reports it as a clean error (`command -v`).

Out of scope here but adjacent: `put`/`get` (cp/scp) live in **makac core**,
not this package; audit there separately.

## Fix strategy (proposed)

Use makac's facts machinery (`concepts/facts.md` in the makac repo): facts
are gathered by *finders* — `function(target) -> table` — run through the
built-in `facts` action, and custom finders can be exported from a package's
`lib/` and required from workflows. This package should ship one:

```lua
-- lib/facts.lua (new), required as require("pkgs/dots/facts")
function M.userland(target)
  -- the built-in "os" finder already covers uname -s / -m per target;
  -- this finder probes the rest:
  --   stat:  try GNU form on /, fall back to BSD form -> "gnu" | "bsd"
  --   ln:    GNU/FreeBSD -> "-n", macOS (darwin) -> "-h"
  --          (or skip the question: the rm+ln sequence from BUG-002)
  --   dashdash: does the userland accept "--"? (probe once)
  -- returns { stat = "gnu"|"bsd", ln_noderef = "-n"|"-h", dashdash = bool }
end
```

Two consumption paths, both legitimate:

- **Workflows** gather it as a `facts` step
  (`finders = { os = "os", userland = require("pkgs/dots/facts").userland }`)
  and branch on the result — the documented makac pattern.
- **materialize internally** calls the same finder function directly and
  caches per target in a weak table, exactly like `target_home` does today —
  no step machinery, and host-only uses never pay for extra SSH round-trips.

The argv builders in materialize then key off the cached facts:
`remote_mode_argv(target)` picks `stat -c %a` vs `stat -f %Lp`, etc.

Then prove it: run the blackbox suite against a macOS and/or FreeBSD target
(a QEMU guest via makac.qemu would make this deterministic).

## Deliberately NOT listed (checked, fine)

- `sh -c 'printf %s "$HOME"'`, the `-L/-d/-f/-e` kind script, plain
  `readlink <path>` (no `-f` used), `chown user:group` — all POSIX or
  present-with-the-same-meaning on GNU, FreeBSD and macOS.
