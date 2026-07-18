---@module "competitest.git.ui"
---LazyGit-style interactive Git interface for competitive-programming commits.
---
---A single centered floating window with two modes:
---  * Selection Mode (default): shows repo/file/problem state and stages, pushes or
---    enters Commit Mode.
---  * Commit Mode: an editable field list (type, platform, difficulty, language,
---    attempts, editorial, contest) with a live commit-message preview.
---
---All state lives in the module-local `ui` table; there is no global state.

local api = vim.api
local utils = require("competitest.utils")
local exec = require("competitest.git.exec")
local meta = require("competitest.git.meta")
local formatter = require("competitest.git.formatter")

local M = {}

---Interactive Git UI state.
---@class (exact) competitest.git.ui.state
---@field ui_visible boolean whether the UI is currently mounted
---@field popup NuiPopup? the floating window
---@field mode "selection" | "commit" current mode
---@field bufnr integer source buffer number
---@field cwd string repository working directory
---@field git competitest.Config.git git configuration
---@field border_style nui_popup_border_option_style
---@field border_highlight string
---@field problem competitest.git.Problem resolved problem
---@field meta competitest.git.Meta editable metadata
---@field fields competitest.git.ui.field[] commit-mode field descriptors
---@field field_index integer focused field index (commit mode)
---@field status competitest.git.FileStatus? last known file status
---@field branch string current branch
---@field restore_winid integer? window to refocus on close
---@field bound_keys string[] currently bound buffer-local keys
---@field ns integer highlight namespace
local ui = {
	ui_visible = false,
	bound_keys = {},
}

---A commit-mode field descriptor.
---@class (exact) competitest.git.ui.field
---@field label string display label
---@field kind "select" | "toggle" | "text" | "number"
---@field get fun(): any current value
---@field set fun(value: any) update value
---@field options fun(): string[] | nil available values (select fields)
---@field min integer? minimum value (number fields)

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

---@param b boolean
---@return string
local function yesno(b)
	return b and "yes" or "no"
end

---Highlight groups used by the UI (defined in `competitest.setup_highlight_groups`).
local HL = {
	section = "CompetiTestGitSection",
	label = "CompetiTestGitLabel",
	key = "CompetiTestGitKey",
	separator = "CompetiTestGitSeparator",
	accent = "CompetiTestGitAccent",
	focus = "CompetiTestGitFocus",
	correct = "CompetiTestCorrect",
	warning = "CompetiTestWarning",
	wrong = "CompetiTestWrong",
}

---Display label for the first key of a mapping.
---@param maps keymaps
---@return string
local function key_label(maps)
	local lhs = type(maps) == "table" and maps[1] or maps
	local special = {
		["<cr>"] = "Enter",
		["<esc>"] = "Esc",
		["<tab>"] = "Tab",
		["<s-tab>"] = "S-Tab",
		["<space>"] = "Space",
		["<up>"] = "↑",
		["<down>"] = "↓",
		["<left>"] = "←",
		["<right>"] = "→",
	}
	return special[string.lower(lhs)] or lhs
end

---Truncate `text` to at most `width` display cells, appending an ellipsis when cut.
---@param text string
---@param width integer
---@return string
local function truncate(text, width)
	width = math.max(width, 4)
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	local chars = vim.fn.strchars(text)
	while chars > 0 do
		local part = vim.fn.strcharpart(text, 0, chars)
		if vim.fn.strdisplaywidth(part) <= width - 1 then
			return part .. "…"
		end
		chars = chars - 1
	end
	return "…"
end

---Greedy-wrap `text` into lines at most `width` display cells wide.
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
	width = math.max(width, 10)
	local out, line = {}, ""
	for word in string.gmatch(text, "%S+") do
		if line == "" then
			line = word
		elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
			line = line .. " " .. word
		else
			table.insert(out, line)
			line = word
		end
	end
	if line ~= "" or #out == 0 then
		table.insert(out, line)
	end
	return out
end

