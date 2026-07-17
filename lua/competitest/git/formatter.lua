---@module "competitest.git.formatter"
---Commit message and body formatting for the Git integration.
---The default formats are intentionally simple; users override them through
---`git.commit_formatter` and `git.body_formatter`.

local M = {}

---Build the commit message subject line.
---When `cfg.commit_formatter` is set it is used, otherwise the built-in default
---`<type>(<platform>/<difficulty>): <id> <title>` is produced.
---@param problem competitest.git.Problem
---@param meta competitest.git.Meta
---@param cfg competitest.Config.git
---@return string # single-line commit message
function M.commit_message(problem, meta, cfg)
	if type(cfg.commit_formatter) == "function" then
		return cfg.commit_formatter(problem, meta)
	end

	local title = problem.title ~= "" and (" " .. problem.title) or ""
	return string.format("%s(%s/%s): %s%s", meta.type, problem.platform, meta.difficulty, problem.id, title)
end

---Build the commit body, or `nil` when bodies are disabled or empty.
---When `cfg.body_formatter` is set it is used, otherwise a small default listing
---the URL, language and attempts is produced.
---@param problem competitest.git.Problem
---@param meta competitest.git.Meta
---@param cfg competitest.Config.git
---@return string? # commit body, or `nil` when it should be omitted
function M.body(problem, meta, cfg)
	if not cfg.body then
		return nil
	end

	local text
	if type(cfg.body_formatter) == "function" then
		text = cfg.body_formatter(problem, meta)
	else
		local lines = {}
		if problem.url ~= "" then
			table.insert(lines, "URL: " .. problem.url)
		end
		table.insert(lines, "Language: " .. meta.language)
		table.insert(lines, "Attempts: " .. tostring(meta.attempts))
		if meta.editorial then
			table.insert(lines, "Editorial: yes")
		end
		text = table.concat(lines, "\n")
	end

	if not text or text == "" then
		return nil
	end
	return text
end

return M
