-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- policy for the example tree root.
local d = dofile(PROJECT_DIR .. "/workflows/defaults.lua")

return {
	["$default_attrs"] = d.files, -- attributes for files here with no explicit entry
	["$ignore"] = { "*.swp" }, -- editor droppings never ship
	["gitconfig"] = { renderer = d.render_gitconfig },
}
