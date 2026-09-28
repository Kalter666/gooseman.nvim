vim.api.nvim_create_user_command("Honk", function()
  require("gooseman").send()
end, { desc = "Send the .http request under the cursor" })
