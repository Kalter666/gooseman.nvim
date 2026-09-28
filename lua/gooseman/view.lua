-- The response window: status + checks, folded headers, highlighted JSON body.
-- Keys: q close · yr copy {{name.body.path}} of the value under the cursor
--       R raw/pretty · o open a binary body in the system viewer · :Honk jq <filter>
-- Also :Honk save [file] · :Honk history · :Honk diff

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace "gooseman_view"
local buf

--- What's on screen: {res, source = {bufnr, req_text}, raw, filter, body_first, json}
M.state = nil

local TEXTY = { "json", "text/", "xml", "javascript", "html", "form", "graphql", "yaml", "csv" }
local EXT = {
  ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/gif"] = "gif", ["image/webp"] = "webp",
  ["application/pdf"] = "pdf", ["application/zip"] = "zip", ["audio/mpeg"] = "mp3", ["video/mp4"] = "mp4",
  ["application/json"] = "json", ["text/html"] = "html", ["text/plain"] = "txt", ["application/xml"] = "xml",
  ["text/csv"] = "csv",
}

local function is_binary(ct, body)
  if body:find "%z" then
    return true
  end
  ct = (ct or ""):lower()
  for _, t in ipairs(TEXTY) do
    if ct:find(t, 1, true) then
      return false
    end
  end
  return ct:match "^image/" or ct:match "^audio/" or ct:match "^video/" or ct:find "pdf" or ct:find "octet%-stream" or ct:find "zip"
end

--- The response body, byte-exact (headers stripped for HTTP).
function M.body(res)
  if res.resp.status == 0 then -- grpcurl / websocat: stdout is the body
    return res.r.stdout
  end
  local _, body = require("gooseman").split_http(res.r.stdout)
  return body
end

local function content_type(res)
  return (res.resp.headers["content-type"] or ""):match "^[^;%s]+" or ""
end

local function size(n)
  return n >= 1048576 and ("%.1f MB"):format(n / 1048576) or n >= 1024 and ("%.1f KB"):format(n / 1024) or (n .. " B")
end

local function ensure()
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, "gooseman://response")
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "gooseman" -- for user autocmds; highlighting is done here
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, desc = "gooseman: " .. desc, nowait = true })
    end
    map("q", "<cmd>close<cr>", "close")
    map("yr", function() M.copy_ref() end, "copy {{ref}} of the value under the cursor")
    map("R", function() M.toggle_raw() end, "raw / pretty")
    map("o", function() M.open_binary() end, "open binary body")
  end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    local cur = api.nvim_get_current_win()
    vim.cmd "botright vsplit"
    api.nvim_win_set_buf(0, buf)
    win = api.nvim_get_current_win()
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].wrap = false
    api.nvim_set_current_win(cur)
  end
  return buf, win
end

