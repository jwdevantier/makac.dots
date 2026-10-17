#!/usr/bin/env makac
-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- workflows/example.lua — the dogfood example: the workflow IS the manifest.
-- Applies the sample tree (workflows/example-src/, with a dots.lua-driven
-- renderer, a $default_attrs mode and a $ignore glob) to a scratch destination.
-- Safe to run as-is:
--
--   makac workflows/example.lua [DEST]
--
--   DEST defaults to /tmp/makac-dots-example-<$USER-or-nobody>. Run it
--   twice: the first run reports every file `changed`, the second is a
--   no-op — that idempotence is the whole point of a converger.

local dest = arg[1]
if dest == nil or dest == "" then
	dest = "/tmp/makac-dots-example-" .. (os.getenv("USER") or "nobody")
end

-- the tree lives next to this workflow; dots.lua files inside it find shared
-- renderer definitions at workflows/defaults.lua via dofile(PROJECT_DIR ...)
local r = step({
	uses = "dots:apply",
	name = "dots",
	with = {
		root = SCRIPT_DIR .. "/example-src",
		dest = dest,
	},
})

-- a stable, machine-greppable summary (tests assert on this line; do not
-- rely on makac's step-line rendering)
print(("SUMMARY changed=%d failed=%d dest=%s")
	:format(#r.out.changed, #r.out.failed, dest))
