-- gRPC server reflection via grpcurl: method names for completion, JSON body templates.
-- ponytail: no auth metadata on reflection calls; servers that guard reflection need `-H` support here

local M = {}

---@type table<string, string[]> address -> "pkg.Service/Method" list, for the session
M.cache = {}

local TIMEOUT = 3000

-- flags go before the address, the verb + its args after it
local function grpcurl(url, flags, ...)
  local cmd = vim.list_extend({ "grpcurl", "-max-time", "3" }, flags)
  if url:match "^grpc://" then
    table.insert(cmd, "-plaintext")
  end
  table.insert(cmd, (url:gsub("^grpcs?://", "")))
  vim.list_extend(cmd, { ... })
  local ok, r = pcall(function()
    return vim.system(cmd, { text = true, timeout = TIMEOUT }):wait()
  end)
  if not ok or r.code ~= 0 then
    return nil, ok and vim.trim(r.stderr) or tostring(r)
  end
  return r.stdout
end

--- Every method on the server as "pkg.Service/Method"; cached per address.
function M.methods(url)
  if M.cache[url] then
    return M.cache[url]
  end
  if vim.fn.executable "grpcurl" == 0 then
    return {}
  end
  local services = grpcurl(url, {}, "list")
  if not services then
    return {} -- not cached: the server may just not be up yet
  end
  local out = {}
  for svc in services:gmatch "[^\n]+" do
    if not svc:match "^grpc%.reflection%." then
      for m in (grpcurl(url, {}, "list", svc) or ""):gmatch "[^\n]+" do
        out[#out + 1] = svc .. "/" .. m:sub(#svc + 2)
      end
    end
  end
  M.cache[url] = out
  return out
end

--- JSON template for a method's request message, e.g. `{ "service": "" }`.
function M.template(url, method)
  local desc, err = grpcurl(url, {}, "describe", (method:gsub("/", ".")))
  if not desc then
    return nil, err
  end
  local input = desc:match "rpc%s+%S+%s*%(%s*(.-)%s*%)"
  if not input then
    return nil, "cannot find the request type of " .. method
  end
  input = input:gsub("^stream%s+", "")
  local msg
  msg, err = grpcurl(url, { "-msg-template" }, "describe", input)
  if not msg then
    return nil, err
  end
  local tmpl = msg:match "Message template:%s*\n(.*)$"
  if not tmpl then
    return nil, "no template in grpcurl output"
  end
  return vim.trim(tmpl)
end

return M
