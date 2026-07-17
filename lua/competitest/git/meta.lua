---@module "competitest.git.meta"
---Problem metadata persistence and resolution.
---
---CompetiTest itself does not keep problem metadata (title, URL, platform, contest)
---once a problem is received. This module bridges that gap: at receive-time it writes
---a small JSON sidecar next to the source file, and at commit-time it resolves a
---`competitest.git.Problem` for the current buffer by trying, in order:
---  1. the sidecar written at receive-time (full metadata),
---  2. a URL found in the source-file header (e.g. a template comment),
---  3. inference from the file name (works best with `filename_strategy = "url"`).

local api = vim.api
local utils = require("competitest.utils")

local M = {}

---Default mapping from file extension to a language label.
---@type table<string, string>
local default_language_map = {
	c = "c",
	cpp = "cpp",
	cc = "cpp",
	cxx = "cpp",
	["c++"] = "cpp",
	py = "python",
	java = "java",
	rs = "rust",
	go = "go",
	js = "javascript",
	ts = "typescript",
	kt = "kotlin",
	rb = "ruby",
}

---Split a task `group` (`"Judge - Contest"`) into its judge and contest parts.
---@param group string?
---@return string judge, string contest
local function split_group(group)
	group = group or ""
	local hyphen = string.find(group, " - ", 1, true)
	if not hyphen then
		return group, ""
	end
	return string.sub(group, 1, hyphen - 1), string.sub(group, hyphen + 3)
end

---Derive a short identifier from a problem URL, falling back to the problem name.
---Mirrors the logic used by `receive.lua` for `$(TASKNAME)`.
---@param url string?
---@param name string?
---@return string
local function derive_taskname(url, name)
	url = url or ""
	local cf_id, cf_index = string.match(url, "/(%d+)/problem/(%u+)$")
	if not cf_id then
		cf_id, cf_index = string.match(url, "/problemset/problem/(%d+)/(%u+)$")
	end
	if not cf_id then
		cf_id, cf_index = string.match(url, "/gym/(%d+)/problem/(%u+)$")
	end
	if cf_id and cf_index then
		return cf_id .. cf_index
	end
	local slug = string.match(url, "/tasks/([^/]+)$") or string.match(url, "/([%w_%-]+)$")
	return slug or name or ""
end

---Compute the absolute path of the metadata sidecar for a source file.
---@param filepath string absolute source file path
---@param git competitest.Config.git
---@return string? # sidecar path, or `nil` on evaluation failure
function M.sidecar_path(filepath, git)
	return utils.eval_string(filepath, git.meta_file_format)
end

---Build a `competitest.git.Problem` from raw task fields, using the configured
---platform detection table to compute platform code, id, contest and index.
---@param filepath string absolute source file path
---@param url string? problem URL
---@param group string? task group (judge + contest)
---@param name string? problem name/title
---@param git competitest.Config.git
---@return competitest.git.Problem
function M.build_problem(filepath, url, group, name, git)
	url = url or ""
	name = name or ""
	local _, group_contest = split_group(group)

	local platform, id, contest, index = "", "", "", ""
	for _, p in ipairs(git.platforms) do
		local ok, matched = pcall(p.match, url, group or "")
		if ok and matched then
			platform = p.code
			local built = p.id({ url = url, group = group or "", name = name, taskname = derive_taskname(url, name) })
			if type(built) == "table" then
				id = built.id or ""
				contest = built.contest or ""
				index = built.index or ""
			end
			break
		end
	end

	if contest == "" then
		contest = group_contest
	end
	if id == "" then
		-- unknown platform: fall back to the file name without extension
		id = vim.fn.fnamemodify(filepath, ":t:r")
	end

	return {
		platform = platform,
		contest = contest,
		index = index,
		id = id,
		title = name,
		url = url,
		filepath = filepath,
	}
end

---Persist problem metadata as a sidecar next to the source file.
---Called from `receive.lua` after a received problem's source file is written.
---Safe to call unconditionally; it does nothing when Git integration is disabled.
---@param filepath string absolute source file path
---@param task competitest.CCTask received task
---@param cfg competitest.Config full CompetiTest configuration
function M.store(filepath, task, cfg)
	local git = cfg.git
	if not (git and git.enabled) then
		return
	end
	local meta_path = M.sidecar_path(filepath, git)
	if not meta_path then
		return
	end
	local problem = M.build_problem(filepath, task.url, task.group, task.name, git)
	local ok, encoded = pcall(vim.json.encode, problem)
	if not ok then
		utils.notify("git.meta.store: failed to encode metadata for '" .. filepath .. "'.", "WARN")
		return
	end
	local write_ok, err = pcall(utils.write_string_on_file, meta_path, encoded)
	if not write_ok then
		utils.notify("git.meta.store: " .. tostring(err), "WARN")
	end
end

