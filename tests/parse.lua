-- run: nvim -l tests/parse.lua
vim.opt.rtp:prepend "."
local p = require "gooseman"

local lines = vim.split(
  [[
@host = http://localhost:8080
@token = abc

### create user
POST {{host}}/users HTTP/1.1
Authorization: Bearer {{token}}
Content-Type: application/json

{"name": "{{GOOSEMAN_TEST_ENV}}"}

### grpc call
# comment
GRPC grpc://localhost:50051 helloworld.Greeter/SayHello

{"name": "x"}

### grpc list
GRPC localhost:50051

### ws
WS ws://localhost:9000/chat
X-Id: 1

hello
]],
  "\n"
)

vim.env.GOOSEMAN_TEST_ENV = "bob"

local r = assert(p.parse(lines, 5))
assert(r.method == "POST" and r.url == "http://localhost:8080/users", r.url)
assert(r.headers[1] == "Authorization: Bearer abc")
assert(r.body == '{"name": "bob"}', r.body)
local cmd, stdin = p.command(r)
assert(vim.deep_equal(cmd, {
  "curl", "-sS", "-i", "-X", "POST", "http://localhost:8080/users",
  "-H", "Authorization: Bearer abc", "-H", "Content-Type: application/json",
  "--data-binary", "@-",
}))
assert(stdin == r.body)

r = assert(p.parse(lines, 14))
cmd, stdin = p.command(r)
assert(vim.deep_equal(cmd, { "grpcurl", "-plaintext", "-d", "@", "localhost:50051", "helloworld.Greeter/SayHello" }))
assert(stdin == '{"name": "x"}')

r = assert(p.parse(lines, 19))
cmd, stdin = p.command(r)
assert(vim.deep_equal(cmd, { "grpcurl", "localhost:50051", "list" }) and stdin == nil)

r = assert(p.parse(lines, 23))
cmd, stdin = p.command(r)
assert(vim.deep_equal(cmd, { "websocat", "ws://localhost:9000/chat", "-H", "X-Id: 1" }) and stdin == "hello")

assert(not p.parse({ "### empty", "# nothing" }, 1))

-- trailing comments before the next ### are not body; shell vars expand; @args prepend
lines = {
  "@who = $(printf goose)",
  "### x",
  "# @args -u a:b",
  "POST http://h/{{who}}",
  "",
  "k=v",
  "",
  "# ── next section ──",
  "### y",
}
r = assert(p.parse(lines, 4))
assert(r.body == "k=v", r.body)
assert(r.url == "http://h/goose", r.url)
cmd = p.command(r)
assert(cmd[1] == "curl" and cmd[2] == "-u" and cmd[3] == "a:b", vim.inspect(cmd))

