-- gooseman.nvim — honks the request under the cursor from a .http file.
--   GET/POST/...  -> curl      (response in a scratch split)
--   GRPC          -> grpcurl   (server reflection; no method = list services)
--   WS            -> websocat  (interactive terminal; body lines sent on connect)
--   `# @args ...` in a block appends raw flags to the tool (mTLS, -proto, -k, ...)

local M = {}

local HTTP_METHODS = {
  GET = true, POST = true, PUT = true, PATCH = true, DELETE = true,
  HEAD = true, OPTIONS = true, TRACE = true, CONNECT = true,
}

-- `@name = value` lines anywhere in the file; later wins.
local function collect_vars(lines)
  local vars = {}
  for _, l in ipairs(lines) do
    local k, v = l:match "^@([%w_%-%.]+)%s*=%s*(.-)%s*$"
    if k then
      vars[k] = v
    end
  end
  return vars
end

-- {{name}} -> file var, else env var, else left as is.
-- File vars may reference other vars; a `$(cmd)` value runs through sh when first used.
-- ponytail: `$(cmd)` runs synchronously on every send; cache tokens to a file if the cmd is slow
local function expand(s, vars, depth)
  depth = depth or 0
  if depth > 10 then
    error "variables reference each other too deep (cycle?)"
  end
  return (s:gsub("{{%s*([%w_%-%.]+)%s*}}", function(k)
    local v = vars[k]
    if v == nil then
      return os.getenv(k)
    elseif type(v) == "table" then -- already resolved during this send
      return v[1]
    end
    v = expand(v, vars, depth + 1)
    local sh = v:match "^%$%((.*)%)$"
    if sh then
      local r = vim.system({ "sh", "-c", sh }, { text = true }):wait()
      if r.code ~= 0 then
        error(("@%s: `%s` failed: %s"):format(k, sh, vim.trim(r.stderr)), 0)
      end
      v = vim.trim(r.stdout)
    end
    vars[k] = { v }
    return v
  end))
end

--- Parse the `###`-delimited block containing `row` (1-based).
---@return {method:string, url:string, target:string?, headers:string[], body:string}?, string? err
function M.parse(lines, row)
  local first, last = 1, #lines
  for i = row, 1, -1 do
    if lines[i]:match "^###" then
      first = i + 1
      break
    end
  end
  for i = row + 1, #lines do
    if lines[i]:match "^###" then
      last = i - 1
      break
    end
  end

  local vars = collect_vars(lines)
  local req, body, in_body, args = nil, {}, false, {}
  for i = first, last do
    local l = lines[i]
    local extra = not in_body and l:match "^%s*#%s*@args%s+(.-)%s*$"
    if extra then
      -- ponytail: whitespace split, no shell quoting; paths with spaces need a var without spaces
      vim.list_extend(args, vim.split(expand(extra, vars), "%s+", { trimempty = true }))
    elseif in_body then
      body[#body + 1] = l
    elseif l:match "^%s*#" or l:match "^%s*//" or l:match "^@" then
      -- comment or variable
    elseif not req then
      if l:match "%S" then
        local method, rest = l:match "^%s*(%u+)%s+(.-)%s*$"
        if not method then
          return nil, "not a request line: " .. l
        end
        rest = expand(rest:gsub("%s+HTTP/[%d%.]+$", ""), vars)
        local url, target = rest:match "^(%S+)%s*(.-)$"
        req = { method = method, url = url, target = target ~= "" and target or nil, headers = {} }
      end
    elseif l:match "^%s*$" then
      in_body = true
    else
      table.insert(req.headers, expand(vim.trim(l), vars))
    end
  end
  if not req then
    return nil, "no request under cursor"
  end
  -- trailing blank/comment lines belong to the gap before the next ###, not the body
  while #body > 0 and (body[#body]:match "^%s*$" or body[#body]:match "^%s*#" or body[#body]:match "^%s*//") do
    table.remove(body)
  end
  req.body = expand(table.concat(body, "\n"), vars)
  req.args = args
  return req
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
  elseif HTTP_METHODS[req.method] then
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
  error("unknown method: " .. req.method)
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

-- Split curl -i output into header/body and pretty-print JSON bodies with jq.
-- ponytail: only the last header block is kept apart (redirects/100-continue stay inline)
local function format_http(out)
  out = out:gsub("\r", "")
  local head, body = out:match "^(.-\n)\n(.*)$"
  if not head then
    return out
  end
  if head:lower():find "content%-type:[^\n]*json" and vim.fn.executable "jq" == 1 then
    local r = vim.system({ "jq", "." }, { stdin = body }):wait()
    if r.code == 0 then
      body = r.stdout
    end
  end
  return head .. "\n" .. body
end

function M.send()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local okp, req, err = pcall(M.parse, lines, vim.api.nvim_win_get_cursor(0)[1])
  if not okp then
    req, err = nil, req
  end
  if not req then
    return vim.notify("gooseman: " .. err, vim.log.levels.WARN)
  end
  local ok, cmd, stdin = pcall(M.command, req)
  if not ok then
    return vim.notify("gooseman: " .. cmd, vim.log.levels.WARN)
  end
  if vim.fn.executable(cmd[1]) == 0 then
    return vim.notify("gooseman: " .. cmd[1] .. " not installed", vim.log.levels.ERROR)
  end

  if req.method == "WS" then
    vim.cmd "botright split"
    local job = vim.fn.jobstart(cmd, { term = true })
    if stdin then
      vim.fn.chansend(job, stdin .. "\n")
    end
    return vim.cmd "startinsert"
  end

  local title = ("%s %s %s"):format(req.method, req.url, req.target or "")
  show { title .. "  …" }
  local start = vim.uv.hrtime()
  vim.system(cmd, { stdin = stdin, text = true }, function(r)
    vim.schedule(function()
      local ms = math.floor((vim.uv.hrtime() - start) / 1e6)
      local out = r.stdout .. (r.stderr ~= "" and ("\n" .. r.stderr) or "")
      if req.method ~= "GRPC" then
        out = format_http(out)
      end
      show(vim.list_extend({ ("%s  (%dms, exit %d)"):format(title, ms, r.code), "" }, vim.split(out, "\n")))
    end)
  end)
end

return M
