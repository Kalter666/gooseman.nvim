-- :Honk            send the request under the cursor   (! = forget cached named responses first)
-- :Honk all        run every request in the file, report + quickfix
-- :Honk env [name] pick an environment from gooseman.json ("none" to clear)
-- :Honk curl       copy the request under the cursor as a shell command
-- :[range]Honk import   curl command (range, else clipboard) -> .http block
-- :Honk last       re-send the last request, from any buffer
-- :Honk pick       jump to any request in the project's .http files
-- :Honk jq [filter]  filter the response window through jq (no filter = clear)
-- :Honk save [file]  write the response body to a file
-- :Honk history    pick an earlier response and show it
-- :Honk diff       diff the response against the previous one of the same request
-- :Honk openapi <file|url>  generate requests from an OpenAPI / Swagger spec
local SUB = { "all", "env", "curl", "import", "last", "pick", "jq", "save", "history", "diff", "openapi" }

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
  elseif sub == "save" then
    require("gooseman.view").save(arg)
  elseif sub == "history" then
    require("gooseman.view").history()
  elseif sub == "diff" then
    require("gooseman.view").diff()
  elseif sub == "openapi" then
    require("gooseman.openapi").import(arg)
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
  desc = "gooseman: send request, or a subcommand (all, env, save, diff, ...)",
  complete = function(lead, line)
    local args = vim.split(line, "%s+", { trimempty = true })
    if args[2] == "env" and (#args > 2 or line:match "%s$") then
      local ok, names = pcall(require("gooseman.env").names, vim.api.nvim_buf_get_name(0))
      names = ok and names or {}
      table.insert(names, "none")
      return starting(names, lead)
    end
    if (args[2] == "save" or args[2] == "openapi") and (#args > 2 or line:match "%s$") then
      return vim.fn.getcompletion(lead, "file")
    end
    return starting(SUB, lead)
  end,
})
