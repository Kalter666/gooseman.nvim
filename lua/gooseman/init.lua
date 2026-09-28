-- gooseman.nvim — honks the request under the cursor from a .http file.
--   GET/POST/...  -> curl      (response in a scratch split)
--   GRPC          -> grpcurl   (server reflection; no method = list services)
--   WS            -> websocat  (interactive terminal; body lines sent on connect)
--
-- Directives (comment lines):
--   # @name login   name a request; others use {{login.body.token}}, {{login.headers.X}},
--                   {{login.status}}. Runs on first use, then cached for the session.
--   # @args ...     raw flags for the tool (mTLS, -proto, -k, cookie jars, ...)
--   # @header K: V  (before the first ###) header added to every request in the file
--   # @expect ...   assertion on the response (see expect.lua); `:Honk all` runs the file as a test
-- Before the first ###, @args also applies to every request.
-- Environments (gooseman.json) supply variables too, see env.lua.

local env = require "gooseman.env"
local expect = require "gooseman.expect"

local M = {}

M.METHODS = {
  GET = true, POST = true, PUT = true, PATCH = true, DELETE = true,
  HEAD = true, OPTIONS = true, TRACE = true, CONNECT = true,
  GRPC = true, WS = true,
}

--- Responses of named requests, shared by every file for the session. `:Honk!` clears it.
---@type table<string, {status:integer, headers:table<string,string>, body:any}>
M.responses = {}

local function is_comment(l)
  return l:match "^%s*#" or l:match "^%s*//"
end

