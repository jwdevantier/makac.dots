-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- sidecar for the example tree root (design/main.md §dots.lua).
local d = dofile(PROJECT_DIR .. "/workflows/defaults.lua")

return {
	["$default"] = d.files, -- attributes for files here with no explicit entry
	["$ignore"] = { "*.swp" }, -- editor droppings never ship
	["gitconfig"] = { renderer = d.render_gitconfig },
}
