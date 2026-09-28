vim.api.nvim_create_user_command("Honk", function(o)
  require("gooseman").send { fresh = o.bang }
end, { bang = true, desc = "Send the .http request under the cursor (! = re-run named dependencies)" })
