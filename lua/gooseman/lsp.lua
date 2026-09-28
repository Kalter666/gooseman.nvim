-- In-process language server for .http files: no binary, runs inside nvim.
--   completion   snippets, {{vars}}, {{named.body.fields}}, methods, gRPC methods (reflection),
--                headers, header values, # @directives, @expect paths/operators
--   hover        what a {{ref}} resolves to (shell vars are shown, not run; secrets masked; token expiry)
--   definition   {{ref}} -> its @var line, `# @name` line or gooseman.json entry
--   diagnostics  undefined refs, unknown methods/directives, bad @expect, duplicate names
--   code actions send, copy as curl, name request, extract to @var, @expect from last response,
--                gRPC body template
--   inlay hints  {{ref}} = its value (secrets masked, tokens as "jwt, 4m left")
--   semantic     {{refs}} coloured by kind, directives, methods, ### titles

local g = require "gooseman"
local env = require "gooseman.env"
local expect = require "gooseman.expect"
local snippets = require "gooseman.snippets"
local grpc = require "gooseman.grpc"

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
  stream = "show the response live in a terminal (SSE, streaming APIs)",
  each = "send once per row of a data file: users.csv (header row = variable names) or users.json",
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

-- {{refs}} resolved from @vars, the environment, OS env and *cached* responses, never running
-- anything (no $(shell), no login) since this happens while typing. Unresolvable -> nil.
-- `mask`: private env and OS env values come out as •••• (for text shown on screen).
local function resolve_plain(str, s, mask)
  for _ = 1, 5 do -- values may reference other values
    if not str:find "{{" then
      return str
    end
    local stuck = false
    str = str:gsub("{{%s*([%w_%-%.]+)%s*}}", function(k)
      local e = s.vars[k] or s.env[k]
      if mask and ((e and e.private) or (not e and os.getenv(k))) then
        return "••••"
      end
      local v = e and e.value or os.getenv(k)
      if not v then
        local name, path = k:match "^([^.]+)%.(.+)$"
        local resp = name and g.responses[name]
        v = resp and g.field(resp, path)
      end
      if not v or v:find "%$%(" then
        stuck = true
        return nil
      end
      return v
    end)
    if stuck then
      return nil
    end
  end
  return not str:find "{{" and str or nil
end

