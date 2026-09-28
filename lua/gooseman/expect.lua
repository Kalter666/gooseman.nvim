-- `# @expect <path> <op> [value]` assertions on a response.
--   path   status | headers.<name> | body.<key>.<index0>...   (same as {{name.<path>}})
--   op     == != < <= > >= contains matches(lua pattern) exists !exists
-- Without any @expect a request passes when the tool exits 0 and HTTP status < 400.

local M = {}

-- longest first so `<=` isn't read as `<`
M.OPS = { "!exists", "exists", "contains", "matches", "==", "!=", "<=", ">=", "<", ">" }
local UNARY = { exists = true, ["!exists"] = true }

---@return {path:string, op:string, value:string}?, string? err
function M.parse(text)
  local path, rest = text:match "^(%S+)%s*(.-)$"
  if not path then
    return nil, "empty @expect"
  end
  for _, op in ipairs(M.OPS) do
    if rest == op or rest:sub(1, #op + 1) == op .. " " then
      local value = vim.trim(rest:sub(#op + 1))
      if (UNARY[op] or false) ~= (value == "") then
        return nil, UNARY[op] and (op .. " takes no value") or (op .. " needs a value")
      end
      return { path = path, op = op, value = value }
    end
  end
  return nil, ("unknown operator in `%s` (use %s)"):format(text, table.concat(M.OPS, " "))
end

local function compare(got, op, want)
  if op == "exists" then
    return got ~= nil
  elseif op == "!exists" then
    return got == nil
  elseif got == nil then
    return false
  elseif op == "contains" then
    return got:find(want, 1, true) ~= nil
  elseif op == "matches" then
    return got:match(want) ~= nil
  end
  local a, b = tonumber(got), tonumber(want)
  if not (a and b) then
    a, b = got, want
  end
  if op == "==" then
    return a == b
  elseif op == "!=" then
    return a ~= b
  elseif type(a) ~= type(b) then
    return false
  elseif op == "<" then
    return a < b
  elseif op == "<=" then
    return a <= b
  elseif op == ">" then
    return a > b
  end
  return a >= b
end

--- Check a response. `expand` expands {{refs}} in expected values.
---@return {ok:boolean, text:string, got:string?}[]
function M.check(expects, resp, code, field, expand)
  if #expects == 0 then
    local ok = code == 0 and (resp.status or 0) < 400
    return { { ok = ok, text = "succeeds", got = ("exit %d, status %d"):format(code, resp.status or 0) } }
  end
  local out = {}
  for _, e in ipairs(expects) do
    local x, err = M.parse(e.text)
    if not x then
      out[#out + 1] = { ok = false, text = e.text, got = err }
    else
      local ok, want = pcall(expand, x.value)
      if not ok then
        out[#out + 1] = { ok = false, text = e.text, got = tostring(want) }
      else
        local got = field(resp, x.path)
        out[#out + 1] = { ok = compare(got, x.op, want), text = e.text, got = got }
      end
    end
  end
  return out
end

return M
