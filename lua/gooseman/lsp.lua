-- In-process language server for .http files: no binary, runs inside nvim.
--   completion   {{vars}}, {{named.body.fields}}, methods, headers, header values, # @directives
--   hover        what a {{ref}} resolves to (shell vars are shown, not run; secrets masked)
--   definition   {{ref}} -> its @var line, `# @name` line or gooseman.json entry
--   diagnostics  undefined refs, unknown methods/directives, bad @expect, duplicate names

local g = require "gooseman"
local env = require "gooseman.env"
local expect = require "gooseman.expect"

local M = {}

local HEADERS = {
  "Accept", "Accept-Encoding", "Accept-Language", "Authorization", "Cache-Control", "Connection",
  "Content-Type", "Cookie", "If-Match", "If-None-Match", "Origin", "Referer", "User-Agent",
  "X-API-Key", "X-Request-ID", "X-Forwarded-For",
}
local HEADER_VALUES = {
  authorization = { "Bearer ", "Basic " },
  ["content-type"] = {
    "application/json", "application/x-www-form-urlencoded", "multipart/form-data",
    "text/plain", "application/xml", "application/grpc",
  },
  accept = { "application/json", "*/*", "text/html" },
  ["cache-control"] = { "no-cache", "no-store", "max-age=0" },
}
local DIRECTIVES = {
  name = "name this request; reuse its response as {{name.body.x}}",
  args = "raw flags for curl/grpcurl/websocat",
  header = "(before the first ###) header added to every request",
  expect = "assert on the response: <path> <op> [value], e.g. status == 200",
}

local K = vim.lsp.protocol.CompletionItemKind

local function buf_lines(uri)
  local bufnr = vim.uri_to_bufnr(uri)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
end

-- scan + the active environment's variables (a broken gooseman.json just means none)
-- ponytail: re-reads gooseman.json on every request; cache by mtime if it ever shows up in a profile
local function scan(lines, uri)
  local s = g.scan(lines)
  local ok, vars = pcall(env.vars, uri and vim.uri_to_fname(uri))
  s.env = ok and vars or {}
  return s
end

-- Role of a 1-based row: "request" | "header" | "body" | "other".
local function role(lines, s, row)
  local b = g.block_at(s, row)
  if not b or row == b.sep then
    return "other"
  end
  if not b.req or row == b.req.line then
    return "request"
  end
  if row < b.req.line then
    return "other"
  end
  for i = b.req.line + 1, row do
    if lines[i]:match "^%s*$" then
      return i == row and "other" or "body" -- headers end at the first blank line
    end
  end
  return "header"
end

-- What {{key}} points at: "var", "response", "env" or nil.
local function kind_of(s, key)
  if s.vars[key] then
    return "var"
  end
  if s.env[key] then
    return "envfile"
  end
  local name = key:match "^([^.]+)%."
  if name and (s.names[name] or g.responses[name]) then
    return "response", name
  end
  if os.getenv(key) then
    return "env"
  end
end