-- grpcurl flags for reflection calls: the block's (and file-wide) headers as -H, plus @args.
-- Anything that can't be resolved without sending is left out.
local function grpc_flags(s, b)
  local own, headers, flags = {}, {}, {}
  for _, h in ipairs(b and b.headers or {}) do
    own[(h.text:match "^([^:]+)" or ""):lower()] = true
  end
  for _, h in ipairs(s.file_headers) do
    if not own[(h.text:match "^([^:]+)" or ""):lower()] then
      headers[#headers + 1] = h
    end
  end
  for _, h in ipairs(vim.list_extend(headers, b and b.headers or {})) do
    local v = resolve_plain(h.text, s)
    if v then
      vim.list_extend(flags, { "-H", v })
    end
  end
  for _, a in ipairs(vim.list_extend(vim.list_extend({}, s.file_args), b and b.args or {})) do
    local v = resolve_plain(a.text, s)
    if v then
      vim.list_extend(flags, vim.split(v, "%s+", { trimempty = true }))
    end
  end
  return flags
end

local function has_file_header(s, header)
  local name = header:match("^([^:]+)"):lower()
  for _, h in ipairs(s.file_headers) do
    if (h.text:match "^([^:]+)" or ""):lower() == name then
      return true
    end
  end
end

-- `pos`: the cursor; snippets replace the whole line up to it, since prefixes like
-- `post-json` aren't one keyword and clients would otherwise filter on `json` alone
local function snippet_items(s, row, pos)
  local out = {}
  for _, sn in ipairs(snippets.list) do
    local body = sn.body
    local item = {
      label = sn.prefix,
      kind = K.Snippet,
      detail = sn.desc,
      insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet,
      documentation = { kind = "markdown", value = "```http\n" .. snippets.preview(body) .. "\n```" },
    }
    if sn.header and not has_file_header(s, sn.header) then
      local line = "# @header " .. sn.header .. "\n"
      if row == 1 then
        body = line .. body -- the edit would collide with the snippet at the top of the file
      else
        local top = { line = 0, character = 0 }
        item.additionalTextEdits = { { range = { start = top, ["end"] = top }, newText = line } }
      end
    end
    item.textEdit = { range = { start = { line = row - 1, character = 0 }, ["end"] = pos }, newText = snippets.lsp_body(body) }
    out[#out + 1] = item
  end
  return out
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
  local url, partial = before:match "^GRPC%s+(%S+)%s+(%S*)$"
  if r == "request" and url then
    local resolved = resolve_plain(url, s)
    local out = {}
    local range = {
      start = { line = row - 1, character = #before - #partial },
      ["end"] = { line = row - 1, character = #before },
    }
    for _, m in ipairs(resolved and grpc.methods(resolved, grpc_flags(s, g.block_at(s, row))) or {}) do
      out[#out + 1] = { label = m, kind = K.Method, detail = "gRPC " .. resolved, textEdit = { range = range, newText = m } }
    end
    return out
  end
  if r == "request" and before:match "^%u*$" then
    return vim.list_extend(items(vim.tbl_keys(g.METHODS), K.Keyword), snippet_items(s, row, params.position))
  end
  if r ~= "header" and before:match "^%a[%w%-]*$" then
    return snippet_items(s, row, params.position)
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

local function duration(sec)
  return sec >= 3600 and ("%dh%02dm"):format(sec / 3600, sec % 3600 / 60)
    or sec >= 60 and ("%dm%02ds"):format(sec / 60, sec % 60)
    or (sec .. "s")
end

local function token_note(v)
  local exp = g.jwt_exp(v)
  if exp then
    local left = exp - os.time()
    return "jwt, " .. (left <= 0 and "expired" or (duration(left) .. " left"))
  end
end

-- short, safe text for an inlay hint; nil = no hint
local function hint_value(s, ref)
  local kind, name = kind_of(s, ref)
  local v
  if kind == "var" then
    local raw = s.vars[ref].value
    v = raw:find "%$%(" and "$(…)" or (resolve_plain(raw, s, true) or raw)
  elseif kind == "envfile" then
    local e = s.env[ref]
    v = e.private and "••••" or (resolve_plain(e.value, s, true) or e.value)
  elseif kind == "response" then
    local resp = g.responses[name]
    if not resp then
      return "not sent yet"
    end
    v = g.field(resp, ref:sub(#name + 2))
    if not v then
      return nil
    end
    local note = token_note(v)
    if note then
      return note
    end
  elseif kind == "env" then
    return "••••" -- OS env: likely a secret, never shown
  else
    return nil
  end
  return #v > 40 and (v:sub(1, 37) .. "…") or v
end

local function inlay_hints(params)
  local uri = params.textDocument.uri
  local lines = buf_lines(uri)
  local s = scan(lines, uri)
  local out = {}
  for row = params.range.start.line + 1, math.min(params.range["end"].line + 1, #lines) do
    local l = lines[row]
    if not l:match "^%s*#" or l:match "^%s*#%s*@" then
      for _, r in ipairs(g.refs(l)) do
        local v = hint_value(s, r.ref)
        if v then
          out[#out + 1] = { position = { line = row - 1, character = r.e }, label = "= " .. v, paddingLeft = true }
        end
      end
    end
  end
  return out
end

local TOKEN_TYPES = { "variable", "parameter", "function", "enumMember", "macro", "keyword", "namespace" }
local TT = { var = 0, envfile = 1, response = 2, env = 3, directive = 4, method = 5, title = 6 }

local function semantic_tokens(params)
  local uri = params.textDocument.uri
  local lines = buf_lines(uri)
  local s = scan(lines, uri)
  local toks = {}
  for row, l in ipairs(lines) do
    if l:match "^###" then
      toks[#toks + 1] = { row - 1, 0, #l, TT.title }
    elseif not l:match "^%s*//" then
      local dir = l:match "^%s*#%s*@" and l:find "@[%w%-]+"
      if dir then
        local _, e = l:find("@[%w%-]+", dir)
        toks[#toks + 1] = { row - 1, dir - 1, e - dir + 1, TT.directive }
      end
      local name = l:match "^@([%w_%-]+)"
      if name then
        toks[#toks + 1] = { row - 1, 0, #name + 1, TT.var }
      end
      if dir or not l:match "^%s*#" then
        for _, r in ipairs(g.refs(l)) do
          local kind = kind_of(s, r.ref)
          if kind then
            toks[#toks + 1] = { row - 1, r.s - 1, r.e - r.s + 1, TT[kind] }
          end
        end
      end
    end
  end
  for _, b in ipairs(s.blocks) do
    local m = b.req and b.req.text:match "^(%u+)%s"
    if m and g.METHODS[m] then
      local col = lines[b.req.line]:find(m, 1, true)
      toks[#toks + 1] = { b.req.line - 1, col - 1, #m, TT.method }
    end
  end
  table.sort(toks, function(a, b)
    return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
  end)
  local data, pr, pc = {}, 0, 0
  for _, t in ipairs(toks) do
    local dl = t[1] - pr
    vim.list_extend(data, { dl, dl == 0 and (t[2] - pc) or t[2], t[3], t[4], 0 })
    pr, pc = t[1], t[2]
  end
  return { data = data }
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
    local exp = resp and g.expires_at(resp)
    if exp then
      local left = exp - os.time()
      text = text .. "\n\n" .. (left <= 0 and "*token expired, refreshes on next use*" or ("*token expires in " .. duration(left) .. "*"))
    end
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
        return { { uri = vim.uri_from_fname(file), range = { start = pos, ["end"] = pos } } }
      end
    end
  end
  local line = kind == "var" and s.vars[r.ref].line or (kind == "response" and s.names[name] and s.names[name].name_line)
  if not line then
    return nil
  end
  -- a list, not a bare Location: tagfunc (Ctrl-]) only takes lists
  return { {
    uri = params.textDocument.uri,
    range = { start = { line = line - 1, character = 0 }, ["end"] = { line = line - 1, character = 0 } },
  } }
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
  local columns = {} -- row -> first row of its block's @each file (its keys are defined there)
  for _, b in ipairs(s.blocks) do
    if b.each then
      local ok, rows = pcall(g.rows, b, vim.uri_to_fname(uri))
      if not ok then
        add(b.each.line, 0, #lines[b.each.line], rows, vim.lsp.protocol.DiagnosticSeverity.Error)
      end
      for i = b.first, b.last do
        columns[i] = ok and rows[1] or {}
      end
    end
  end
  for row, l in ipairs(lines) do
    if not l:match "^%s*#" or l:match "^%s*#%s*@" then
      for _, r in ipairs(g.refs(l)) do
        if not kind_of(s, r.ref) and not (columns[row] or {})[r.ref] then
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

local function slug(str)
  local out = str:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""):sub(1, 30)
  return out ~= "" and out or "req"
end

-- run f in a window showing the buffer, cursor on row (for commands that act "at cursor")
local function at_row(uri, row, f)
  local win = vim.fn.bufwinid(vim.uri_to_bufnr(uri))
  if win ~= -1 then
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      f()
    end)
  end
end

local function block_for(uri, row)
  local lines, bufnr = buf_lines(uri)
  local s = scan(lines, uri)
  return g.block_at(s, row), bufnr, lines, s
end

local COMMANDS = {
  ["gooseman.send"] = function(uri, row)
    at_row(uri, row, g.send)
  end,
  ["gooseman.curl"] = function(uri, row)
    at_row(uri, row, g.copy_curl)
  end,
  ["gooseman.name"] = function(uri, row)
    local b, bufnr = block_for(uri, row)
    vim.ui.input({ prompt = "request name: ", default = slug(b.title ~= "" and b.title or b.req.text) }, function(name)
      if name and name:match "^[%w_%-]+$" then
        local at = b.sep or (b.first - 1)
        vim.api.nvim_buf_set_lines(bufnr, at, at, false, { "# @name " .. name })
      end
    end)
  end,
  ["gooseman.expect"] = function(uri, row)
    local b, bufnr, lines = block_for(uri, row)
    local resp = g.last[g.last_key(vim.uri_to_fname(uri), b)]
    if not resp then
      return
    end
    local want = {}
    if not b.req.text:match "^GRPC" then
      want[#want + 1] = "status == " .. resp.status
    end
    if (resp.headers["content-type"] or ""):find "json" then
      want[#want + 1] = "headers.content-type contains json"
    end
    if type(resp.body) == "table" then
      local keys = vim.islist(resp.body) and (#resp.body > 0 and { "0" } or {}) or vim.tbl_keys(resp.body)
      table.sort(keys)
      for i = 1, math.min(#keys, 5) do
        if keys[i]:match "^[%w_%-]+$" then
          want[#want + 1] = "body." .. keys[i] .. " exists"
        end
      end
    end
    local have, add = {}, {}
    for _, e in ipairs(b.expects) do
      have[e.text] = true
    end
    for _, w in ipairs(want) do
      if not have[w] then
        add[#add + 1] = "# @expect " .. w
      end
    end
    local at = b.name_line or b.sep or (b.first - 1)
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, add)
  end,
  ["gooseman.grpc_template"] = function(uri, row)
    -- explicit action: full expansion, so a login it depends on may run
    local b, bufnr, lines = block_for(uri, row)
    local ok, req = pcall(g.build, g.context(lines, vim.uri_to_fname(uri)), b)
    if not ok then
      return vim.notify("gooseman: " .. (type(req) == "table" and "request depends on itself" or req), vim.log.levels.WARN)
    end
    local flags = vim.deepcopy(req.args)
    for _, h in ipairs(req.headers) do
      vim.list_extend(flags, { "-H", h })
    end
    local tmpl, err = grpc.template(req.url, req.target, flags)
    if not tmpl then
      return vim.notify("gooseman: " .. err, vim.log.levels.WARN)
    end
    local at = #b.headers > 0 and b.headers[#b.headers].line or b.req.line
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, vim.list_extend({ "" }, vim.split(tmpl, "\n")))
  end,
  ["gooseman.extract"] = function(uri, row, s_col, e_col)
    local lines, bufnr = buf_lines(uri)
    local text = lines[row]:sub(s_col + 1, e_col)
    local guess = text:match "^https?://" and "host" or text:match "^grpcs?://" and "grpc" or "value"
    vim.ui.input({ prompt = ("@var for %q: "):format(text), default = guess }, function(name)
      if not (name and name:match "^[%w_%-]+$") then
        return
      end
      local at, first_sep = 0, nil
      for i, l in ipairs(lines) do
        first_sep = first_sep or (l:match "^###" and i)
        if not first_sep and l:match "^@" then
          at = i -- after the last @var of the preamble
        end
        -- only request/header/body text, and never inside an existing {{ref}}
        if not (l:match "^@" or l:match "^###" or l:match "^%s*#" or l:match "^%s*//") then
          local out, pos = {}, 1
          for _, r in ipairs(vim.list_extend(g.refs(l), { { s = #l + 1, e = #l } })) do
            out[#out + 1] = l:sub(pos, r.s - 1):gsub(vim.pesc(text), "{{" .. name .. "}}")
            out[#out + 1] = l:sub(r.s, r.e)
            pos = r.e + 1
          end
          lines[i] = table.concat(out)
        end
      end
      table.insert(lines, at + 1, ("@%s = %s"):format(name, text))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end)
  end,
}

local function code_actions(params)
  local uri, rng = params.textDocument.uri, params.range
  local row = rng.start.line + 1
  local b, _, lines = block_for(uri, row)
  local acts = {}
  local function act(title, command, ...)
    acts[#acts + 1] = { title = title, command = { title = title, command = command, arguments = { uri, row, ... } } }
  end
  if b and b.req then
    act("Honk: send this request", "gooseman.send")
    act("Honk: copy as curl", "gooseman.curl")
    if not b.name then
      act("Honk: name this request", "gooseman.name")
    end
    if g.last[g.last_key(vim.uri_to_fname(uri), b)] then
      act("Honk: add @expect from the last response", "gooseman.expect")
    end
    if b.req.text:match "^GRPC%s+%S+%s+%S+/%S+" and #b.body == 0 then
      act("Honk: insert gRPC request template", "gooseman.grpc_template")
    end
  end
  if rng.start.line == rng["end"].line and rng["end"].character > rng.start.character then
    local text = (lines[row] or ""):sub(rng.start.character + 1, rng["end"].character)
    if vim.trim(text) ~= "" and not text:find "{{" and not text:find "}}" then
      act("Honk: extract to @var", "gooseman.extract", rng.start.character, rng["end"].character)
    end
  end
  return acts
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
        codeActionProvider = true,
        inlayHintProvider = true,
        semanticTokensProvider = { legend = { tokenTypes = TOKEN_TYPES, tokenModifiers = {} }, full = true },
        executeCommandProvider = { commands = vim.tbl_keys(COMMANDS) },
      },
      serverInfo = { name = "gooseman" },
    }
  end,
  shutdown = function() end,
  ["textDocument/completion"] = complete,
  ["textDocument/hover"] = hover,
  ["textDocument/definition"] = definition,
  ["textDocument/codeAction"] = code_actions,
  ["textDocument/inlayHint"] = inlay_hints,
  ["textDocument/semanticTokens/full"] = semantic_tokens,
  ["workspace/executeCommand"] = function(params)
    local f = COMMANDS[params.command]
    if f then
      f(unpack(params.arguments or {}))
    end
  end,
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
    -- values behind hints/colours changed (new cached response, other env): ask to re-fetch
    for _, m in ipairs { "workspace/inlayHint/refresh", "workspace/semanticTokens/refresh" } do
      pcall(dispatchers.server_request, m, nil)
    end
  end
  return {
    request = function(method, params, callback)
      id = id + 1
      local h = handlers[method]
      local ok, res = pcall(h or function() end, params)
      -- answer on the next tick like a real server: clients (native completion's omnifunc)
      -- may be under textlock while the request is made
      vim.schedule(function()
        callback(nil, ok and res or nil)
      end)
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