--- Structure of a .http file; shared by the sender and the LSP. Nothing is expanded here.
function M.scan(lines)
  local s = { vars = {}, names = {}, blocks = {}, file_headers = {}, file_args = {}, dups = {} }
  local seps = {}
  for i, l in ipairs(lines) do
    if l:match "^###" then
      seps[#seps + 1] = i
    end
  end
  local ranges = {}
  if #seps == 0 then
    ranges[1] = { first = 1, last = #lines }
  else
    if seps[1] > 1 then
      ranges[1] = { first = 1, last = seps[1] - 1, preamble = true }
    end
    for j, sep in ipairs(seps) do
      ranges[#ranges + 1] = { first = sep + 1, last = (seps[j + 1] or #lines + 1) - 1, sep = sep }
    end
  end

  for _, b in ipairs(ranges) do
    b.args, b.headers, b.body, b.expects = {}, {}, {}, {}
    b.title = b.sep and lines[b.sep]:match "^###%s*(.-)%s*$" or ""
    local state = "pre"
    for i = b.first, b.last do
      local l = lines[i]
      if state == "body" then
        b.body[#b.body + 1] = i
      else
        local k, v = l:match "^@([%w_%-]+)%s*=%s*(.-)%s*$"
        local d, dv = l:match "^%s*#%s*@([%w%-]+)%s*(.-)%s*$"
        if k then
          s.vars[k] = { value = v, line = i }
        elseif d == "name" then
          if s.names[dv] then
            table.insert(s.dups, { name = dv, line = i })
          end
          b.name, b.name_line = dv, i
          s.names[dv] = b
        elseif d == "args" then
          table.insert(b.preamble and s.file_args or b.args, { text = dv, line = i })
        elseif d == "expect" then
          table.insert(b.expects, { text = dv, line = i })
        elseif d == "header" and b.preamble then
          table.insert(s.file_headers, { text = dv, line = i })
        elseif is_comment(l) then
          -- comment (or unknown directive; the LSP flags those)
        elseif state == "pre" then
          if l:match "%S" then
            b.req = { text = vim.trim(l), line = i }
            state = "headers"
          end
        elseif l:match "^%s*$" then
          state = "body"
        else
          table.insert(b.headers, { text = vim.trim(l), line = i })
        end
      end
    end
    -- trailing blank/comment lines belong to the gap before the next ###, not the body
    while #b.body > 0 and (lines[b.body[#b.body]]:match "^%s*$" or is_comment(lines[b.body[#b.body]])) do
      table.remove(b.body)
    end
    table.insert(s.blocks, b)
  end
  return s
end

function M.block_at(s, row)
  for _, b in ipairs(s.blocks) do
    if (row >= b.first and row <= b.last) or row == b.sep then
      return b
    end
  end
end

--- Every {{ref}} in a string: returns list of {ref, start_col, end_col} (1-based, inclusive).
function M.refs(str)
  local out, init = {}, 1
  while true do
    local s, e, ref = str:find("{{%s*([%w_%-%.]+)%s*}}", init)
    if not s then
      return out
    end
    out[#out + 1] = { ref = ref, s = s, e = e }
    init = e + 1
  end
end

--- Read a dotted path out of a stored response: status | headers.<name> | body.<key>.<index0>...
function M.field(resp, path)
  local parts = vim.split(path, ".", { plain = true })
  local v
  if parts[1] == "status" then
    v = resp.status
  elseif parts[1] == "headers" then
    v = resp.headers[(table.concat(parts, ".", 2)):lower()]
  elseif parts[1] == "body" then
    v = resp.body
    for i = 2, #parts do
      if type(v) ~= "table" then
        v = nil
        break
      end
      local n = tonumber(parts[i])
      v = (n and vim.islist(v)) and v[n + 1] or v[parts[i]]
    end
  end
  if v == nil or v == vim.NIL then
    return nil
  end
  return type(v) == "table" and vim.json.encode(v) or tostring(v)
end

-- Split curl -i output into header blocks (redirects/100-continue give several) and body.
local function split_http(out)
  out = out:gsub("\r", "")
  local heads = {}
  while out:match "^HTTP/" do
    local h, rest = out:match "^(.-\n)\n(.*)$"
    if not h then
      break
    end
    heads[#heads + 1], out = h, rest
  end
  return heads, out
end

--- Turn tool output into {status, headers, body}; JSON bodies are decoded.
function M.to_response(method, stdout)
  local resp = { status = 0, headers = {} }
  local body = stdout
  if method ~= "GRPC" then
    local heads
    heads, body = split_http(stdout)
    local last = heads[#heads] or ""
    resp.status = tonumber(last:match "^HTTP/%S+%s+(%d+)") or 0
    for k, v in last:gmatch "\n([^:\n]+):%s*([^\n]*)" do
      resp.headers[k:lower()] = v
    end
  end
  local ok, decoded = pcall(vim.json.decode, body)
  resp.body = ok and decoded or body
  resp.at = os.time()
  return resp
end

--- Seconds before expiry at which a cached token counts as stale.
M.EXPIRY_SKEW = 30

local function jwt_exp(s)
  local payload = type(s) == "string" and s:match "^[%w_%-]+%.([%w_%-]+)%.[%w_%-]*$"
  if not payload then
    return nil
  end
  payload = payload:gsub("%-", "+"):gsub("_", "/")
  local ok, json = pcall(vim.base64.decode, payload .. string.rep("=", (4 - #payload % 4) % 4))
  ok, json = pcall(vim.json.decode, ok and json or "")
  return ok and type(json) == "table" and tonumber(json.exp) or nil
end

--- When a cached response's credentials run out (epoch seconds), or nil if unknown:
--- the earliest JWT `exp` and `expires_in` (OAuth, counted from arrival) anywhere in the body.
function M.expires_at(resp)
  local t
  local function visit(v, depth)
    local x
    if type(v) == "string" then
      x = jwt_exp(v)
    elseif type(v) == "table" and depth < 5 then
      local ttl = not vim.islist(v) and tonumber(v.expires_in)
      x = ttl and resp.at and (resp.at + ttl)
      for _, child in pairs(v) do
        visit(child, depth + 1)
      end
    end
    if x and (not t or x < t) then
      t = x
    end
  end
  visit(resp.body, 0)
  return t
end

local expand

-- Response of a named request: cached, or run it now (synchronously) and cache it.
local function response_for(ctx, name, depth)
  local cached = M.responses[name]
  if cached then
    local exp = M.expires_at(cached)
    if not (exp and exp - M.EXPIRY_SKEW <= os.time()) then
      ctx.from_cache[name] = true
      return cached
    end
    M.responses[name] = nil -- token (nearly) expired: log in again now rather than eat a 401
  end
  local b = ctx.s.names[name]
  if not b then
    error(("request `%s` has not been sent yet"):format(name), 0)
  end
  if ctx.running[name] then
    error({ cycle = name })
  end
  local req = M.build(ctx, b, depth + 1)
  if req.method == "WS" then
    error(("`%s` is a WS request; only HTTP/GRPC responses can be reused"):format(name), 0)
  end
  local cmd, stdin = M.command(req)
  local r = vim.system(cmd, { stdin = stdin, text = true }):wait()
  local resp = M.to_response(req.method, r.stdout)
  if r.code ~= 0 or resp.status >= 400 then
    local why = vim.trim(r.stderr) ~= "" and vim.trim(r.stderr)
      or (type(resp.body) == "table" and vim.json.encode(resp.body) or vim.trim(tostring(resp.body)))
    error(("dependency `%s` failed (exit %d, status %d): %s"):format(name, r.code, resp.status, why:sub(1, 200)), 0)
  end
  M.responses[name] = resp
  return resp
end

local function lookup(ctx, key, depth)
  if ctx.resolved[key] then
    return ctx.resolved[key]
  end
  local var = ctx.s.vars[key] or ctx.env[key]
  if var then
    local v = expand(var.value, ctx, depth + 1)
    local sh = v:match "^%$%((.*)%)$"
    if sh then
      local r = vim.system({ "sh", "-c", sh }, { text = true }):wait()
      if r.code ~= 0 then
        error(("@%s: `%s` failed: %s"):format(key, sh, vim.trim(r.stderr)), 0)
      end
      v = vim.trim(r.stdout)
    end
    ctx.resolved[key] = v
    return v
  end
  local name, path = key:match "^([^.]+)%.(.+)$"
  if name and (ctx.s.names[name] or M.responses[name]) then
    if ctx.running[name] then -- even when cached: a request never feeds on its own old response
      error({ cycle = name })
    end
    local v = M.field(response_for(ctx, name, depth), path)
    if not v then
      error(("response of `%s` has no %s"):format(name, path), 0)
    end
    return v
  end
  return os.getenv(key)
end

-- {{name}} -> file var (may reference others; `$(cmd)` runs through sh, once per send),
-- else a named response field, else env var, else left as is.
-- ponytail: `$(cmd)` runs synchronously on every send; name the request instead if it's a login
function expand(str, ctx, depth)
  depth = depth or 0
  if depth > 10 then
    error("variables reference each other too deep (cycle?)", 0)
  end
  return (str:gsub("{{%s*([%w_%-%.]+)%s*}}", function(k)
    return lookup(ctx, k, depth)
  end))
end

--- Expansion state for one send. `path` locates gooseman.json (defaults to cwd).
function M.context(lines, path)
  return { lines = lines, s = M.scan(lines), env = env.vars(path), resolved = {}, running = {}, from_cache = {} }
end

function M.expand(str, ctx)
  return expand(str, ctx, 0)
end

-- ponytail: whitespace split, no shell quoting; paths with spaces need a var without spaces
local function split_args(list, ctx, depth, into)
  for _, a in ipairs(list) do
    vim.list_extend(into, vim.split(expand(a.text, ctx, depth), "%s+", { trimempty = true }))
  end
  return into
end

--- Expand a scanned block into a request.
function M.build(ctx, b, depth)
  depth = depth or 0
  if not b.req then
    error("no request under cursor", 0)
  end
  if b.name then
    ctx.running[b.name] = true
  end
  local method, rest = b.req.text:match "^(%u+)%s+(.-)$"
  if not (method and M.METHODS[method]) then
    error("not a request line: " .. b.req.text, 0)
  end
  rest = expand(rest:gsub("%s+HTTP/[%d%.]+$", ""), ctx, depth)
  local url, target = rest:match "^(%S+)%s*(.-)$"
  local req = { method = method, url = url, target = target ~= "" and target or nil, name = b.name, headers = {} }

  local own = {}
  for _, h in ipairs(b.headers) do
    own[(h.text:match "^([^:]+)" or ""):lower()] = true
  end
  for _, h in ipairs(ctx.s.file_headers) do
    if not own[(h.text:match "^([^:]+)" or ""):lower()] then
      -- a file-wide header built from this request's own response (auth via login) is skipped here
      local ok, v = pcall(expand, h.text, ctx, depth)
      if ok then
        table.insert(req.headers, v)
      elseif not (type(v) == "table" and v.cycle == b.name) then
        error(v, 0)
      end
    end
  end
  for _, h in ipairs(b.headers) do
    table.insert(req.headers, expand(h.text, ctx, depth))
  end

  local body = {}
  for _, i in ipairs(b.body) do
    body[#body + 1] = ctx.lines[i]
  end
  req.body = expand(table.concat(body, "\n"), ctx, depth)
  req.args = split_args(b.args, ctx, depth, split_args(ctx.s.file_args, ctx, depth, {}))
  if b.name then
    ctx.running[b.name] = nil
  end
  return req
end

--- Parse + expand the block containing `row` (1-based).
function M.parse(lines, row, path)
  local ctx = M.context(lines, path)
  local b = M.block_at(ctx.s, row)
  if not (b and b.req) then
    return nil, "no request under cursor"
  end
  return M.build(ctx, b)
end

--- Build the argv (and stdin) for a parsed request.
---@return string[] cmd, string? stdin
function M.command(req)
  local cmd
  local extra = req.args or {}
  if req.method == "GRPC" then
    -- grpc://host:port = plaintext, anything else = TLS
    local plain = req.url:match "^grpc://"
    local addr = req.url:gsub("^grpcs?://", "")
    cmd = vim.list_extend({ "grpcurl" }, extra)
    if plain then
      table.insert(cmd, "-plaintext")
    end
    for _, h in ipairs(req.headers) do
      vim.list_extend(cmd, { "-H", h })
    end
    if req.target and req.target:find "/" then
      vim.list_extend(cmd, { "-d", "@", addr, req.target })
      return cmd, req.body ~= "" and req.body or "{}"
    end
    vim.list_extend(cmd, { addr, "list" })
    if req.target then
      table.insert(cmd, req.target)
    end
    return cmd, nil
  elseif req.method == "WS" then
    -- URL before -H: websocat's -H is multi-value and would swallow a trailing URL
    cmd = vim.list_extend({ "websocat" }, extra)
    table.insert(cmd, req.url)
    for _, h in ipairs(req.headers) do
      vim.list_extend(cmd, { "-H", h })
    end
    return cmd, req.body ~= "" and req.body or nil
  end
  cmd = vim.list_extend({ "curl" }, extra)
  vim.list_extend(cmd, { "-sS", "-i", "-X", req.method, req.url })
  for _, h in ipairs(req.headers) do
    vim.list_extend(cmd, { "-H", h })
  end
  if req.body ~= "" then
    vim.list_extend(cmd, { "--data-binary", "@-" })
    return cmd, req.body
  end
  return cmd, nil
end

local result_buf

local function show(lines)
  if not (result_buf and vim.api.nvim_buf_is_valid(result_buf)) then
    result_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(result_buf, "gooseman://response")
    vim.bo[result_buf].bufhidden = "hide"
  end
  if vim.fn.bufwinid(result_buf) == -1 then
    local win = vim.api.nvim_get_current_win()
    vim.cmd "botright vsplit"
    vim.api.nvim_win_set_buf(0, result_buf)
    vim.api.nvim_set_current_win(win)
  end
  vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, lines)
end

-- Header blocks as-is, JSON body pretty-printed with jq.
local function format_http(out)
  local heads, body = split_http(out)
  if #heads == 0 then
    return out
  end
  local head = table.concat(heads, "\n")
  if head:lower():find "content%-type:[^\n]*json" and vim.fn.executable "jq" == 1 then
    local r = vim.system({ "jq", "." }, { stdin = body }):wait()
    if r.code == 0 then
      body = r.stdout
    end
  end
  return head .. "\n" .. body
end

--- Last response of every request sent, for the LSP's "add @expect from last response".
M.last = {}

function M.last_key(path, b)
  return (path or "") .. "\0" .. b.req.text
end

M.REFRESH_COOLDOWN = 60
local refreshed_at = {} -- named request -> os.time() of its last auto-refresh

local function errmsg(e)
  return type(e) == "table" and ("request `%s` depends on itself"):format(e.cycle) or tostring(e)
end

--- Build and run one block asynchronously; `cb(res)` gets
--- {req, r, resp, ms, retried, checks} or {err}.
--- A 401 on a request that used cached named responses (a login token, say)
--- forgets those, re-runs them and retries once. To go easy on rate limits:
--- 401 only (403 means forbidden, a fresh token won't help), each named request is
--- refreshed at most once per REFRESH_COOLDOWN seconds, and
--- `vim.g.gooseman_auto_refresh = false` turns it off.
function M.run(lines, b, path, cb)
  local function attempt(retried)
    local ctx = M.context(lines, path)
    local ok, req = pcall(M.build, ctx, b)
    if not ok then
      return cb { err = errmsg(req) }
    end
    local cmd, stdin = M.command(req)
    if vim.fn.executable(cmd[1]) == 0 then
      return cb { err = cmd[1] .. " not installed" }
    end
    local start = vim.uv.hrtime()
    vim.system(cmd, { stdin = stdin, text = true }, vim.schedule_wrap(function(r)
      local resp = M.to_response(req.method, r.stdout)
      local stale = not retried and resp.status == 401 and vim.g.gooseman_auto_refresh ~= false
        and vim.tbl_filter(function(name)
          return os.time() - (refreshed_at[name] or 0) >= M.REFRESH_COOLDOWN
        end, vim.tbl_keys(ctx.from_cache))
      if stale and #stale > 0 then
        for _, name in ipairs(stale) do
          M.responses[name], refreshed_at[name] = nil, os.time()
        end
        return attempt(stale)
      end
      if req.name and r.code == 0 then
        M.responses[req.name] = resp
      end
      M.last[M.last_key(path, b)] = resp
      local checks = expect.check(b.expects, resp, r.code, M.field, function(v)
        return M.expand(v, ctx)
      end)
      cb {
        req = req, r = r, resp = resp, retried = retried, checks = checks,
        ms = math.floor((vim.uv.hrtime() - start) / 1e6),
      }
    end))
  end
  attempt(false)
end

local function title_of(req)
  return vim.trim(("%s %s %s"):format(req.method, req.url, req.target or ""))
end

local function render(res)
  local out = {
    ("%s  (%dms, exit %d%s)"):format(
      title_of(res.req), res.ms, res.r.code,
      res.retried and (", retried after refreshing " .. table.concat(res.retried, ", ")) or ""
    ),
  }
  for _, c in ipairs(res.checks) do
    if c.text ~= "succeeds" then -- the default check is implied by the status line
      out[#out + 1] = (c.ok and "  ✓ " or "  ✗ ") .. c.text .. (c.ok and "" or ("   (got " .. tostring(c.got) .. ")"))
    end
  end
  out[#out + 1] = ""
  local text = res.r.stdout .. (res.r.stderr ~= "" and ("\n" .. res.r.stderr) or "")
  if res.req.method ~= "GRPC" then
    text = format_http(text)
  end
  return vim.list_extend(out, vim.split(text, "\n"))
end

local function current()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local b = M.block_at(M.scan(lines), row)
  return lines, b, vim.api.nvim_buf_get_name(0), row
end

---@param opts? {fresh:boolean} fresh: forget cached named responses first
function M.send(opts)
  if opts and opts.fresh then
    M.responses = {}
  end
  local lines, b, path = current()
  if not (b and b.req) then
    return vim.notify("gooseman: no request under cursor", vim.log.levels.WARN)
  end

  if b.req.text:match "^WS%s" then
    local ok, req = pcall(M.build, M.context(lines, path), b)
    if not ok then
      return vim.notify("gooseman: " .. errmsg(req), vim.log.levels.WARN)
    end
    local cmd, stdin = M.command(req)
    if vim.fn.executable(cmd[1]) == 0 then
      return vim.notify("gooseman: websocat not installed", vim.log.levels.ERROR)
    end
    vim.cmd "botright split"
    local job = vim.fn.jobstart(cmd, { term = true })
    if stdin then
      vim.fn.chansend(job, stdin .. "\n")
    end
    return vim.cmd "startinsert"
  end

  show { b.req.text .. "  …" }
  M.run(lines, b, path, function(res)
    if res.err then
      show { "gooseman: " .. res.err }
      return vim.notify("gooseman: " .. res.err, vim.log.levels.WARN)
    end
    show(render(res))
  end)
end

--- Run every HTTP/gRPC request in the buffer top to bottom (WS skipped); report + quickfix.
function M.send_all(opts)
  if opts and opts.fresh then
    M.responses = {}
  end
  local lines, _, path = current()
  local bufnr = vim.api.nvim_get_current_buf()
  local blocks = vim.tbl_filter(function(b)
    return b.req and not b.req.text:match "^WS%s"
  end, M.scan(lines).blocks)
  local report, qf, failed, i = {}, {}, 0, 0
  local started = vim.uv.hrtime()

  local function finish()
    local ms = math.floor((vim.uv.hrtime() - started) / 1e6)
    local head = ("honk all: %d passed, %d failed  (%dms%s)"):format(
      #blocks - failed, failed, ms, env.active and (", env " .. env.active) or ""
    )
    show(vim.list_extend({ head, "" }, report))
    vim.fn.setqflist({}, "r", { title = "gooseman", items = qf })
    vim.notify("gooseman: " .. head, failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
  end

  local function step()
    i = i + 1
    local b = blocks[i]
    if not b then
      return finish()
    end
    show { ("honk all: %d/%d  %s"):format(i, #blocks, b.req.text) }
    M.run(lines, b, path, function(res)
      local name = b.title ~= "" and b.title or b.req.text
      local bad = {}
      if res.err then
        bad[1] = res.err
      else
        for _, c in ipairs(res.checks) do
          if not c.ok then
            bad[#bad + 1] = c.text .. "   (got " .. tostring(c.got) .. ")"
          end
        end
      end
      local status = res.resp and (res.req.method == "GRPC" and ("exit " .. res.r.code) or res.resp.status) or "-"
      report[#report + 1] = ("%s %s   %s  %s"):format(#bad == 0 and "✓" or "✗", name, status, res.ms and (res.ms .. "ms") or "")
      for _, m in ipairs(bad) do
        report[#report + 1] = "    " .. m
        qf[#qf + 1] = { bufnr = bufnr, lnum = b.req.line, text = name .. ": " .. m }
      end
      if #bad > 0 then
        failed = failed + 1
      end
      step()
    end)
  end
  step()
end

--- Copy the request under the cursor as a shell command.
function M.copy_curl()
  local lines, b, path = current()
  if not (b and b.req) then
    return vim.notify("gooseman: no request under cursor", vim.log.levels.WARN)
  end
  local ok, req = pcall(M.build, M.context(lines, path), b)
  if not ok then
    return vim.notify("gooseman: " .. errmsg(req), vim.log.levels.WARN)
  end
  local line = require("gooseman.curl").export(M.command(req))
  vim.fn.setreg("+", line)
  vim.fn.setreg('"', line)
  vim.notify("gooseman: copied " .. line:sub(1, 80) .. (#line > 80 and "…" or ""))
end

--- Turn a curl command into a .http block: from the given line range (replaced),
--- else from the clipboard (inserted after the current block).
function M.import_curl(line1, line2)
  local text = line1 and table.concat(vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false), "\n")
    or vim.fn.getreg "+"
  if text == "" then
    text = vim.fn.getreg '"'
  end
  local ok, block = pcall(require("gooseman.curl").to_http, text)
  if not ok then
    return vim.notify("gooseman: " .. block, vim.log.levels.WARN)
  end
  if line1 then
    return vim.api.nvim_buf_set_lines(0, line1 - 1, line2, false, block)
  end
  local _, b, _, row = current()
  local at = b and b.last or row
  table.insert(block, 1, "")
  vim.api.nvim_buf_set_lines(0, at, at, false, block)
  vim.api.nvim_win_set_cursor(0, { at + 2, 0 })
end

--- For statuslines: "🪿 dev" when an environment is active.
function M.statusline()
  return env.active and ("🪿 " .. env.active) or ""
end

return M