local function paint(lines, hls, fold)
  local b, win = ensure()
  api.nvim_buf_clear_namespace(b, ns, 0, -1)
  api.nvim_buf_set_lines(b, 0, -1, false, lines)
  for _, h in ipairs(hls) do
    pcall(api.nvim_buf_set_extmark, b, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  api.nvim_win_call(win, function()
    vim.cmd "silent! normal! zE"
    if fold then
      vim.cmd(("%d,%dfold"):format(fold[1], fold[2])) -- created closed
    end
  end)
end

--- Plain text: progress, reports, errors.
function M.show(lines)
  M.state = nil
  paint(lines, {})
end

-- ponytail: line-based JSON colouring of jq's pretty output (one value per line); a treesitter
-- pass would handle minified bodies too, but needs the json parser installed
local function json_hl(hls, lines, first)
  for i = first, #lines do
    local l, row, from = lines[i], i - 1, 1
    local ks, ke = l:find '^%s*"[^"]*"%s*:'
    if ks then
      local q1 = l:find '"'
      hls[#hls + 1] = { row, q1 - 1, l:find('"%s*:', q1 + 1), "@property" }
      from = ke + 1
    end
    local s = l:find('"', from)
    if s then
      hls[#hls + 1] = { row, s - 1, l:match '.*()"', "@string" }
    else
      for pat, group in pairs { ["%-?%d[%d%.eE%+%-]*"] = "@number", ["true"] = "@boolean", ["false"] = "@boolean", ["null"] = "@constant.builtin" } do
        local a, e = l:find(pat, from)
        if a then
          hls[#hls + 1] = { row, a - 1, e, group }
        end
      end
    end
  end
end

local function draw()
  local st, g = M.state, require "gooseman"
  local res = st.res
  local lines, hls = {}, {}
  local function add(l, group)
    lines[#lines + 1] = l
    if group then
      hls[#hls + 1] = { #lines - 1, 0, #l, group }
    end
  end

  local ok = true
  for _, c in ipairs(res.checks) do
    ok = ok and c.ok
  end
  add(("%s  (%dms, exit %d%s%s)"):format(
    vim.trim(("%s %s %s"):format(res.req.method, res.req.url, res.req.target or "")),
    res.ms, res.r.code,
    res.retried and (", retried after refreshing " .. table.concat(res.retried, ", ")) or "",
    st.filter and (", jq " .. st.filter) or ""
  ), ok and "DiagnosticOk" or "DiagnosticError")
  local t = res.timing
  if t then
    add(("  dns %d · connect %d%s · server %d · download %d  = %d ms"):format(
      t.dns, t.connect, t.tls and (" · tls " .. t.tls) or "", t.server, t.download, t.total), "Comment")
  end
  for _, c in ipairs(res.checks) do
    if c.text ~= "succeeds" then -- the default check is implied by the status line
      add((c.ok and "  ✓ " or "  ✗ ") .. c.text .. (c.ok and "" or ("   (got " .. tostring(c.got) .. ")")),
        c.ok and "DiagnosticOk" or "DiagnosticError")
    end
  end
  add ""

  if st.raw then
    for l in vim.gsplit(((res.r.stdout .. res.r.stderr):gsub("\r", "")), "\n") do
      add(l)
    end
    return paint(lines, hls)
  end

  local heads, body = {}, res.r.stdout
  if res.req.method ~= "GRPC" then
    heads, body = g.split_http(res.r.stdout)
  end
  local fold_from = #lines + 1
  for _, h in ipairs(heads) do
    for l in vim.gsplit(h, "\n", { trimempty = true }) do
      local k = l:match "^([^:]+):"
      add(l, l:match "^HTTP/" and "Title" or nil)
      if k then
        hls[#hls + 1] = { #lines - 1, 0, #k, "@property" }
      end
    end
  end
  local fold = #lines > fold_from and { fold_from, #lines } or nil
  if #heads > 0 then
    add ""
  end

  st.body_first, st.json = #lines + 1, false
  local ct = res.resp.headers["content-type"]
  if body ~= "" and is_binary(ct, body) then
    add(("<binary body: %s, %s>  press o to open it"):format(size(#body), ct or "unknown type"), "Comment")
  elseif body ~= "" then
    body = body:gsub("\r", "")
    local json = res.req.method == "GRPC" or (ct or ""):find "json" or type(res.resp.body) == "table"
    local pretty = false
    if json and vim.fn.executable "jq" == 1 then
      local r = vim.system({ "jq", st.filter or "." }, { stdin = body, text = true }):wait()
      if r.code == 0 then
        body, pretty = r.stdout, true
      elseif st.filter then
        body, json = "jq: " .. r.stderr, false
      end
    end
    for l in vim.gsplit((body:gsub("\n$", "")), "\n") do
      add(l)
    end
    if json and pretty then -- unformatted body: paths and colours would be wrong
      st.json = not st.filter
      json_hl(hls, lines, st.body_first)
    end
  end
  if res.r.stderr ~= "" then
    add ""
    for l in vim.gsplit(vim.trim(res.r.stderr), "\n") do
      add(l, "DiagnosticWarn")
    end
  end
  paint(lines, hls, fold)
end

--- Show a finished request. `source` = {bufnr, req_text} of the .http block it came from.
function M.render(res, source)
  M.state = { res = res, source = source }
  draw()
end

function M.toggle_raw()
  if M.state then
    M.state.raw = not M.state.raw
    draw()
  end
end

function M.jq(filter)
  if not M.state then
    return vim.notify("gooseman: no response to filter", vim.log.levels.WARN)
  end
  M.state.filter = (filter and filter ~= "") and filter or nil
  draw()
end

function M.open_binary()
  local st = M.state
  if not st then
    return
  end
  local path = vim.fn.tempname() .. "." .. (EXT[content_type(st.res)] or "bin")
  local f = assert(io.open(path, "wb"))
  f:write(M.body(st.res))
  f:close()
  vim.ui.open(path)
  vim.notify("gooseman: saved " .. path)
end

--- Write the response body (exact bytes) to `file`; no file = ask, suggesting a name from the URL.
function M.save(file)
  local st = M.state
  if not st then
    return vim.notify("gooseman: no response to save", vim.log.levels.WARN)
  end
  local function write(p)
    p = vim.fn.expand(p)
    local f, err = io.open(p, "wb")
    if not f then
      return vim.notify("gooseman: " .. err, vim.log.levels.ERROR)
    end
    f:write(M.body(st.res))
    f:close()
    vim.notify("gooseman: saved " .. p)
  end
  if file and file ~= "" then
    return write(file)
  end
  local last = (st.res.req.url:match "^[^?#]*" or ""):match "([^/]+)$" or ""
  local default = last:match "%.%w+$" and last or ("response." .. (EXT[content_type(st.res)] or "txt"))
  vim.ui.input({ prompt = "save body to: ", default = default, completion = "file" }, function(p)
    if p and p ~= "" then
      write(p)
    end
  end)
end

local function source_of(e)
  local nr = vim.fn.bufnr(e.path)
  return { bufnr = nr ~= -1 and nr or nil, req_text = e.req_text }
end

--- Pick an earlier response (any request) and show it.
function M.history()
  local h = require("gooseman").history
  if #h == 0 then
    return vim.notify("gooseman: nothing sent yet", vim.log.levels.WARN)
  end
  vim.ui.select(h, {
    prompt = "honk: history",
    format_item = function(e)
      local res = e.res
      local ok = true
      for _, c in ipairs(res.checks) do
        ok = ok and c.ok
      end
      local status = res.resp.status > 0 and res.resp.status or ("exit " .. res.r.code)
      return ("%s  %s %-8s %6dms  %s"):format(os.date("%H:%M:%S", e.at), ok and "✓" or "✗", status, res.ms, e.req_text)
    end,
  }, function(e)
    if e then
      M.render(e.res, source_of(e))
    end
  end)
end

-- status + body, JSON sorted and pretty (jq -S) so diffs show real changes
local function diff_text(res)
  local body = M.body(res):gsub("\r", "")
  if type(res.resp.body) == "table" and vim.fn.executable "jq" == 1 then
    local r = vim.system({ "jq", "-S", "." }, { stdin = body, text = true }):wait()
    body = r.code == 0 and r.stdout or body
  end
  local status = res.resp.status > 0 and ("status " .. res.resp.status) or ("exit " .. res.r.code)
  return vim.split(status .. "\n\n" .. body:gsub("\n$", ""), "\n")
end

--- Diff the response on screen against the previous response of the same request, in a new tab.
function M.diff()
  local st = M.state
  if not st then
    return vim.notify("gooseman: no response to diff", vim.log.levels.WARN)
  end
  local h, cur = require("gooseman").history, nil
  for _, e in ipairs(h) do
    if cur and e.path == cur.path and e.req_text == cur.req_text then
      vim.cmd "tabnew"
      for i, x in ipairs { e, cur } do
        if i == 2 then
          vim.cmd "rightbelow vnew"
        end
        local b = api.nvim_get_current_buf()
        vim.bo[b].buftype, vim.bo[b].bufhidden = "nofile", "wipe"
        api.nvim_buf_set_lines(b, 0, -1, false, diff_text(x.res))
        vim.bo[b].modifiable = false
        vim.wo.winbar = ("%s  %s"):format(os.date("%H:%M:%S", x.at), x.req_text)
        vim.cmd "diffthis"
      end
      return
    end
    cur = cur or (e.res == st.res and e) or nil
  end
  vim.notify("gooseman: no earlier response of this request", vim.log.levels.WARN)
end

--- Dotted path of the JSON value on `row`, from jq's pretty output starting at `first`.
function M.json_path(lines, first, row)
  local stack = {}
  for i = first, row do
    local t = vim.trim(lines[i] or "")
    local closing = t:match "^[%]}]"
    local seg
    if t ~= "" and not closing then
      local top = stack[#stack]
      if top and top.arr then
        top.idx = top.idx + 1
        seg = tostring(top.idx)
      else
        seg = t:match '^"(.-)"%s*:'
      end
    end
    if i == row then
      local segs = {}
      for _, f in ipairs(stack) do
        segs[#segs + 1] = f.seg
      end
      if not closing then
        segs[#segs + 1] = seg
      end
      for _, s in ipairs(segs) do
        if not s:match "^[%w_%-]+$" then
          return nil -- keys with dots/spaces can't be written as a {{ref}} path
        end
      end
      return table.concat(segs, ".")
    end
    if closing then
      table.remove(stack)
    else
      local opener = t:match "[%[{]$"
      if opener then
        stack[#stack + 1] = { arr = opener == "[", seg = seg, idx = -1 }
      end
    end
  end
end

--- Copy {{name.body.path}} for the value under the cursor; names the request first if needed.
function M.copy_ref()
  local st = M.state
  if not (st and st.json) then
    return vim.notify("gooseman: no JSON body here" .. (st and st.filter and " (clear the jq filter)" or ""), vim.log.levels.WARN)
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local row = api.nvim_win_get_cursor(0)[1]
  local path = row >= st.body_first and M.json_path(lines, st.body_first, row)
  if not path then
    return vim.notify("gooseman: put the cursor on a body value (plain keys only)", vim.log.levels.WARN)
  end
  local g = require "gooseman"
  local function copy(name)
    local ref = "{{" .. name .. ".body" .. (path ~= "" and ("." .. path) or "") .. "}}"
    vim.fn.setreg("+", ref)
    vim.fn.setreg('"', ref)
    vim.notify("gooseman: copied " .. ref)
  end
  if st.res.req.name then
    return copy(st.res.req.name)
  end
  -- unnamed request: name it in its .http file so the ref resolves
  local src = st.source
  if not (src and api.nvim_buf_is_valid(src.bufnr)) then
    return vim.notify("gooseman: name the request (# @name) to reference it", vim.log.levels.WARN)
  end
  local blines = api.nvim_buf_get_lines(src.bufnr, 0, -1, false)
  local b = vim.iter(g.scan(blines).blocks):find(function(x)
    return x.req and x.req.text == src.req_text
  end)
  if not b then
    return vim.notify("gooseman: can't find the request in its file anymore", vim.log.levels.WARN)
  end
  local default = (b.title ~= "" and b.title or "req"):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  vim.ui.input({ prompt = "name this request: ", default = default }, function(name)
    if not (name and name:match "^[%w_%-]+$") then
      return
    end
    local at = b.sep or (b.first - 1)
    api.nvim_buf_set_lines(src.bufnr, at, at, false, { "# @name " .. name })
    st.res.req.name = name
    g.responses[name] = st.res.resp -- usable right away, no re-send needed
    copy(name)
  end)
end

return M