---Read and validate a sidecar for the given source file.
---@param filepath string absolute source file path
---@param git competitest.Config.git
---@return competitest.git.Problem? # stored problem, or `nil` when absent/invalid
local function read_sidecar(filepath, git)
	local meta_path = M.sidecar_path(filepath, git)
	if not meta_path or not utils.does_file_exist(meta_path) then
		return nil
	end
	local content = utils.load_file_as_string(meta_path)
	if not content then
		return nil
	end
	local ok, decoded = pcall(vim.json.decode, content)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	---@cast decoded competitest.git.Problem
	decoded.filepath = filepath -- keep the path fresh in case the file moved
	for _, field in ipairs({ "platform", "contest", "index", "id", "title", "url" }) do
		if type(decoded[field]) ~= "string" then
			decoded[field] = ""
		end
	end
	return decoded
end

---Scan the first lines of a buffer for a problem URL (e.g. a template comment).
---@param bufnr integer
---@return string? # URL, or `nil` when none is found
local function scan_header_url(bufnr)
	local lines = api.nvim_buf_get_lines(bufnr, 0, 20, false)
	for _, line in ipairs(lines) do
		local url = string.match(line, "https?://[%w%.%-/_%?=&#]+")
		if url then
			return url
		end
	end
	return nil
end

---Infer a problem purely from the source file name.
---Recognises Codeforces-style (`2050A`) and AtCoder-style (`abc412_c`) names.
---@param filepath string absolute source file path
---@param git competitest.Config.git
---@return competitest.git.Problem
function M.infer_from_filename(filepath, git)
	local stem = vim.fn.fnamemodify(filepath, ":t:r")

	-- Codeforces: "2050A", "1700B2"
	local contest, index = string.match(stem, "^(%d+)(%u%d*)$")
	if contest and index then
		return {
			platform = "cf",
			contest = contest,
			index = index,
			id = "CF" .. contest .. index,
			title = "",
			url = string.format("https://codeforces.com/contest/%s/problem/%s", contest, index),
			filepath = filepath,
		}
	end

	-- AtCoder: "abc412_c"
	local ac_contest, ac_index = string.match(stem, "^(%a+%d+)_(%w+)$")
	if ac_contest and ac_index then
		return {
			platform = "at",
			contest = ac_contest:upper(),
			index = ac_index:upper(),
			id = (ac_contest .. ac_index):upper(),
			title = "",
			url = string.format("https://atcoder.jp/contests/%s/tasks/%s_%s", ac_contest, ac_contest, ac_index),
			filepath = filepath,
		}
	end

	return {
		platform = "",
		contest = "",
		index = "",
		id = stem,
		title = "",
		url = "",
		filepath = filepath,
	}
end

---Resolve the problem associated with a buffer, trying sidecar, header URL, then file name.
---@param bufnr integer buffer number
---@param git competitest.Config.git
---@return competitest.git.Problem
function M.resolve(bufnr, git)
	local filepath = api.nvim_buf_get_name(bufnr)

	local from_sidecar = read_sidecar(filepath, git)
	if from_sidecar then
		return from_sidecar
	end

	local url = scan_header_url(bufnr)
	if url and url ~= "" then
		return M.build_problem(filepath, url, "", "", git)
	end

	return M.infer_from_filename(filepath, git)
end

---Build a default `competitest.git.Meta` for a resolved problem.
---Used both for the initial UI state and for non-interactive commits.
---@param bufnr integer buffer number
---@param problem competitest.git.Problem
---@param git competitest.Config.git
---@return competitest.git.Meta
function M.default_meta(bufnr, problem, git)
	local difficulties = git.difficulty[problem.platform] or {}
	return {
		type = git.default_type,
		difficulty = difficulties[1] or "",
		language = M.language(bufnr, git),
		attempts = 1,
		editorial = false,
		contest = false,
	}
end

---Compute the list of paths that should be staged for a problem.
---Always includes the solution file; includes the testcases directory when
---`git.stage_testcases` is set.
---@param bufnr integer buffer number
---@param problem competitest.git.Problem
---@param git competitest.Config.git
---@return string[]
function M.stage_paths(bufnr, problem, git)
	local paths = { problem.filepath }
	if git.stage_testcases then
		local ok, bufcfg = pcall(function()
			return require("competitest.config").get_buffer_config(bufnr)
		end)
		if ok and bufcfg then
			local tcdir = vim.fn.fnamemodify(problem.filepath, ":h") .. "/" .. (bufcfg.testcases_directory or ".")
			if utils.does_file_exist(tcdir) then
				table.insert(paths, tcdir)
			end
		end
	end
	return paths
end

---Infer the language label for a buffer.
---Prefers `git.language_map` (keyed by filetype or extension), then a built-in map,
---then the raw extension.
---@param bufnr integer buffer number
---@param git competitest.Config.git
---@return string
function M.language(bufnr, git)
	local filetype = vim.bo[bufnr].filetype
	local ext = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":e")
	local map = git.language_map or {}
	return map[filetype] or map[ext] or default_language_map[ext] or (ext ~= "" and ext) or (filetype ~= "" and filetype) or "unknown"
end

return M
