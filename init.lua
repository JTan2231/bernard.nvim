local M = {}

function M.on_text_change()
	print("Text changed!")
end

-- Set up autocommands when the file is loaded
local augroup = vim.api.nvim_create_augroup("Bernard", { clear = true })
vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
	group = augroup,
	callback = M.on_text_change,
})

return M
