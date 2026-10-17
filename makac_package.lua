-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- The dots package: a desired-state converger for dotfiles.
-- Walk a tree of source files (+ `dots.lua` sidecars) and materialize the
-- plan onto a target (host or SSH remote).
--
-- This file only EXPORTS; the implementations live in lib/ modules. Actions
-- are functions of a single `with` table (the action contract, makac core —
-- see the makac repository's design/action.md); makac normalizes their
-- result table ({ err?, changed?, skipped?, out? }).

local action_file = require("./action_file")
local action_apply = require("./action_apply")

return {
	actions = {
		-- ensure ONE file/symlink at dest matches the entry
		file = action_file.file,
		link = action_file.link,
		-- walk a tree (or take with.files) and converge every entry
		apply = action_apply.apply,
	},
}
