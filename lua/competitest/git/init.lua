---@module "competitest.git"
---Public entry point for CompetiTest's Git integration.
---
---Interactive UI:
---  require("competitest.git").open()
---Non-interactive helpers (suitable for keymaps):
---  require("competitest.git").commit()
---  require("competitest.git").push()
---  require("competitest.git").commit_push()

local api = vim.api
local config = require("competitest.config")
local utils = require("competitest.utils")
local exec = require("competitest.git.exec")
local meta = require("competitest.git.meta")
local formatter = require("competitest.git.formatter")

local M = {}

---Re-exported so `receive.lua` can persist metadata without knowing the layout.
M.store_meta = meta.store

---Resolved context for a Git action.
---@class (exact) competitest.git.Context
---@field bufnr integer source buffer number
---@field cwd string repository working directory
---@field git competitest.Config.git git configuration
---@field problem competitest.git.Problem resolved problem

---Resolve the Git context for a buffer, validating prerequisites, then call `on_ready`.
---Emits a notification and does nothing when a prerequisite fails.
---@param bufnr integer buffer number
---@param on_ready fun(context: competitest.git.Context)
local function build_context(bufnr, on_ready)
	config.load_buffer_config(bufnr)
	local git = config.get_buffer_config(bufnr).git

	if not (git and git.enabled) then
		utils.notify("git integration is disabled; set `git.enabled = true` in setup().", "WARN")
		return
	end
	if not exec.available() then
		utils.notify("git executable not found in PATH.")
		return
	end

	local filepath = api.nvim_buf_get_name(bufnr)
	if filepath == "" then
		utils.notify("current buffer is not associated with a file.")
		return
	end

	local cwd = vim.fn.fnamemodify(filepath, ":h")
	exec.is_repo(cwd, function(is_repo)
		if not is_repo then
			utils.notify("'" .. cwd .. "' is not inside a git repository.")
			return
		end
		on_ready({
			bufnr = bufnr,
			cwd = cwd,
			git = git,
			problem = meta.resolve(bufnr, git),
		})
	end)
end

---Push the current branch, reporting the result via notifications.
---@param context competitest.git.Context
---@param on_done fun(ok: boolean)?
local function do_push(context, on_done)
	utils.notify("pushing\226\128\166", "INFO")
	exec.push(context.cwd, function(ok, res)
		if ok then
			utils.notify("pushed successfully.", "INFO")
		else
			local msg = res.stderr ~= "" and res.stderr or res.stdout
			utils.notify("push failed: " .. vim.trim(msg))
		end
		if on_done then
			on_done(ok)
		end
	end)
end

---Open the interactive Git UI.
---@param bufnr integer? buffer to act on (defaults to the current buffer)
function M.open(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	build_context(bufnr, function(context)
		require("competitest.git.ui").open(context)
	end)
end

---Non-interactively stage and commit a solution using default metadata.
---The commit message is produced by the configured formatter.
---@param bufnr integer? buffer to act on (defaults to the current buffer)
---@param on_done fun(ok: boolean)? called after the commit attempt
function M.commit(bufnr, on_done)
	bufnr = bufnr or api.nvim_get_current_buf()
	build_context(bufnr, function(context)
		local m = meta.default_meta(context.bufnr, context.problem, context.git)
		local subject = formatter.commit_message(context.problem, m, context.git)
		local body = formatter.body(context.problem, m, context.git)
		local paths = meta.stage_paths(context.bufnr, context.problem, context.git)

		exec.stage(context.cwd, paths, function(staged_ok, stage_res)
			if not staged_ok then
				utils.notify("could not stage files: " .. vim.trim(stage_res.stderr), "WARN")
			end
			exec.commit(context.cwd, subject, body, function(ok, res)
				if ok then
					utils.notify("committed: " .. subject, "INFO")
					if context.git.push_after_commit then
						do_push(context)
					end
				else
					local msg = res.stderr ~= "" and res.stderr or res.stdout
					if string.find(msg, "nothing to commit", 1, true) or string.find(msg, "no changes added", 1, true) then
						utils.notify("nothing to commit.", "WARN")
					else
						utils.notify("commit failed: " .. vim.trim(msg))
					end
				end
				if on_done then
					on_done(ok)
				end
			end)
		end)
	end)
end

---Non-interactively push the current branch.
---@param bufnr integer? buffer to act on (defaults to the current buffer)
function M.push(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	build_context(bufnr, function(context)
		do_push(context)
	end)
end

---Commit a solution and, on success, push.
---@param bufnr integer? buffer to act on (defaults to the current buffer)
function M.commit_push(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	build_context(bufnr, function(context)
		local m = meta.default_meta(context.bufnr, context.problem, context.git)
		local subject = formatter.commit_message(context.problem, m, context.git)
		local body = formatter.body(context.problem, m, context.git)
		local paths = meta.stage_paths(context.bufnr, context.problem, context.git)

		exec.stage(context.cwd, paths, function()
			exec.commit(context.cwd, subject, body, function(ok, res)
				if ok then
					utils.notify("committed: " .. subject, "INFO")
					do_push(context)
				else
					local msg = res.stderr ~= "" and res.stderr or res.stdout
					if string.find(msg, "nothing to commit", 1, true) then
						utils.notify("nothing to commit.", "WARN")
					else
						utils.notify("commit failed: " .. vim.trim(msg))
					end
				end
			end)
		end)
	end)
end

---Called by the test runner when all testcases pass, honouring `git.commit_on_accept`.
---@param bufnr integer buffer that just passed all testcases
function M.on_accept(bufnr)
	local git = config.get_buffer_config(bufnr).git
	if not (git and git.enabled) then
		return
	end
	if not api.nvim_buf_is_valid(bufnr) then
		return
	end
	if git.commit_on_accept == "ui" then
		vim.schedule(function()
			M.open(bufnr)
		end)
	elseif git.commit_on_accept == "auto" then
		vim.schedule(function()
			M.commit(bufnr)
		end)
	end
end

return M
