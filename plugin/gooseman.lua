-- :Honk            send the request under the cursor   (! = forget cached named responses first)
-- :Honk all        run every request in the file, report + quickfix
-- :Honk env [name] pick an environment from gooseman.json ("none" to clear)
-- :Honk curl       copy the request under the cursor as a shell command
-- :[range]Honk import   curl command (range, else clipboard) -> .http block
-- :Honk last       re-send the last request, from any buffer
-- :Honk pick       jump to any request in the project's .http files
-- :Honk jq [filter]  filter the response window through jq (no filter = clear)
local SUB = { "all", "env", "curl", "import", "last", "pick", "jq" }

local function starting(list, lead)
  return vim.tbl_filter(function(n)
    return n:find(lead, 1, true) == 1
  end, list)
end

vim.api.nvim_create_user_command("Honk", function(o)
  local g = require "gooseman"
  local sub, arg = o.fargs[1], o.fargs[2]
  if not sub then
    g.send { fresh = o.bang }
  elseif sub == "all" then
    g.send_all { fresh = o.bang }
  elseif sub == "env" then
    require("gooseman.env").select(vim.api.nvim_buf_get_name(0), arg)
  elseif sub == "last" then
    g.send_last()
  elseif sub == "pick" then
    g.pick()
  elseif sub == "jq" then
    require("gooseman.view").jq(table.concat(vim.list_slice(o.fargs, 2), " "))
  elseif sub == "curl" then
    g.copy_curl()
  elseif sub == "import" then
    if o.range > 0 then
      g.import_curl(o.line1, o.line2)
    else
      g.import_curl()
    end
  else
    vim.notify("gooseman: unknown :Honk " .. sub, vim.log.levels.WARN)
  end
end, {
  bang = true,
  nargs = "*",
  range = true,
  desc = "gooseman: send request / all / env / curl / import",
  complete = function(lead, line)
    local args = vim.split(line, "%s+", { trimempty = true })
    if args[2] == "env" and (#args > 2 or line:match "%s$") then
      local ok, names = pcall(require("gooseman.env").names, vim.api.nvim_buf_get_name(0))
      names = ok and names or {}
      table.insert(names, "none")
      return starting(names, lead)
    end
    return starting(SUB, lead)
  end,
})
