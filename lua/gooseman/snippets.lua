-- Snippets served by the built-in LSP (any LSP-aware completion plugin expands them).
-- Bodies are written with plain .http braces ({{var}}, JSON {}); `lsp_body` escapes the
-- literal ones so only ${n:...} placeholders stay special.
-- `header` = a file-wide `# @header` the snippet needs; the LSP adds it at the top of the file.

local M = {}

local function block(method, ct, body)
  return table.concat({
    "### ${1:" .. method:lower() .. " something}",
    method .. " {{host}}/${2:path}",
    ct and ("Content-Type: " .. ct) or "Accept: application/json",
    body and "" or nil,
    body,
  }, "\n")
end

local JSON_BODY = '{\n  "${3:key}": "${4:value}"\n}'

M.list = {
  -- requests
  { prefix = "get", desc = "GET request", body = block("GET") .. "\n$0" },
  { prefix = "post-json", desc = "POST with a JSON body", body = block("POST", "application/json", JSON_BODY) },
  { prefix = "put-json", desc = "PUT with a JSON body", body = block("PUT", "application/json", JSON_BODY) },
  { prefix = "patch-json", desc = "PATCH with a JSON body", body = block("PATCH", "application/json", JSON_BODY) },
  { prefix = "post-form", desc = "POST a urlencoded form", body = block("POST", "application/x-www-form-urlencoded", "${3:key}=${4:value}") },
  { prefix = "delete", desc = "DELETE request", body = block("DELETE") .. "\n$0" },
  {
    prefix = "graphql",
    desc = "GraphQL query over POST",
    body = [[### ${1:graphql query}
POST {{host}}/${2:graphql}
Content-Type: application/json

{
  "query": "${3:query { viewer { id } }}",
  "variables": {$4}
}]],
  },
  {
    prefix = "upload",
    desc = "multipart file upload",
    body = [[### ${1:upload a file}
# @args -F ${2:file}=@${3:./file.txt}
POST {{host}}/${4:upload}]],
  },
  {
    prefix = "grpc",
    desc = "gRPC call (method names complete from server reflection)",
    body = [[### ${1:grpc call}
GRPC ${2:grpc://localhost:50051} ${3:pkg.Service/Method}

{$0}]],
  },
  { prefix = "grpc-list", desc = "list gRPC services", body = "### ${1:list services}\nGRPC ${2:grpc://localhost:50051}" },
  {
    prefix = "ws",
    desc = "WebSocket connection",
    body = "### ${1:websocket}\nWS ${2:ws://localhost:9000}/${3:path}\n\n${4:hello}",
  },

  -- auth
  {
    prefix = "auth-basic",
    desc = "Basic auth (curl encodes it)",
    body = "### ${1:basic auth}\n# @args -u {{${2:user}}}:{{${3:password}}}\nGET {{host}}/${4:path}",
  },
  {
    prefix = "auth-bearer",
    desc = "Bearer token header",
    body = "### ${1:bearer auth}\nGET {{host}}/${2:path}\nAuthorization: Bearer {{${3:token}}}",
  },
  {
    prefix = "auth-apikey",
    desc = "API key in a header",
    body = "### ${1:api key}\nGET {{host}}/${2:path}\n${3:X-API-Key}: {{${4:api_key}}}",
  },
  {
    prefix = "auth-apikey-query",
    desc = "API key in the query string",
    body = "### ${1:api key}\nGET {{host}}/${2:path}?${3:api_key}={{${4:api_key}}}",
  },
  {
    prefix = "auth-login",
    desc = "named login + file-wide Bearer header from its token",
    header = "Authorization: Bearer {{login.body.token}}",
    body = [[### login
# @name login
POST {{host}}/${1:login}
Content-Type: application/json

{"user": "{{${2:user}}}", "password": "{{${3:password}}}"}]],
  },
  {
    prefix = "auth-oauth-cc",
    desc = "OAuth2 client credentials + file-wide Bearer header",
    header = "Authorization: Bearer {{oauth.body.access_token}}",
    body = [[### oauth token
# @name oauth
POST ${1:{{host}}/oauth/token}
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials&client_id={{${2:client_id}}}&client_secret={{${3:client_secret}}}${4:&scope=}]],
  },
  {
    prefix = "auth-oauth-password",
    desc = "OAuth2 password grant + file-wide Bearer header",
    header = "Authorization: Bearer {{oauth.body.access_token}}",
    body = [[### oauth token
# @name oauth
POST ${1:{{host}}/oauth/token}
Content-Type: application/x-www-form-urlencoded

grant_type=password&username={{${2:user}}}&password={{${3:password}}}&client_id={{${4:client_id}}}]],
  },
  {
    prefix = "auth-cookie",
    desc = "log in with a cookie jar, then reuse the session",
    body = [[### log in (stores the session cookie)
# @args -c ${1:/tmp/gooseman.cookies}
POST {{host}}/${2:login}
Content-Type: application/json

{"user": "{{${3:user}}}", "password": "{{${4:password}}}"}

### use the session
# @args -b $1
GET {{host}}/${5:me}]],
  },
  {
    prefix = "auth-mtls",
    desc = "client certificate (mTLS)",
    body = "### ${1:mtls}\n# @args --cert ${2:./client.crt} --key ${3:./client.key} --cacert ${4:./ca.crt}\nGET ${5:https://api.example.com}/${6:path}",
  },
  {
    prefix = "auth-digest",
    desc = "HTTP Digest auth",
    body = "### ${1:digest auth}\n# @args --digest -u {{${2:user}}}:{{${3:password}}}\nGET {{host}}/${4:path}",
  },
  {
    prefix = "auth-aws",
    desc = "AWS SigV4 signing (keys from env vars)",
    body = [[### ${1:aws request}
# @args --aws-sigv4 aws:amz:${2:us-east-1}:${3:execute-api} -u {{AWS_ACCESS_KEY_ID}}:{{AWS_SECRET_ACCESS_KEY}}
GET ${4:https://example.execute-api.us-east-1.amazonaws.com}/${5:path}
X-Amz-Security-Token: {{AWS_SESSION_TOKEN}}]],
  },

  -- tests
  { prefix = "expect-ok", desc = "assert status + a body field", body = "# @expect status == ${1:200}\n# @expect body.${2:id} exists" },
  {
    prefix = "expect-json",
    desc = "assert a JSON response",
    body = "# @expect headers.content-type contains json\n# @expect body.${1:id} ${2:==} ${3:value}",
  },

  -- files
  {
    prefix = "http-file",
    desc = "new file: host, login and a first request",
    body = [[@host = ${1:http://localhost:8080}
# @header Authorization: Bearer {{login.body.token}}

### login
# @name login
POST {{host}}/${2:login}
Content-Type: application/json

{"user": "{{${3:user}}}", "password": "{{${4:password}}}"}

### ${5:first request}
GET {{host}}/${6:path}
$0]],
  },
}

--- Escape literal braces: `{`/`}` that are not part of `${n:...}` get a backslash on `}`.
function M.lsp_body(body)
  local out, stack, i = {}, {}, 1
  while i <= #body do
    local c = body:sub(i, i)
    if c == "$" and body:sub(i + 1, i + 1) == "{" then
      stack[#stack + 1] = "p"
      out[#out + 1] = "${"
      i = i + 1
    elseif c == "{" then
      stack[#stack + 1] = "b"
      out[#out + 1] = c
    elseif c == "}" then
      local top = table.remove(stack)
      out[#out + 1] = top == "p" and "}" or "\\}"
    else
      out[#out + 1] = c
    end
    i = i + 1
  end
  return table.concat(out)
end

--- Snippet text with placeholders filled with their defaults (completion docs).
function M.preview(body)
  local ok, ast = pcall(require("vim.lsp._snippet_grammar").parse, M.lsp_body(body))
  return ok and tostring(ast) or body
end

return M