-- keys of a stored response at a dotted path, for completing {{login.body.<here>}}
local function response_keys(name, path)
  if path == "" then
    return { "body", "headers", "status" }
  end
  local resp = g.responses[name]
  if not resp then
    return {}
  end
  local parts = vim.split(path, ".", { plain = true })
  local v
  if parts[1] == "headers" and #parts == 1 then
    v = resp.headers
  elseif parts[1] == "body" then
    v = resp.body
    for i = 2, #parts do
      if type(v) ~= "table" then
        return {}
      end
      local n = tonumber(parts[i])
      v = (n and vim.islist(v)) and v[n + 1] or v[parts[i]]
    end
  end
  if type(v) ~= "table" then
    return {}
  end
  local keys = {}
  if vim.islist(v) then
    for i = 1, #v do
      keys[#keys + 1] = tostring(i - 1)
    end
  else
    for k in pairs(v) do
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  return keys
end

local function items(labels, kind, detail)
  local out = {}
  for _, l in ipairs(labels) do
    out[#out + 1] = { label = l, kind = kind, detail = detail }
  end
  return out
end

local function complete(params)
  local lines = buf_lines(params.textDocument.uri)
  local row, col = params.position.line + 1, params.position.character
  local line = lines[row] or ""
  local before = line:sub(1, col)
  local s = scan(lines, params.textDocument.uri)

  local ref = before:match "{{%s*([%w_%-%.]*)$"
  if ref then
    local name, path = ref:match "^([^.]+)%.(.*)$"
    if name then
      local prefix = path:match "^(.*)%." or ""
      return items(response_keys(name, prefix), K.Field, "response of " .. name)
    end
    local out = {}
    for k, v in pairs(s.vars) do
      out[#out + 1] = { label = k, kind = K.Variable, detail = v.value }
    end
    for k, v in pairs(s.env) do
      if not s.vars[k] then
        out[#out + 1] = { label = k, kind = K.Constant, detail = "env " .. (env.active or "$shared") .. (v.private and " (private)" or "") }
      end
    end
    for k in pairs(s.names) do
      out[#out + 1] = { label = k, kind = K.Module, detail = "response of ### " .. k }
    end
    for k in pairs(g.responses) do
      if not s.names[k] then
        out[#out + 1] = { label = k, kind = K.Module, detail = "cached response (other file)" }
      end
    end
    return out
  end

  local x = before:match "^%s*#%s*@expect%s+(.*)$"
  if x then
    if not x:find "%s" then
      return items({ "status", "headers.", "body." }, K.Field)
    end
    if x:match "^%S+%s+%S*$" then
      return items(expect.OPS, K.Operator)
    end
    return {}
  end

  if before:match "^%s*#%s*@[%w%-]*$" then
    local out = {}
    for k, doc in pairs(DIRECTIVES) do
      out[#out + 1] = { label = k, kind = K.Keyword, detail = doc }
    end
    return out
  end

  local r = role(lines, s, row)
  if r == "request" and before:match "^%u*$" then
    return items(vim.tbl_keys(g.METHODS), K.Keyword)
  end
  if r == "header" then
    local hname = before:match "^%s*([%w%-]+):%s*[^{]*$"
    if hname then
      return items(HEADER_VALUES[hname:lower()] or {}, K.Value)
    end
    if before:match "^%s*[%w%-]*$" then
      local out = {}
      for _, h in ipairs(HEADERS) do
        out[#out + 1] = { label = h, kind = K.Property, insertText = h .. ": " }
      end
      return out
    end
  end
  return {}
end

-- {{ref}} under the cursor
local function ref_at(params)
  local lines = buf_lines(params.textDocument.uri)
  local row, col = params.position.line + 1, params.position.character + 1
  for _, r in ipairs(g.refs(lines[row] or "")) do
    if col >= r.s and col <= r.e then
      return r, lines, row
    end
  end
end

local function hover(params)
  local r, lines = ref_at(params)
  if not r then
    return nil
  end
  local s = scan(lines, params.textDocument.uri)
  local kind, name = kind_of(s, r.ref)
  local text
  if kind == "var" then
    local v = s.vars[r.ref].value
    local sh = v:match "^%$%((.*)%)$"
    text = sh and ("shell, runs on send:\n```sh\n" .. sh .. "\n```") or ("```\n" .. v .. "\n```")
  elseif kind == "envfile" then
    local v = s.env[r.ref]
    text = ("%s\n\n*%s, environment `%s`*"):format(
      v.private and "`••••••` (private)" or ("```\n" .. v.value .. "\n```"),
      vim.fn.fnamemodify(v.file, ":~:."),
      env.active or "$shared"
    )
  elseif kind == "response" then
    local resp = g.responses[name]
    local v = resp and g.field(resp, r.ref:sub(#name + 2))
    text = resp and ("```\n" .. tostring(v) .. "\n```\n*cached response of `" .. name .. "`*")
      or ("`" .. name .. "` not sent yet, runs automatically on first use")
  elseif kind == "env" then
    -- never show secrets in a popup
    text = ("env `$%s` is set (%d chars)"):format(r.ref, #os.getenv(r.ref))
  else
    text = "undefined, will be sent as `{{" .. r.ref .. "}}`"
  end
  return { contents = { kind = "markdown", value = text } }
end

local function definition(params)
  local r, lines = ref_at(params)
  if not r then
    return nil
  end
  local s = scan(lines, params.textDocument.uri)
  local kind, name = kind_of(s, r.ref)
  if kind == "envfile" then
    local file = s.env[r.ref].file
    for i, l in ipairs(vim.fn.readfile(file)) do
      if l:find('"' .. r.ref .. '"', 1, true) then
        local pos = { line = i - 1, character = 0 }
        return { uri = vim.uri_from_fname(file), range = { start = pos, ["end"] = pos } }
      end
    end
  end
  local line = kind == "var" and s.vars[r.ref].line or (kind == "response" and s.names[name] and s.names[name].name_line)
  if not line then
    return nil
  end
  return {
    uri = params.textDocument.uri,
    range = { start = { line = line - 1, character = 0 }, ["end"] = { line = line - 1, character = 0 } },
  }
end

function M.diagnostics(lines, uri)
  local s = scan(lines, uri)
  local out = {}
  local function add(row, s_col, e_col, msg, sev)
    out[#out + 1] = {
      range = { start = { line = row - 1, character = s_col }, ["end"] = { line = row - 1, character = e_col } },
      message = msg,
      severity = sev or vim.lsp.protocol.DiagnosticSeverity.Warning,
      source = "gooseman",
    }
  end
  for row, l in ipairs(lines) do
    if not l:match "^%s*#" or l:match "^%s*#%s*@" then
      for _, r in ipairs(g.refs(l)) do
        if not kind_of(s, r.ref) then
          add(row, r.s - 1, r.e, ("undefined `%s` (not a @var, named request or env var)"):format(r.ref))
        end
      end
    end
    local d = l:match "^%s*#%s*@([%w%-]+)"
    if d and not DIRECTIVES[d] then
      add(row, 0, #l, "unknown directive @" .. d .. " (ignored)", vim.lsp.protocol.DiagnosticSeverity.Hint)
    elseif d == "expect" then
      local _, err = expect.parse(l:match "@expect%s*(.-)%s*$")
      if err then
        add(row, 0, #l, err, vim.lsp.protocol.DiagnosticSeverity.Error)
      end
    end
  end
  for _, b in ipairs(s.blocks) do
    if b.req then
      local m = b.req.text:match "^(%S+)"
      if not g.METHODS[m] then
        add(b.req.line, 0, #m, "unknown method " .. m, vim.lsp.protocol.DiagnosticSeverity.Error)
      end
    end
  end
  for _, d in ipairs(s.dups) do
    add(d.line, 0, #lines[d.line], "duplicate @name " .. d.name, vim.lsp.protocol.DiagnosticSeverity.Error)
  end
  return out
end

local handlers = {
  initialize = function()
    return {
      capabilities = {
        positionEncoding = "utf-8",
        textDocumentSync = { openClose = true, change = 1 },
        completionProvider = { triggerCharacters = { "{", ".", "@", ":" } },
        hoverProvider = true,
        definitionProvider = true,
      },
      serverInfo = { name = "gooseman" },
    }
  end,
  shutdown = function() end,
  ["textDocument/completion"] = complete,
  ["textDocument/hover"] = hover,
  ["textDocument/definition"] = definition,
}

local refreshers = {} -- one per running server: re-publish diagnostics for its open docs

--- Re-lint every open .http buffer (after `:Honk env`, say).
function M.refresh()
  for _, f in pairs(refreshers) do
    f()
  end
end

local function server(dispatchers)
  local closing, id, open = false, 0, {}
  local function publish(uri)
    vim.schedule(function()
      if closing or not vim.api.nvim_buf_is_loaded(vim.uri_to_bufnr(uri)) then
        return
      end
      dispatchers.notification("textDocument/publishDiagnostics", {
        uri = uri,
        diagnostics = M.diagnostics((buf_lines(uri)), uri),
      })
    end)
  end
  refreshers[dispatchers] = function()
    for uri in pairs(open) do
      publish(uri)
    end
  end
  return {
    request = function(method, params, callback)
      id = id + 1
      local h = handlers[method]
      local ok, res = pcall(h or function() end, params)
      callback(nil, ok and res or nil)
      return true, id
    end,
    notify = function(method, params)
      if method == "textDocument/didOpen" or method == "textDocument/didChange" then
        open[params.textDocument.uri] = true
        publish(params.textDocument.uri)
      elseif method == "textDocument/didClose" then
        open[params.textDocument.uri] = nil
      elseif method == "exit" then
        closing = true
        refreshers[dispatchers] = nil
        dispatchers.on_exit(0, 15)
      end
    end,
    is_closing = function()
      return closing
    end,
    terminate = function()
      closing = true
      refreshers[dispatchers] = nil
    end,
  }
end

function M.start(bufnr)
  return vim.lsp.start({ name = "gooseman", cmd = server, root_dir = vim.fn.getcwd() }, { bufnr = bufnr })
end

return M
