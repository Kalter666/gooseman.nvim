-- Environments: variable sets picked with `:Honk env <name>`.
-- Found next to the .http file or in any parent directory:
--   gooseman.json          {"$shared": {...}, "dev": {"host": "..."}, "prod": {...}}
--   gooseman.private.json  same shape, for secrets (gitignore it); wins over gooseman.json
-- `$shared` applies to every environment; the active one wins over it.
-- Values may use {{refs}} and $(shell) like @vars.
-- `"$confirm": true` in an environment asks before every send (names containing "prod" ask
-- by default; `"$confirm": false` turns that off). The active environment is remembered per
-- gooseman.json across restarts.

local M = {}

---@type string?
M.active = nil

local STATE = vim.fn.stdpath "state" .. "/gooseman.json" -- gooseman.json path -> active env

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

-- the gooseman.json that governs a file
local function project(path)
  local dir = (path and path ~= "") and vim.fs.dirname(path) or vim.fn.getcwd()
  return vim.fs.find("gooseman.json", { upward = true, path = dir })[1]
end

local function read_state()
  local ok, t = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(STATE), "\n"))
  end)
  return ok and type(t) == "table" and t or {}
end

local restored = {}

--- Pick up the environment last used with this file's gooseman.json (once per session).
function M.restore(path)
  local f = project(path)
  if M.active or not f or restored[f] then
    return
  end
  restored[f] = true
  local name = read_state()[f]
  if name and M.load(path)[name] then
    M.active = name
  end
end

local function save(path)
  local f = project(path)
  if f then
    local t = read_state()
    t[f] = M.active
    vim.fn.mkdir(vim.fs.dirname(STATE), "p")
    vim.fn.writefile({ vim.json.encode(t) }, STATE)
  end
end

--- Variables in effect for a file: $shared overlaid by the active environment.
function M.vars(path)
  M.restore(path)
  local all = M.load(path)
  local vars = {}
  for _, env in ipairs { "$shared", M.active } do
    for k, v in pairs(all[env] or {}) do
      if k:sub(1, 1) ~= "$" then -- $confirm and friends are settings, not variables
        vars[k] = v
      end
    end
  end
  return vars
end

--- Does the active environment want a confirmation before sending?
function M.guarded(path)
  if not M.active then
    return false
  end
  local ok, all = pcall(M.load, path)
  local c = ok and all[M.active] and all[M.active]["$confirm"]
  if c then
    return c.value == "true"
  end
  return M.active:lower():find "prod" ~= nil
end

--- true = go ahead. Asks only in a guarded environment.
function M.confirm(path, what)
  if not M.guarded(path) then
    return true
  end
  return vim.fn.confirm(("Send %s to %s?"):format(what, M.active), "&Send\n&Cancel", 2) == 1
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
    save(path)
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
