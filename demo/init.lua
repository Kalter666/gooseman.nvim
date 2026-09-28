-- Minimal config for recording the demos: nvim -u demo/init.lua demo/hero.http
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
vim.o.termguicolors = true
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.laststatus = 3
vim.o.statusline = " %f%m %= %{v:lua.require'gooseman'.statusline()}  %l:%c "
vim.o.shortmess = vim.o.shortmess .. "I"
vim.o.swapfile = false
vim.o.completeopt = "menuone,noselect,popup"
vim.diagnostic.config { virtual_text = true }
vim.lsp.inlay_hint.enable(true)
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(a)
    vim.lsp.completion.enable(true, a.data.client_id, a.buf, { autotrigger = true })
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = a.buf })
  end,
})
-- no system clipboard inside the recorder: keep + and * in memory
local reg = {}
vim.g.clipboard = {
  name = "demo",
  copy = { ["+"] = function(l) reg["+"] = l end, ["*"] = function(l) reg["*"] = l end },
  paste = { ["+"] = function() return reg["+"] or {} end, ["*"] = function() return reg["*"] or {} end },
}
