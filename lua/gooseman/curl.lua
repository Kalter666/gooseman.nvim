-- curl <-> .http
--   export: the request under the cursor as a shell command (curl/grpcurl/websocat)
--   import: a curl command (e.g. browser devtools "Copy as cURL") as a .http block

local M = {}

local function quote(w)
  if w:match "^[%w%-_./:=@,+%%]+$" then
    return w
  end
  return "'" .. w:gsub("'", [['\'']]) .. "'"
end

--- argv + stdin -> one copy-pasteable shell line.
function M.export(cmd, stdin)
  local argv, piped = {}, stdin
  for i, a in ipairs(cmd) do
    if cmd[1] == "curl" and (a == "-sS" or a == "-i") then
      -- noise for a shared command
    elseif stdin and cmd[1] == "curl" and a == "@-" and cmd[i - 1] == "--data-binary" then
      argv[#argv + 1], piped = stdin, nil
    elseif stdin and cmd[1] == "grpcurl" and a == "@" and cmd[i - 1] == "-d" then
      argv[#argv + 1], piped = stdin, nil
    else
      argv[#argv + 1] = a
    end
  end
  if cmd[1] == "curl" and argv[2] == "-X" and argv[3] == "GET" then
    table.remove(argv, 2)
    table.remove(argv, 2)
  end
  local line = table.concat(vim.tbl_map(quote, argv), " ")
  return piped and ("printf '%s\\n' " .. quote(piped) .. " | " .. line) or line
end

--- Split a shell command into words: '...', "...", $'...', backslashes, line continuations.
function M.words(s)
  s = s:gsub("\\\r?\n", " ")
  local words, cur, q, i = {}, nil, nil, 1
  local ESC = { n = "\n", t = "\t", r = "\r" }
  while i <= #s do
    local c = s:sub(i, i)
    if q == "'" then
      if c == "'" then q = nil else cur = cur .. c end
    elseif q == "$'" then
      if c == "'" then
        q = nil
      elseif c == "\\" then
        i = i + 1
        local n = s:sub(i, i)
        cur = cur .. (ESC[n] or n)
      else
        cur = cur .. c
      end
    elseif q == '"' then
      if c == '"' then
        q = nil
      elseif c == "\\" and s:sub(i + 1, i + 1):match '[$`"\\]' then
        i = i + 1
        cur = cur .. s:sub(i, i)
      else
        cur = cur .. c
      end
    elseif c:match "%s" then
      if cur then
        words[#words + 1], cur = cur, nil
      end
    elseif c == "$" and s:sub(i + 1, i + 1) == "'" then
      q, cur, i = "$'", cur or "", i + 1
    elseif c == "'" or c == '"' then
      q, cur = c, cur or ""
    elseif c == "\\" then
      i = i + 1
      cur = (cur or "") .. s:sub(i, i)
    else
      cur = (cur or "") .. c
    end
    i = i + 1
  end
  if cur then
    words[#words + 1] = cur
  end
  return words
end

local DATA = {
  ["-d"] = true, ["--data"] = true, ["--data-raw"] = true, ["--data-binary"] = true,
  ["--data-ascii"] = true, ["--data-urlencode"] = true, ["--json"] = true,
}
local VALUED = { -- passed through to `# @args` with their value
  ["-o"] = true, ["--output"] = true, ["-m"] = true, ["--max-time"] = true, ["--connect-timeout"] = true,
  ["-x"] = true, ["--proxy"] = true, ["-E"] = true, ["--cert"] = true, ["--key"] = true, ["--cacert"] = true,
  ["-e"] = true, ["--referer"] = true, ["-F"] = true, ["--form"] = true, ["-c"] = true, ["--cookie-jar"] = true,
  ["--resolve"] = true, ["--retry"] = true, ["-w"] = true, ["--write-out"] = true,
}
local DROP = { s = true, S = true, i = true, v = true } -- gooseman sets its own output flags
local DROP_LONG = { ["--silent"] = true, ["--show-error"] = true, ["--include"] = true, ["--verbose"] = true }

--- curl command -> .http block lines.
function M.to_http(text)
  local w = M.words(vim.trim(text))
  if w[1] ~= "curl" then
    error("not a curl command", 0)
  end
  local method, url, headers, data, args, json = nil, nil, {}, {}, {}, false
  local function has(name)
    for _, h in ipairs(headers) do
      if h:lower():match("^" .. name:lower():gsub("%-", "%%-") .. ":") then
        return true
      end
    end
  end
  local i = 2
  while i <= #w do
    local a, v = w[i], nil
    local long, eq = a:match "^(%-%-[^=]+)=(.*)$"
    local short, attached = a:match "^(%-[XHdubAoemxEFcw])(.+)$" -- -XPOST, -HAccept:x
    if long then
      a, v = long, eq
    elseif short then
      a, v = short, attached
    end
    local function val()
      if v then
        return v
      end
      i = i + 1
      return w[i] or ""
    end
    if a == "-X" or a == "--request" then
      method = val():upper()
    elseif a == "-H" or a == "--header" then
      headers[#headers + 1] = val()
    elseif DATA[a] then
      local d = val()
      if d:sub(1, 1) == "@" and a ~= "--data-raw" then
        vim.list_extend(args, { a, d }) -- body from a file: let curl read it
      else
        data[#data + 1] = d
      end
      json = json or a == "--json"
    elseif a == "-u" or a == "--user" then
      headers[#headers + 1] = "Authorization: Basic " .. vim.base64.encode(val())
    elseif a == "-b" or a == "--cookie" then
      local c = val()
      if c:find "=" then
        headers[#headers + 1] = "Cookie: " .. c
      else
        vim.list_extend(args, { "-b", c }) -- cookie jar file
      end
    elseif a == "-A" or a == "--user-agent" then
      headers[#headers + 1] = "User-Agent: " .. val()
    elseif a == "--url" then
      url = val()
    elseif VALUED[a] then
      vim.list_extend(args, { a, val() })
    elseif DROP_LONG[a] then
      -- skip
    elseif a:match "^%-%a+$" then -- -sSLk: drop output flags, keep the rest
      local keep = a:sub(2):gsub(".", function(c)
        return DROP[c] and "" or c
      end)
      if keep ~= "" then
        args[#args + 1] = "-" .. keep
      end
    elseif a:match "^%-" then
      args[#args + 1] = a .. (v and ("=" .. v) or "")
    elseif not url then
      url = a
    end
    i = i + 1
  end
  if not url then
    error("curl command has no URL", 0)
  end
  if json then
    if not has "Content-Type" then
      headers[#headers + 1] = "Content-Type: application/json"
    end
    if not has "Accept" then
      headers[#headers + 1] = "Accept: application/json"
    end
  elseif #data > 0 and not has "Content-Type" then
    headers[#headers + 1] = "Content-Type: application/x-www-form-urlencoded" -- what curl -d sends
  end

  local out = { "### imported from curl" }
  if #args > 0 then
    -- ponytail: @args splits on whitespace; values with spaces need a {{var}}
    out[#out + 1] = "# @args " .. table.concat(args, " ")
  end
  out[#out + 1] = ("%s %s"):format(method or (#data > 0 and "POST" or "GET"), url)
  vim.list_extend(out, headers)
  if #data > 0 then
    out[#out + 1] = ""
    vim.list_extend(out, vim.split(table.concat(data, "&"), "\n"))
  end
  return out
end

return M
