local M = {}

local active = false

local connections = {}
local timer = nil
local response = ""
local host = ""
local port = 0
local suggestion_delay = 750

local open_buffers = {}
local diffs = {}

local diff_count = 20
local ns_id = vim.api.nvim_create_namespace("bernard")

local function display_response(line, col)
	vim.schedule(function()
		vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
		local lines = vim.split(response, "\n", { trimempty = true })
		local virtual_lines = {}

		local first_line = { { "", "BernardSuggestion" } }
		for i, line_text in ipairs(lines) do
			if i == 1 then
				first_line[1][1] = line_text
			else
				table.insert(virtual_lines, { { line_text, "BernardSuggestion" } })
			end
		end

		vim.api.nvim_buf_set_extmark(0, ns_id, line, col, {
			virt_lines = virtual_lines,
			virt_text = first_line,
			virt_text_pos = "inline",
		})
	end)
end

local uv = vim.loop
local function send_data(data, line, col)
	response = ""

	if #connections > 0 then
		for _, connection in ipairs(connections) do
			if not connection:is_closing() then
				connection:close()
			end
		end

		connections = {}
	end

	local client = uv.new_tcp()
	table.insert(connections, client)
	local suggestion = ""
	client:connect(host, port, function(err)
		if err then
			print("Connection error: " .. err)
			return
		end

		client:write(data, function(write_err)
			if write_err then
				print("Write error: " .. write_err)
				client:close()
				return
			end

			client:read_start(function(read_err, chunk)
				if read_err then
					print("Read error: " .. read_err)
					if not client:is_closing() then
						client:close()
					end

					return
				end

				if chunk then
					chunk = string.gsub(chunk, "\\n", "\n")
					chunk = string.gsub(chunk, "\\t", "\t")
					chunk = string.gsub(chunk, "\\r", "\r")

					suggestion = suggestion .. chunk
				else
					if not client:is_closing() then
						client:close()
					end

					if not timer then
						response = ""
						return
					end

					vim.schedule(function()
						response = vim.fn.substitute(suggestion, "\\s*$", "", "")
						table.remove(connections, 1)

						display_response(line, col)
					end)
				end
			end)
		end)
	end)

	local timeout_timer = uv.new_timer()
	timeout_timer:start(5000, 0, function()
		if not client:is_closing() then
			client:close()
		end

		timeout_timer:close()
	end)
end

local function on_bytes(_, bufnr, _, start_row, _, _, _, _, _, new_end_row, _, _)
	while #diffs >= diff_count do
		table.remove(diffs, 1)
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + new_end_row, false)
	local text = table.concat(lines, "\n")

	if #text == 0 then
		return
	end

	local filename = vim.fn.expand("%:p")

	table.insert(diffs, { filename = filename, text = text })
end

local function build_request(cursor)
	local diff_map = {}
	for _, diff in ipairs(diffs) do
		local filename = diff.filename
		if not diff_map[filename] then
			diff_map[filename] = {}
		end

		table.insert(diff_map[filename], { delta = diff.text, diff_type = "addition" })
	end

	local changes = {}
	for filename, diff_list in pairs(diff_map) do
		table.insert(changes, {
			filename = filename,
			diffs = diff_list,
		})
	end

	local start_line = math.max(1, cursor.line - 10)
	local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), start_line, cursor.line + 1, false)
	local cursor_context = table.concat(lines, "\n")

	local request = {
		changes = changes,
		cursor = cursor,
		cursor_context = cursor_context,
	}

	return vim.fn.json_encode(request)
end

local function cleanup()
	if timer then
		timer:stop()
		if not timer:is_closing() then
			timer:close()
		end
	end

	response = ""
	vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
end

function M.insert_response()
	if response == "" then
		return
	end

	local lines = vim.split(response, "\n", { trimempty = false })
	vim.api.nvim_put(lines, "c", true, true)

	vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
	response = ""
end

function M.handle_tab()
	if #response > 0 and #connections == 0 then
		M.insert_response()
	else
		vim.api.nvim_put({ "\t" }, "", false, true)
	end
end

function M.enable()
	vim.api.nvim_create_autocmd({ "CursorMovedI" }, {
		callback = function()
			if not active then
				return
			end

			cleanup()

			local cursor = vim.api.nvim_win_get_cursor(0)
			local col = cursor[2]

			local current_line = vim.fn.getline(".")
			if col >= #current_line - 2 and #diffs > 0 then
				timer = uv.new_timer()
				timer:start(suggestion_delay, 0, function()
					vim.schedule(function()
						local cursor = vim.api.nvim_win_get_cursor(0)
						local row = cursor[1]
						local col = cursor[2]
						cursor = {
							line = row,
							column = col,
							flat = vim.fn.line2byte(row) + col - 1,
							filename = vim.fn.expand("%:p"),
						}

						local request = build_request(cursor)

						send_data(request, cursor.line - 1, cursor.column)
					end)
					timer:close()
				end)
			else
				if timer and not timer:is_closing() then
					timer:stop()
					timer:close()
				end
			end
		end,
	})

	vim.api.nvim_create_autocmd("CursorMoved", {
		callback = function()
			if not active then
				return
			end

			cleanup()
		end,
	})

	vim.api.nvim_create_autocmd("BufEnter", {
		pattern = "*",
		callback = function()
			if not active then
				return
			end

			local current_buffer = vim.api.nvim_get_current_buf()
			if open_buffers[current_buffer] then
				return
			end

			vim.keymap.set("i", "<Tab>", M.handle_tab, { noremap = true, silent = true })

			local success = vim.api.nvim_buf_attach(0, false, {
				on_bytes = on_bytes,
			})

			if success then
				open_buffers[current_buffer] = true
			else
				print("Failed to attach Bernard to buffer " .. vim.api.nvim_get_current_buf())
			end
		end,
	})

	vim.api.nvim_create_autocmd("InsertLeave", {
		callback = cleanup,
	})

	vim.api.nvim_create_autocmd("ColorScheme", {
		pattern = "*",
		callback = function()
			vim.api.nvim_set_hl(0, "BernardSuggestion", { fg = "#8a8a8a", ctermfg = 200, force = true })
		end,
	})

	vim.api.nvim_create_autocmd("BufDelete", {
		pattern = "*",
		callback = function()
			if not active then
				return
			end

			open_buffers[vim.api.nvim_get_current_buf()] = nil
		end,
	})

	active = true
	print("Bernard enabled")
end

function M.disable()
	active = false
	print("Bernard disabled")
end

function M.setup(opts)
	opts = opts or {}
	host = opts.host or "127.0.0.1"
	port = opts.port or 5050
	suggestion_delay = opts.suggestion_delay or 750

	vim.api.nvim_create_user_command("Bernard", function(o)
		if o.args == "enable" then
			M.enable()
		elseif o.args == "disable" then
			M.disable()
		end
	end, {
		nargs = "?",
	})

	if opts.startup then
		M.enable()
	end
end

return M
