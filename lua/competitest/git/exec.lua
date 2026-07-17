---@module "competitest.git.exec"
---Thin asynchronous wrappers around the `git` executable.
---Uses `vim.system` on Neovim >= 0.10 and falls back to `vim.fn.jobstart` otherwise.
---Every callback is invoked on the main loop (via `vim.schedule`) so it is safe to
---touch buffers and windows from within.

local utils = require("competitest.utils")

local M = {}

---Result of a git invocation.
---@class (exact) competitest.git.ExecResult
---@field code integer process exit code (127 when git could not be started)
---@field stdout string captured standard output
---@field stderr string captured standard error

---Whether the `git` executable is available.
---@return boolean
function M.available()
	return vim.fn.executable("git") == 1
end

---Run a git command asynchronously.
---@param args string[] arguments passed to `git`
---@param cwd string working directory
---@param on_done fun(result: competitest.git.ExecResult) called on completion
local function run(args, cwd, on_done)
	local cmd = { "git" }
	vim.list_extend(cmd, args)

	if vim.system then
		local ok = pcall(vim.system, cmd, { cwd = cwd, text = true }, function(res)
			vim.schedule(function()
				on_done({ code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" })
			end)
		end)
		if not ok then
			vim.schedule(function()
				on_done({ code = 127, stdout = "", stderr = "unable to start git" })
			end)
		end
		return
	end

	-- Fallback for Neovim < 0.10.
	local stdout, stderr = {}, {}
	local jid = vim.fn.jobstart(cmd, {
		cwd = cwd,
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if data then
				vim.list_extend(stdout, data)
			end
		end,
		on_stderr = function(_, data)
			if data then
				vim.list_extend(stderr, data)
			end
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				on_done({ code = code, stdout = table.concat(stdout, "\n"), stderr = table.concat(stderr, "\n") })
			end)
		end,
	})
	if jid <= 0 then
		vim.schedule(function()
			on_done({ code = 127, stdout = "", stderr = "unable to start git" })
		end)
	end
end

---Whether `cwd` is inside a git work tree.
---@param cwd string
---@param on_done fun(is_repo: boolean)
function M.is_repo(cwd, on_done)
	run({ "rev-parse", "--is-inside-work-tree" }, cwd, function(res)
		on_done(res.code == 0 and vim.trim(res.stdout) == "true")
	end)
end

---Current branch name (or a short SHA / "?" when detached/unknown).
---@param cwd string
---@param on_done fun(branch: string)
function M.branch(cwd, on_done)
	run({ "rev-parse", "--abbrev-ref", "HEAD" }, cwd, function(res)
		local branch = vim.trim(res.stdout)
		on_done(res.code == 0 and branch ~= "" and branch or "?")
	end)
end

---Porcelain status of a single file.
---@class (exact) competitest.git.FileStatus
---@field tracked boolean whether the file is tracked by git
---@field staged boolean whether the file has staged changes
---@field dirty boolean whether the file has unstaged changes
---@field index string index (staged) status character
---@field worktree string worktree (unstaged) status character

---Report the git status of a single file.
---@param cwd string
---@param filepath string absolute file path
---@param on_done fun(status: competitest.git.FileStatus)
function M.file_status(cwd, filepath, on_done)
	run({ "status", "--porcelain", "--", filepath }, cwd, function(res)
		if res.code ~= 0 or res.stdout == "" then
			-- No output: either clean & tracked, or the command failed.
			on_done({ tracked = res.code == 0, staged = false, dirty = false, index = " ", worktree = " " })
			return
		end
		local line = vim.split(res.stdout, "\n", { plain = true, trimempty = true })[1] or "  "
		local index = string.sub(line, 1, 1)
		local worktree = string.sub(line, 2, 2)
		local untracked = index == "?" and worktree == "?"
		on_done({
			tracked = not untracked,
			staged = index ~= " " and index ~= "?",
			dirty = worktree ~= " " and worktree ~= "?",
			index = index,
			worktree = worktree,
		})
	end)
end

---Stage one or more files.
---@param cwd string
---@param files string[] absolute file paths
---@param on_done fun(ok: boolean, result: competitest.git.ExecResult)
function M.stage(cwd, files, on_done)
	local args = { "add", "--" }
	vim.list_extend(args, files)
	run(args, cwd, function(res)
		on_done(res.code == 0, res)
	end)
end

---Unstage one or more files (keeping working-tree changes).
---@param cwd string
---@param files string[] absolute file paths
---@param on_done fun(ok: boolean, result: competitest.git.ExecResult)
function M.unstage(cwd, files, on_done)
	local args = { "reset", "-q", "HEAD", "--" }
	vim.list_extend(args, files)
	run(args, cwd, function(res)
		on_done(res.code == 0, res)
	end)
end

---Create a commit with the given subject and optional body.
---@param cwd string
---@param subject string commit message subject
---@param body string? commit message body
---@param on_done fun(ok: boolean, result: competitest.git.ExecResult)
function M.commit(cwd, subject, body, on_done)
	local args = { "commit", "-m", subject }
	if body and body ~= "" then
		table.insert(args, "-m")
		table.insert(args, body)
	end
	run(args, cwd, function(res)
		on_done(res.code == 0, res)
	end)
end

---Push the current branch to its remote.
---@param cwd string
---@param on_done fun(ok: boolean, result: competitest.git.ExecResult)
function M.push(cwd, on_done)
	run({ "push" }, cwd, function(res)
		on_done(res.code == 0, res)
	end)
end

return M