---Status text and highlight group for the current file.
---@return string text
---@return string hlgroup
local function status_info()
	local s = ui.status
	if not s then
		return "… loading", HL.label
	end
	if not s.tracked then
		return "● untracked", HL.wrong
	end
	if s.staged and s.dirty then
		return "● staged + modified", HL.warning
	elseif s.staged then
		return "● staged", HL.correct
	elseif s.dirty then
		return "● modified", HL.warning
	end
	return "✓ clean", HL.correct
end

---Current commit-message preview.
---@return string
local function preview()
	local ok, msg = pcall(formatter.commit_message, ui.problem, ui.meta, ui.git)
	if not ok then
		return "<formatter error: " .. tostring(msg) .. ">"
	end
	return msg
end

---String value shown for a field.
---@param field competitest.git.ui.field
---@return string
local function field_value(field)
	local v = field.get()
	if field.kind == "toggle" then
		return yesno(v)
	end
	if v == nil or v == "" then
		return "-"
	end
	return tostring(v)
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

---A piece of rendered line text with an optional highlight group.
---@class (exact) competitest.git.ui.segment
---@field [1] string text
---@field [2] string? highlight group

---Rebuild and paint the popup buffer for the current mode.
local function render()
	if not (ui.popup and ui.ui_visible and ui.popup.winid and api.nvim_win_is_valid(ui.popup.winid)) then
		return
	end
	local win_width = api.nvim_win_get_width(ui.popup.winid)

	local lines = {} ---@type string[]
	local extmarks = {} ---@type { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] row, col, end_col, group
	local focus_row ---@type integer? 0-indexed line of the focused field (commit mode)

	---Append one line composed of highlighted segments.
	---@param ... competitest.git.ui.segment | string
	local function add(...)
		local text = ""
		for _, seg in ipairs({ ... }) do
			if type(seg) == "string" then
				seg = { seg }
			end
			if seg[2] and seg[1] ~= "" then
				table.insert(extmarks, { #lines, #text, #text + #seg[1], seg[2] })
			end
			text = text .. seg[1]
		end
		table.insert(lines, text)
	end

	---Append a section separator like ` ── Title ─────`.
	---@param title string
	local function section(title)
		local fill = math.max(3, win_width - vim.fn.strdisplaywidth(title) - 7)
		add({ " ── ", HL.separator }, { title, HL.section }, { " " .. string.rep("─", fill), HL.separator })
	end

	---Append a `label  value` header row.
	---@param label string
	---@param ... competitest.git.ui.segment | string
	local function row(label, ...)
		add({ "  " }, { string.format("%-12s", label), HL.label }, ...)
	end

	local value_width = win_width - 16 -- header rows: 2 pad + 12 label + right margin

	add("")
	row("Repository", { vim.fn.fnamemodify(ui.cwd, ":t") }, "  ", { ui.branch or "?", HL.accent })
	local status_text, status_hl = status_info()
	row("File", { vim.fn.fnamemodify(ui.problem.filepath, ":t") }, "  ", { status_text, status_hl })
	local id = ui.problem.id ~= "" and ui.problem.id or "?"
	if ui.problem.title ~= "" then
		row("Problem", { id, HL.accent }, "  ", { truncate(ui.problem.title, value_width - #id - 2) })
	else
		row("Problem", { id, HL.accent })
	end
	row("URL", { truncate(ui.problem.url ~= "" and ui.problem.url or "-", value_width), HL.label })
	add("")

	if ui.mode == "selection" then
		section("Commit preview")
		for _, l in ipairs(wrap(preview(), win_width - 4)) do
			add("  " .. l)
		end
		add("")
		section("Actions")
		local m = ui.git.mappings.selection
		local actions = {
			{ m.commit, "commit" },
			{ m.stage, "stage" },
			{ m.unstage, "unstage" },
			{ m.push, "push" },
			{ m.refresh, "refresh" },
			{ m.close, "close" },
		}
		for i = 1, #actions, 3 do
			local segs = { " " }
			for j = i, math.min(i + 2, #actions) do
				local key, name = key_label(actions[j][1]), actions[j][2]
				table.insert(segs, { string.format("%6s", key), HL.key })
				table.insert(segs, { " " .. name .. string.rep(" ", math.max(1, 10 - #name)) })
			end
			add(unpack(segs))
		end
	else
		section("Commit details")
		for i, field in ipairs(ui.fields) do
			local focused = i == ui.field_index
			local value = field_value(field)
			local value_hl
			if field.kind == "toggle" then
				value_hl = field.get() and HL.correct or HL.label
			end
			if focused then
				focus_row = #lines
				if field.kind ~= "text" then
					value = "‹ " .. value .. " ›"
				end
			end
			add({ focused and " ▸ " or "   ", HL.accent }, { string.format("%-14s", field.label), HL.label }, { value, value_hl })
		end
		add("")
		section("Preview")
		for _, l in ipairs(wrap(preview(), win_width - 4)) do
			add("  " .. l)
		end
		add("")
		local m = ui.git.mappings.commit
		local hints = {
			{ key_label(m.confirm), "commit" },
			{ key_label(m.back), "back" },
			{ key_label(m.next_field), "move" },
			{ key_label(m.edit), "edit" },
			{ key_label(m.cycle_prev) .. "/" .. key_label(m.cycle_next), "cycle" },
		}
		local segs, used = { "  " }, 2
		for _, h in ipairs(hints) do
			local w = vim.fn.strdisplaywidth(h[1]) + #h[2] + 4
			if used + w > win_width and #segs > 1 then
				add(unpack(segs))
				segs, used = { "  " }, 2
			end
			table.insert(segs, { h[1], HL.key })
			table.insert(segs, { " " .. h[2] .. "   ", HL.label })
			used = used + w
		end
		add(unpack(segs))
	end
	add("")

	-- fit the window height to the content, capped by the configured height ratio
	local _, vim_height = utils.get_ui_size()
	local max_height = math.max(5, math.floor(ui.git.height * vim_height))
	local height = math.min(#lines, max_height)
	if height ~= api.nvim_win_get_height(ui.popup.winid) then
		ui.popup:update_layout({ position = "50%", size = { width = win_width, height = height } })
	end

	vim.bo[ui.popup.bufnr].modifiable = true
	api.nvim_buf_set_lines(ui.popup.bufnr, 0, -1, false, lines)
	vim.bo[ui.popup.bufnr].modifiable = false

	api.nvim_buf_clear_namespace(ui.popup.bufnr, ui.ns, 0, -1)
	if focus_row then
		api.nvim_buf_set_extmark(ui.popup.bufnr, ui.ns, focus_row, 0, { line_hl_group = HL.focus, priority = 100 })
	end
	for _, e in ipairs(extmarks) do
		api.nvim_buf_set_extmark(ui.popup.bufnr, ui.ns, e[1], e[2], { end_col = e[3], hl_group = e[4], priority = 110, strict = false })
	end
	if focus_row then
		pcall(api.nvim_win_set_cursor, ui.popup.winid, { focus_row + 1, 0 })
	end
end

--------------------------------------------------------------------------------
-- Git operations
--------------------------------------------------------------------------------

---Refresh branch and file status, then run `cb`.
---@param cb fun()?
local function refresh(cb)
	exec.branch(ui.cwd, function(branch)
		ui.branch = branch
		exec.file_status(ui.cwd, ui.problem.filepath, function(status)
			ui.status = status
			if cb then
				cb()
			end
		end)
	end)
end

---Push the current branch, keeping the UI open.
local function do_push()
	utils.notify("pushing\226\128\166", "INFO")
	exec.push(ui.cwd, function(ok, res)
		if ok then
			utils.notify("pushed successfully.", "INFO")
		else
			local msg = res.stderr ~= "" and res.stderr or res.stdout
			utils.notify("push failed: " .. vim.trim(msg))
		end
		if ui.ui_visible then
			refresh(render)
		end
	end)
end

---Stage the solution (and testcases, if configured), commit, then optionally push.
local function confirm_commit()
	local subject = preview()
	local body = formatter.body(ui.problem, ui.meta, ui.git)
	local paths = meta.stage_paths(ui.bufnr, ui.problem, ui.git)

	exec.stage(ui.cwd, paths, function(staged_ok, stage_res)
		if not staged_ok then
			utils.notify("could not stage files: " .. vim.trim(stage_res.stderr), "WARN")
		end
		exec.commit(ui.cwd, subject, body, function(ok, res)
			if ok then
				utils.notify("committed: " .. subject, "INFO")
				if ui.ui_visible then
					M.set_mode("selection")
					refresh(render)
				end
				if ui.git.push_after_commit then
					do_push()
				end
			else
				local msg = res.stderr ~= "" and res.stderr or res.stdout
				if string.find(msg, "nothing to commit", 1, true) or string.find(msg, "no changes added", 1, true) then
					utils.notify("nothing to commit.", "WARN")
				else
					utils.notify("commit failed: " .. vim.trim(msg))
				end
				if ui.ui_visible then
					refresh(render)
				end
			end
		end)
	end)
end

---Stage or unstage the current solution.
---@param stage boolean `true` to stage, `false` to unstage
local function stage_or_unstage(stage)
	local paths = meta.stage_paths(ui.bufnr, ui.problem, ui.git)
	local fn = stage and exec.stage or exec.unstage
	fn(ui.cwd, paths, function(ok, res)
		if not ok then
			utils.notify((stage and "stage" or "unstage") .. " failed: " .. vim.trim(res.stderr))
		end
		if ui.ui_visible then
			refresh(render)
		end
	end)
end

--------------------------------------------------------------------------------
-- Field editing (commit mode)
--------------------------------------------------------------------------------

---Open a dropdown selector over `options`, calling `on_choice` with the picked value.
---@param title string
---@param options string[]
---@param on_choice fun(value: string)
local function open_dropdown(title, options, on_choice)
	if #options == 0 then
		utils.notify("no options available for " .. title .. ".", "WARN")
		return
	end
	local nui_menu = require("nui.menu")
	local width = #title + 4
	for _, opt in ipairs(options) do
		width = math.max(width, #opt + 4)
	end
	local _, vim_height = utils.get_ui_size()
	local menu = nui_menu({
		relative = "editor",
		position = "50%",
		size = { width = width, height = math.min(#options, math.max(3, vim_height - 6)) },
		border = {
			style = ui.border_style,
			highlight = ui.border_highlight,
			text = { top = " " .. title .. " ", top_align = "center" },
		},
		buf_options = { filetype = "CompetiTest" },
		zindex = 60,
	}, {
		lines = vim.tbl_map(function(opt)
			return nui_menu.item(opt, { value = opt })
		end, options),
		keymap = {
			focus_next = { "j", "<down>", "<tab>" },
			focus_prev = { "k", "<up>", "<s-tab>" },
			close = { "<esc>", "q", "<c-c>" },
			submit = { "<cr>", "<space>" },
		},
		on_close = function()
			if ui.popup and ui.popup.winid and api.nvim_win_is_valid(ui.popup.winid) then
				api.nvim_set_current_win(ui.popup.winid)
			end
		end,
		on_submit = function(item)
			on_choice(item.value)
			if ui.popup and ui.popup.winid and api.nvim_win_is_valid(ui.popup.winid) then
				api.nvim_set_current_win(ui.popup.winid)
			end
		end,
	})
	menu:mount()
end

---Prompt for free text, calling `on_text` with the entered value (unless cancelled).
---@param title string
---@param default string
---@param on_text fun(text: string)
local function prompt(title, default, on_text)
	vim.ui.input({ prompt = title .. ": ", default = default }, function(input)
		if input ~= nil then
			on_text(input)
		end
	end)
end

---Cycle the focused field's value by `delta` (select/number/toggle).
---@param delta integer
local function cycle_field(delta)
	local field = ui.fields[ui.field_index]
	if field.kind == "toggle" then
		field.set(not field.get())
	elseif field.kind == "number" then
		field.set(math.max(field.min or 1, (field.get() or 1) + delta))
	elseif field.kind == "select" then
		local opts = field.options() or {}
		if #opts == 0 then
			return
		end
		local idx = 1
		local cur = field.get()
		for i, o in ipairs(opts) do
			if o == cur then
				idx = i
				break
			end
		end
		idx = ((idx - 1 + delta) % #opts) + 1
		field.set(opts[idx])
	end
	render()
end

---Edit the focused field (dropdown for selects, prompt for text/number, flip for toggles).
local function edit_field()
	local field = ui.fields[ui.field_index]
	if field.kind == "toggle" then
		field.set(not field.get())
		render()
	elseif field.kind == "select" then
		open_dropdown(field.label, field.options() or {}, function(v)
			field.set(v)
			render()
		end)
	elseif field.kind == "number" then
		prompt(field.label, tostring(field.get() or 1), function(text)
			local n = tonumber(text)
			if n then
				field.set(math.max(field.min or 1, math.floor(n)))
			end
			render()
		end)
	else -- text
		prompt(field.label, tostring(field.get() or ""), function(text)
			field.set(text)
			render()
		end)
	end
end

---Build the commit-mode field descriptors (closures over `ui`).
---@return competitest.git.ui.field[]
local function build_fields()
	local function platform_options()
		local seen, list = {}, {}
		for _, p in ipairs(ui.git.platforms) do
			if not seen[p.code] then
				seen[p.code] = true
				table.insert(list, p.code)
			end
		end
		if ui.problem.platform ~= "" and not seen[ui.problem.platform] then
			table.insert(list, ui.problem.platform)
		end
		return list
	end

	return {
		{
			label = "Type",
			kind = "select",
			get = function() return ui.meta.type end,
			set = function(v) ui.meta.type = v end,
			options = function() return ui.git.types end,
		},
		{
			label = "Platform",
			kind = "select",
			get = function() return ui.problem.platform end,
			set = function(v)
				ui.problem.platform = v
				local dl = ui.git.difficulty[v] or {}
				local found = false
				for _, d in ipairs(dl) do
					if d == ui.meta.difficulty then
						found = true
						break
					end
				end
				if not found then
					ui.meta.difficulty = dl[1] or ""
				end
			end,
			options = platform_options,
		},
		{
			label = "Difficulty",
			kind = "select",
			get = function() return ui.meta.difficulty end,
			set = function(v) ui.meta.difficulty = v end,
			options = function() return ui.git.difficulty[ui.problem.platform] or {} end,
		},
		{
			label = "Language",
			kind = "text",
			get = function() return ui.meta.language end,
			set = function(v) ui.meta.language = v end,
		},
		{
			label = "Attempts",
			kind = "number",
			min = 1,
			get = function() return ui.meta.attempts end,
			set = function(v) ui.meta.attempts = v end,
		},
		{
			label = "Editorial",
			kind = "toggle",
			get = function() return ui.meta.editorial end,
			set = function(v) ui.meta.editorial = v end,
		},
		{
			label = "Contest Mode",
			kind = "toggle",
			get = function() return ui.meta.contest end,
			set = function(v) ui.meta.contest = v end,
		},
	}
end

--------------------------------------------------------------------------------
-- Keymaps and mode switching
--------------------------------------------------------------------------------

---Remove all buffer-local keymaps set by the UI.
local function clear_keymaps()
	for _, lhs in ipairs(ui.bound_keys) do
		pcall(vim.keymap.del, "n", lhs, { buffer = ui.popup.bufnr })
	end
	ui.bound_keys = {}
end

---Bind one or more left-hand sides to `fn` in the popup buffer.
---@param maps keymaps
---@param fn fun()
local function bind(maps, fn)
	if type(maps) == "string" then
		maps = { maps }
	end
	for _, lhs in ipairs(maps) do
		vim.keymap.set("n", lhs, fn, { buffer = ui.popup.bufnr, nowait = true, noremap = true, silent = true })
		table.insert(ui.bound_keys, lhs)
	end
end

---Switch mode and (re)bind the appropriate keymaps.
---@param mode "selection" | "commit"
function M.set_mode(mode)
	ui.mode = mode
	clear_keymaps()
	if mode == "selection" then
		local m = ui.git.mappings.selection
		bind(m.commit, function() M.set_mode("commit") end)
		bind(m.push, do_push)
		bind(m.stage, function() stage_or_unstage(true) end)
		bind(m.unstage, function() stage_or_unstage(false) end)
		bind(m.refresh, function() refresh(render) end)
		bind(m.close, M.close)
	else
		ui.field_index = ui.field_index or 1
		local m = ui.git.mappings.commit
		bind(m.confirm, confirm_commit)
		bind(m.back, function() M.set_mode("selection") end)
		bind(m.next_field, function()
			ui.field_index = (ui.field_index % #ui.fields) + 1
			render()
		end)
		bind(m.prev_field, function()
			ui.field_index = ((ui.field_index - 2) % #ui.fields) + 1
			render()
		end)
		bind(m.edit, edit_field)
		bind(m.cycle_next, function() cycle_field(1) end)
		bind(m.cycle_prev, function() cycle_field(-1) end)
	end
	render()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

---Mount (or remount) the floating window.
local function mount()
	local nui_popup = require("nui.popup")
	local nui_event = require("nui.utils.autocmd").event
	local vim_width, vim_height = utils.get_ui_size()

	ui.popup = nui_popup({
		enter = true,
		focusable = true,
		border = {
			style = ui.border_style,
			highlight = ui.border_highlight,
			text = { top = " CompetiGit ", top_align = "center" },
		},
		relative = "editor",
		position = "50%",
		size = {
			width = math.floor(ui.git.width * vim_width),
			height = math.floor(ui.git.height * vim_height),
		},
		buf_options = {
			modifiable = false,
			readonly = false,
			filetype = "CompetiTest",
		},
		win_options = {
			number = false,
			relativenumber = false,
			wrap = false,
			spell = false,
			cursorline = false,
		},
	})
	ui.popup:mount()
	api.nvim_buf_set_name(ui.popup.bufnr, "CompetiGit")
	ui.ui_visible = true
	ui.popup:on(nui_event.WinClosed, function()
		ui.ui_visible = false
	end, { once = true })
end

---Open the interactive Git UI.
---@param context { bufnr: integer, cwd: string, git: competitest.Config.git, problem: competitest.git.Problem }
function M.open(context)
	if ui.ui_visible then
		M.close()
	end

	local main_cfg = require("competitest.config").get_buffer_config(context.bufnr)
	ui.bufnr = context.bufnr
	ui.cwd = context.cwd
	ui.git = context.git
	ui.problem = context.problem
	ui.meta = meta.default_meta(context.bufnr, context.problem, context.git)
	ui.border_style = main_cfg.floating_border
	ui.border_highlight = main_cfg.floating_border_highlight
	ui.field_index = 1
	ui.status = nil
	ui.branch = "?"
	ui.ns = ui.ns or api.nvim_create_namespace("CompetiGit")
	ui.restore_winid = api.nvim_get_current_win()
	ui.bound_keys = {}

	mount()
	ui.fields = build_fields()
	M.set_mode("selection")
	refresh(render)
end

---Close the interactive Git UI.
function M.close()
	if ui.popup then
		clear_keymaps()
		ui.popup:unmount()
	end
	ui.ui_visible = false
	if ui.restore_winid and api.nvim_win_is_valid(ui.restore_winid) then
		api.nvim_set_current_win(ui.restore_winid)
	end
end

---Resize the UI if visible (called from the global resize handler).
function M.resize()
	if not ui.ui_visible then
		return
	end
	local mode = ui.mode
	clear_keymaps()
	if ui.popup then
		ui.popup:unmount()
	end
	mount()
	ui.fields = build_fields()
	M.set_mode(mode)
	refresh(render)
end

return M
