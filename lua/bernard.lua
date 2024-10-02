local M = {}

local connections = {}
local timer = nil
local response = ""
local host = ""
local port = 0

local open_buffers = {}
local diffs = {}

local diff_count = 10
local ns_id = vim.api.nvim_create_namespace("bernard")

local function display_response(line, col)
	vim.schedule(function()
		vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
		local lines = vim.split(response, "\n", { trimempty = true })
		local virtual_lines = {}

		local first_line = { { "", "Comment" } }
		for i, line_text in ipairs(lines) do
			if i == 1 then
				first_line[1][1] = line_text
			else
				table.insert(virtual_lines, { { line_text, "Comment" } })
			end
		end

		print(line, col)
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

			print("Sent data:", data)

			client:read_start(function(read_err, chunk)
				if read_err then
					print("Read error: " .. read_err)
					if not client:is_closing() then
						client:close()
					end

					return
				end

				if chunk then
					print("Received response:", chunk)

					chunk = string.gsub(chunk, "\\n", "\n")
					chunk = string.gsub(chunk, "\\t", "\t")
					chunk = string.gsub(chunk, "\\r", "\r")

					response = response .. chunk
				else
					if not client:is_closing() then
						client:close()
					end

					vim.schedule(function()
						response = vim.fn.substitute(response, "\\s*$", "", "")

						display_response(line, col)
					end)
				end
			end)
		end)
	end)

	-- Set a timeout
	local timeout_timer = uv.new_timer()
	timeout_timer:start(5000, 0, function()
		print("Request timed out")
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

function M.insert_response()
	if response == "" then
		return
	end

	local lines = vim.split(response, "\n", { trimempty = false })
	vim.api.nvim_put(lines, "c", true, true)

	vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
	response = ""
end

function M.setup(opts)
	opts = opts or {}
	host = opts.host or "127.0.0.1"
	port = opts.port or 5050

	vim.api.nvim_create_user_command("Bernard", function(o)
		if o.args == "enable" then
			M.enable()
		end
	end, {
		nargs = "?",
	})
end

function M.handle_tab()
	vim.notify("tab pressed: " .. tostring(#response))
	if #response > 0 then
		M.insert_response()
	else
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, true, true), "i", true)
	end
end

function M.enable()
	vim.api.nvim_create_autocmd({ "CursorMovedI" }, {
		callback = function()
			print("input cursor moved")
			vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

			local cursor = vim.api.nvim_win_get_cursor(0)
			local col = cursor[2]

			local current_line = vim.fn.getline(".")
			if col >= #current_line - 2 then
				if timer then
					timer:stop()
					if not timer:is_closing() then
						timer:close()
					end
				end

				timer = uv.new_timer()
				timer:start(500, 0, function()
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
			response = ""
			vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
		end,
	})

	vim.keymap.set("i", "<Tab>", M.handle_tab, { noremap = true, silent = true })
	local success = vim.api.nvim_buf_attach(0, false, {
		on_bytes = on_bytes,
	})
	if success then
		print("Successfully attached to buffer " .. vim.api.nvim_get_current_buf())
		open_buffers[vim.api.nvim_get_current_buf()] = true
	else
		print("Failed to attach to buffer " .. vim.api.nvim_get_current_buf())
	end

	vim.api.nvim_create_autocmd("BufAdd", {
		pattern = "*",
		callback = function()
			vim.keymap.set("i", "<Tab>", M.handle_tab, { noremap = true, silent = true })

			local current_buffer = vim.api.nvim_get_current_buf()
			if open_buffers[current_buffer] then
				return
			end

			local success = vim.api.nvim_buf_attach(0, false, {
				on_bytes = on_bytes,
			})
			if success then
				print("Successfully attached to buffer " .. vim.api.nvim_get_current_buf())
				open_buffers[vim.api.nvim_get_current_buf()] = true
			else
				print("Failed to attach to buffer " .. vim.api.nvim_get_current_buf())
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufDelete", {
		pattern = "*",
		callback = function()
			open_buffers[vim.api.nvim_get_current_buf()] = nil
		end,
	})
end

return M
