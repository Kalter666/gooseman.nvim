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
print "ok"
