require("gooseman.lsp").start(0)

local function jump(flags)
  return function()
    for _ = 1, vim.v.count1 do
      vim.fn.search("^###", flags)
    end
  end
end
vim.keymap.set("n", "]r", jump "W", { buffer = 0, desc = "gooseman: next request" })
vim.keymap.set("n", "[r", jump "bW", { buffer = 0, desc = "gooseman: previous request" })
