-- Environments: variable sets picked with `:Honk env <name>`.
-- Found next to the .http file or in any parent directory:
--   gooseman.json          {"$shared": {...}, "dev": {"host": "..."}, "prod": {...}}
--   gooseman.private.json  same shape, for secrets (gitignore it); wins over gooseman.json
-- `$shared` applies to every environment; the active one wins over it.
-- Values may use {{refs}} and $(shell) like @vars.

local M = {}

---@type string?
M.active = nil -- ponytail: per session; persist to a state file if switching every restart gets old

local FILES = { "gooseman.json", "gooseman.private.json" }

--- env name -> var -> {value, file, private}
function M.load(path)
  local dir = (path and path ~= "") and vim.fs.dirname(path) or vim.fn.getcwd()
  local out = {}
  for _, f in ipairs(FILES) do
    local found = vim.fs.find(f, { upward = true, path = dir })[1]
    if found then
      local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(found), "\n"))
      if not ok or type(data) ~= "table" then
        error(found .. ": not a JSON object of environments", 0)
      end
      for env, vars in pairs(data) do
        out[env] = out[env] or {}
        for k, v in pairs(type(vars) == "table" and vars or {}) do
          out[env][k] = {
            value = type(v) == "table" and vim.json.encode(v) or tostring(v),
            file = found,
            private = f == "gooseman.private.json",
          }
        end
      end
    end
  end
  return out
end

--- Variables in effect for a file: $shared overlaid by the active environment.
function M.vars(path)
  local all = M.load(path)
  local vars = {}
  for _, env in ipairs { "$shared", M.active } do
    for k, v in pairs(all[env] or {}) do
      vars[k] = v
    end
  end
  return vars
end

function M.names(path)
  local names = vim.tbl_filter(function(n)
    return n ~= "$shared"
  end, vim.tbl_keys(M.load(path)))
  table.sort(names)
  return names
end

function M.select(path, name)
  local ok, names = pcall(M.names, path)
  if not ok then
    return vim.notify("gooseman: " .. names, vim.log.levels.ERROR)
  end
  local function set(n)
    if n == nil then
      return
    end
    M.active = (n ~= "none") and n or nil
    vim.notify("gooseman: environment " .. (M.active or "none"))
    require("gooseman.lsp").refresh()
  end
  if name then
    if name ~= "none" and not vim.tbl_contains(names, name) then
      return vim.notify(("gooseman: no environment `%s` (have: %s)"):format(name, table.concat(names, ", ")), vim.log.levels.WARN)
    end
    return set(name)
  end
  if #names == 0 then
    return vim.notify("gooseman: no gooseman.json found", vim.log.levels.WARN)
  end
  table.insert(names, "none")
  vim.ui.select(names, { prompt = "gooseman environment" }, set)
end

return M