-- named responses: file-wide header from a cached login; login itself never uses its own token
p.responses = { login = p.to_response("POST", 'HTTP/1.1 200 OK\r\nX-Sid: 7\r\n\r\n{"token":"t","items":[{"id":5}]}') }
lines = {
  "# @header Authorization: Bearer {{login.body.token}}",
  "### login",
  "# @name login",
  "POST http://h/login",
  "### use",
  "GET http://h/x/{{login.body.items.0.id}}?sid={{login.headers.x-sid}}&s={{login.status}}",
}
r = assert(p.parse(lines, 4))
assert(#r.headers == 0, vim.inspect(r.headers))
r = assert(p.parse(lines, 6))
assert(r.headers[1] == "Authorization: Bearer t", vim.inspect(r.headers))
assert(r.url == "http://h/x/5?sid=7&s=200", r.url)
assert(not pcall(p.parse, { "### a", "# @name a", "GET http://h/{{a.body.x}}" }, 3), "self reference must fail")

-- @expect
local expect = require "gooseman.expect"
assert(vim.deep_equal(expect.parse "status == 200", { path = "status", op = "==", value = "200" }))
assert(expect.parse("body.x exists").op == "exists")
assert(expect.parse("body.n <= 3").op == "<=")
assert(select(2, expect.parse "status ~= 1"):find "unknown operator")
assert(select(2, expect.parse "body.x exists 1"):find "takes no value")
assert(select(2, expect.parse "status =="):find "needs a value")
local resp = p.to_response("GET", 'HTTP/1.1 201 Created\r\nX-Id: a1\r\n\r\n{"n":5,"tags":["a","b"],"z":null}')
local id = function(v) return v end
local checks = expect.check({
  { text = "status == 201" }, { text = "status < 300" }, { text = "body.n > 10" },
  { text = "body.tags.1 == b" }, { text = "body.z !exists" }, { text = "headers.x-id matches ^a%d$" },
  { text = "body.tags contains \"a\"" }, { text = "body.missing exists" },
}, resp, 0, p.field, id)
local oks = vim.tbl_map(function(c) return c.ok end, checks)
assert(vim.deep_equal(oks, { true, true, false, true, true, true, true, false }), vim.inspect(checks))
assert(expect.check({}, resp, 0, p.field, id)[1].ok)
assert(not expect.check({}, p.to_response("GET", "HTTP/1.1 500 X\r\n\r\n"), 0, p.field, id)[1].ok)

-- curl import / export
local curl = require "gooseman.curl"
assert(vim.deep_equal(curl.words [[curl -H 'A: b c' "x\"y" $'l1\nl2' a\ b \
  --x]], { "curl", "-H", "A: b c", 'x"y', "l1\nl2", "a b", "--x" }))
local block = curl.to_http [[curl 'https://api.x/v1/geese?id=1' -XPOST -H 'Accept: application/json' -u gooseman:secret --data-raw '{"a":1}' -sSL --compressed -b 'sid=1' --max-time 5]]
assert(vim.deep_equal(block, {
  "### imported from curl",
  "# @args -L --compressed --max-time 5",
  "POST https://api.x/v1/geese?id=1",
  "Accept: application/json",
  "Authorization: Basic " .. vim.base64.encode "gooseman:secret",
  "Cookie: sid=1",
  "Content-Type: application/x-www-form-urlencoded",
  "",
  '{"a":1}',
}), vim.inspect(block))
block = curl.to_http "curl --json '{\"a\":1}' https://x/y"
assert(block[2] == "POST https://x/y" and block[3] == "Content-Type: application/json", vim.inspect(block))
assert(curl.to_http("curl https://x")[2] == "GET https://x")
assert(not pcall(curl.to_http, "wget https://x"))
-- round trip: .http -> curl -> .http
r = assert(p.parse({ "POST http://h/a", "X-A: it's", "", "{\"k\": 1}" }, 1))
local line = curl.export(p.command(r))
assert(line == [[curl -X POST http://h/a -H 'X-A: it'\''s' --data-binary '{"k": 1}']], line)
local back = curl.to_http(line)
assert(back[2] == "POST http://h/a" and back[3] == "X-A: it's" and back[#back] == '{"k": 1}', vim.inspect(back))
assert(curl.export(p.command(assert(p.parse({ "GET http://h/x" }, 1)))) == "curl http://h/x")
local ws = curl.export(p.command(assert(p.parse({ "WS ws://h", "", "hi there" }, 1))))
assert(ws == "printf '%s\\n' 'hi there' | websocat ws://h", ws)

-- environments: $shared < active env < private file; file @vars win over all
local env = require "gooseman.env"
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/sub", "p")
vim.fn.writefile({ '{"$shared": {"a": "shared", "b": "shared"}, "dev": {"b": "dev", "c": "{{a}}-x"}}' }, dir .. "/gooseman.json")
vim.fn.writefile({ '{"dev": {"secret": "s3"}}' }, dir .. "/gooseman.private.json")
local path = dir .. "/sub/api.http"
assert(vim.deep_equal(env.names(path), { "dev" }))
env.active = "dev"
lines = { "@b = file", "GET http://h/{{a}}/{{b}}/{{c}}/{{secret}}" }
r = assert(p.parse(lines, 2, path))
assert(r.url == "http://h/shared/file/shared-x/s3", r.url)
assert(env.vars(path).secret.private)
env.active = nil
r = assert(p.parse(lines, 2, path))
assert(r.url == "http://h/shared/file/{{c}}/{{secret}}", r.url)
vim.fn.delete(dir, "rf")

-- token expiry: JWT exp and OAuth expires_in; an expired cached login is dropped, not reused
local function jwt(claims)
  local b64 = function(t) return (vim.base64.encode(vim.json.encode(t)):gsub("=", ""):gsub("+", "-"):gsub("/", "_")) end
  return b64 { alg = "HS256" } .. "." .. b64(claims) .. ".sig"
end
local now = os.time()
assert(p.expires_at { body = { token = jwt { exp = now + 100 } } } == now + 100)
assert(p.expires_at { body = { access_token = "opaque", expires_in = 60 }, at = now } == now + 60)
assert(p.expires_at { body = { token = jwt { exp = now + 500 }, expires_in = 60 }, at = now } == now + 60)
assert(p.expires_at { body = { token = "a.b.c" } } == nil)
assert(p.expires_at { body = { token = jwt { sub = "x" } } } == nil)
p.responses = { login = { status = 200, headers = {}, body = { token = jwt { exp = now + 5 } }, at = now } }
local ok2, err2 = pcall(p.parse, { "GET http://h/{{login.body.token}}" }, 1)
assert(not ok2 and err2:find "has not been sent yet", tostring(err2)) -- 5s left < skew: treated as gone
assert(p.responses.login == nil, "expired login must be dropped")
p.responses.login = { status = 200, headers = {}, body = { token = jwt { exp = now + 3600 } }, at = now }
assert(p.parse({ "GET http://h/{{login.body.token}}" }, 1).url:find "^http://h/ey")

-- snippets all parse as LSP snippets
local G = require "vim.lsp._snippet_grammar"
for _, sn in ipairs(require("gooseman.snippets").list) do
  assert(pcall(G.parse, require("gooseman.snippets").lsp_body(sn.body)), sn.prefix)
end

-- nested tokens: {"data": {"auth": {"token": <jwt>}}}, and expires_in below the top level
assert(p.expires_at { body = { data = { auth = { token = jwt { exp = now + 42 } } } } } == now + 42)
assert(p.expires_at { body = { result = { credentials = { expires_in = 10 } } }, at = now } == now + 10)
assert(p.expires_at { body = { list = { { t = jwt { exp = now + 9 } }, { t = jwt { exp = now + 7 } } } } } == now + 7)

-- split_http keeps binary bodies byte-exact (only header \r's go)
local png = "\137PNG\r\n\26\n\0\0\r\n"
local heads, body = p.split_http("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n" .. png)
assert(#heads == 2 and heads[2] == "HTTP/1.1 200 OK\nContent-Type: image/png\n", vim.inspect(heads))
assert(body == png, "binary body changed")
heads, body = p.split_http "HTTP/1.1 204 No Content\n\n"
assert(#heads == 1 and body == "")

-- JSON path of the value under the cursor, from jq's pretty output
local view = require "gooseman.view"
local jl = vim.split([[{
  "user": {
    "id": 7,
    "tags": [
      "a",
      {
        "deep": true
      }
    ]
  },
  "odd key": 1
}]], "\n")
assert(view.json_path(jl, 1, 3) == "user.id")
assert(view.json_path(jl, 1, 5) == "user.tags.0")
assert(view.json_path(jl, 1, 7) == "user.tags.1.deep")
assert(view.json_path(jl, 1, 6) == "user.tags.1")
assert(view.json_path(jl, 1, 9) == "user.tags") -- closing ] names its array
assert(view.json_path(jl, 1, 11) == nil) -- "odd key" can't be a {{ref}} path
assert(view.json_path(jl, 1, 1) == "")

-- curl -w timing: cumulative seconds -> phases in ms, marker line stripped from stderr
local t, rest = p.timing "warn\n@@gooseman-timing 0.002 0.005 0.030 0.070 0.075\n"
assert(t.dns == 2 and t.connect == 3 and t.tls == 25 and t.server == 40 and t.download == 5 and t.total == 75, vim.inspect(t))
assert(rest == "warn", vim.inspect(rest))
t = p.timing "@@gooseman-timing 0.001 0.002 0 0.010 0.011\n"
assert(t.tls == nil and t.server == 8, vim.inspect(t))
assert(p.timing "" == nil)

-- @stream: directive, or an event-stream Accept header; @each rows from CSV and JSON
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "user, id", "ann,1", "", "bob, 2" }, dir .. "/u.csv")
vim.fn.writefile({ '[{"user":"ann","n":1,"x":null},{"user":"bob","tags":["a"]}]' }, dir .. "/u.json")
local s2 = p.scan(vim.split([[
### a
# @stream
GET http://x/
### b
GET http://x/events
Accept: text/event-stream
### c
# @each u.csv
GET http://x/{{user}}
### d
# @each u.json
GET http://x/]], "\n"))
assert(s2.blocks[1].stream and s2.blocks[2].stream and not s2.blocks[3].stream)
local rows = p.rows(s2.blocks[3], dir .. "/f.http")
assert(#rows == 2 and rows[2].user == "bob" and rows[2].id == "2", vim.inspect(rows))
rows = p.rows(s2.blocks[4], dir .. "/f.http")
assert(rows[1].n == "1" and rows[1].x == nil and rows[2].tags == '["a"]', vim.inspect(rows))
local ctx = p.context(vim.split("### c\nGET http://x/{{user}}", "\n"))
ctx.resolved = { user = "ann" }
assert(p.build(ctx, ctx.s.blocks[1]).url == "http://x/ann")

-- OpenAPI -> .http
local http = require("gooseman.openapi").to_http {
  info = { title = "geese" },
  servers = { { url = "http://api/v1/" } },
  paths = {
    ["/geese/{id}"] = {
      parameters = { { name = "id", ["in"] = "path", required = true } },
      get = { summary = "get a goose", parameters = { { ["$ref"] = "#/components/parameters/Q" } } },
      put = { requestBody = { content = { ["application/json"] = { schema = { ["$ref"] = "#/components/schemas/Goose" } } } } },
    },
  },
  components = {
    parameters = { Q = { name = "verbose", ["in"] = "query", required = true } },
    schemas = { Goose = { type = "object", properties = { name = { type = "string", example = "honk" } } } },
  },
}
local text = table.concat(http, "\n")
assert(text:find("@host = http://api/v1\n", 1, true), text)
assert(text:find("### get a goose\nGET {{host}}/geese/{{id}}?verbose={{verbose}}", 1, true), text)
assert(text:find("PUT {{host}}/geese/{{id}}\nContent-Type: application/json\n", 1, true), text)
assert(text:find('"name": "honk"', 1, true) or text:find('"name":"honk"', 1, true), text)
print "ok"
