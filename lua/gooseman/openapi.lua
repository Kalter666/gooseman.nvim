-- OpenAPI 3 / Swagger 2 spec -> .http blocks. JSON is read natively, YAML through yq.
-- One block per operation: path params become {{vars}}, required query and header params
-- too, and a JSON body is filled from the schema's examples (or a typed skeleton).

local M = {}

local METHODS = { "get", "post", "put", "patch", "delete", "head", "options" }

local function decode(text)
  local ok, spec = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if ok and type(spec) == "table" then
    return spec
  end
  if vim.fn.executable "yq" == 0 then
    error("spec isn't JSON; install yq (mikefarah/yq) to read YAML", 0)
  end
  local r = vim.system({ "yq", "-o", "json", "." }, { stdin = text, text = true }):wait()
  if r.code ~= 0 then
    error("yq: " .. vim.trim(r.stderr), 0)
  end
  return vim.json.decode(r.stdout, { luanil = { object = true, array = true } })
end

--- Load a spec from a file path or http(s) URL.
function M.load(src)
  if src:match "^https?://" then
    local r = vim.system({ "curl", "-sSfL", src }, { text = true }):wait()
    if r.code ~= 0 then
      error("fetching spec: " .. vim.trim(r.stderr), 0)
    end
    return decode(r.stdout)
  end
  local ok, lines = pcall(vim.fn.readfile, vim.fn.expand(src))
  if not ok then
    error("can't read " .. src, 0)
  end
  return decode(table.concat(lines, "\n"))
end

local function resolve(spec, v)
  local seen = 0
  while type(v) == "table" and v["$ref"] and seen < 10 do
    local node = spec
    for part in v["$ref"]:gsub("^#/", ""):gmatch "[^/]+" do
      node = type(node) == "table" and node[part:gsub("~1", "/"):gsub("~0", "~")] or nil
    end
    v, seen = node, seen + 1
  end
  return v
end

-- example value for a schema; depth-limited so recursive schemas terminate
local function example(spec, schema, depth)
  schema = resolve(spec, schema)
  if type(schema) ~= "table" or depth > 5 then
    return nil
  end
  if schema.example ~= nil then
    return schema.example
  end
  if schema.default ~= nil then
    return schema.default
  end
  if schema.enum then
    return schema.enum[1]
  end
  if schema.allOf then
    local out = vim.empty_dict()
    for _, s in ipairs(schema.allOf) do
      local part = example(spec, s, depth + 1)
      if type(part) == "table" then
        out = vim.tbl_extend("force", out, part)
      end
    end
    return out
  end
  local variants = schema.oneOf or schema.anyOf
  if variants then
    return example(spec, variants[1], depth + 1)
  end
  local t = type(schema.type) == "table" and schema.type[1] or schema.type
  if t == "object" or schema.properties then
    local out = vim.empty_dict()
    for k, p in pairs(schema.properties or {}) do
      out[k] = example(spec, p, depth + 1)
    end
    return out
  elseif t == "array" then
    return { example(spec, schema.items, depth + 1) }
  elseif t == "integer" or t == "number" then
    return 0
  elseif t == "boolean" then
    return false
  elseif t == "string" then
    return schema.format == "date-time" and "2024-01-01T00:00:00Z" or schema.format == "date" and "2024-01-01"
      or "string"
  end
end

local function pretty(v)
  local json = vim.json.encode(v)
  if vim.fn.executable "jq" == 1 then
    local r = vim.system({ "jq", "." }, { stdin = json, text = true }):wait()
    if r.code == 0 then
      return vim.split(vim.trim(r.stdout), "\n")
    end
  end
  return { json }
end

local function base_url(spec)
  if spec.servers and spec.servers[1] then
    return (spec.servers[1].url:gsub("/$", ""))
  end
  if spec.host then -- swagger 2
    return ((spec.schemes or { "https" })[1] .. "://" .. spec.host .. (spec.basePath or "")):gsub("/$", "")
  end
  return "http://localhost:8080"
end

--- Spec table -> lines of a .http file.
function M.to_http(spec)
  local out = { "# generated from " .. ((spec.info or {}).title or "an OpenAPI spec"), "@host = " .. base_url(spec) }
  local paths = vim.tbl_keys(spec.paths or {})
  table.sort(paths)
  for _, path in ipairs(paths) do
    local item = resolve(spec, spec.paths[path])
    for _, m in ipairs(METHODS) do
      local op = item[m]
      if op then
        local params, query, headers, body = {}, {}, {}, nil
        vim.list_extend(params, item.parameters or {})
        vim.list_extend(params, op.parameters or {})
        for _, p in ipairs(params) do
          p = resolve(spec, p)
          if p["in"] == "query" and p.required then
            query[#query + 1] = p.name .. "={{" .. p.name .. "}}"
          elseif p["in"] == "header" and p.required then
            headers[#headers + 1] = p.name .. ": {{" .. p.name .. "}}"
          elseif p["in"] == "body" then -- swagger 2
            body = example(spec, p.schema, 0)
          end
        end
        local rb = resolve(spec, op.requestBody)
        local media = rb and rb.content and (rb.content["application/json"] or select(2, next(rb.content)))
        if media then
          body = media.example
          if body == nil and media.examples then
            local _, first = next(media.examples)
            body = resolve(spec, first).value
          end
          if body == nil then
            body = example(spec, media.schema, 0)
          end
        end
        out[#out + 1] = ""
        out[#out + 1] = "### " .. (op.summary or op.operationId or (m:upper() .. " " .. path))
        local url = "{{host}}" .. path:gsub("{([%w_%-]+)}", "{{%1}}")
        out[#out + 1] = m:upper() .. " " .. url .. (#query > 0 and ("?" .. table.concat(query, "&")) or "")
        vim.list_extend(out, headers)
        if body ~= nil then
          out[#out + 1] = "Content-Type: application/json"
          out[#out + 1] = ""
          vim.list_extend(out, pretty(body))
        end
      end
    end
  end
  return out
end

--- :Honk openapi <file|url> — the generated requests in a new .http buffer.
function M.import(src)
  if not src or src == "" then
    return vim.notify("gooseman: :Honk openapi <file or url>", vim.log.levels.WARN)
  end
  local ok, lines = pcall(function()
    return M.to_http(M.load(src))
  end)
  if not ok then
    return vim.notify("gooseman: " .. lines, vim.log.levels.ERROR)
  end
  vim.cmd "enew"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.filetype = "http"
end

return M
