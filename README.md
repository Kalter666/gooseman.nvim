<div align="center">

# 🪿 gooseman.nvim

**A postman goose. Point it at a request, it honks it at the server.**

*HTTP, gRPC and WebSocket requests from plain `.http` files, right in Neovim.*

[![Neovim](https://img.shields.io/badge/Neovim-0.10+-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Made%20with-Lua-2C2D72?logo=lua&logoColor=white)](https://lua.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

</div>

---

Write requests in a `.http` file, put the cursor inside one, run `:Honk`.
The goose doesn't reinvent anything. It hands each request to a tool you already trust:

| Request line                              | Tool       | Result                                         |
| ----------------------------------------- | ---------- | ---------------------------------------------- |
| `GET` `POST` `PUT` `PATCH` `DELETE` … url | `curl`     | response in a split, JSON pretty-printed by jq |
| `GRPC host:port pkg.Service/Method`       | `grpcurl`  | response in a split                            |
| `WS ws://…`                               | `websocat` | interactive terminal split                     |

## 📦 Install

Needs Neovim 0.10+ and whichever tools you use: `curl`, `grpcurl`, `websocat`, `jq` (optional).
`:checkhealth gooseman` tells you what's missing.

```lua
-- lazy.nvim
{
  "Kalter666/gooseman.nvim",
  ft = "http",
  cmd = "Honk",
  keys = { { "<leader>Rs", "<cmd>Honk<cr>", ft = "http", desc = "Honk request under cursor" } },
}
```

No `setup()` needed.

## 📝 The `.http` format

```http
@host = http://localhost:8080

### create a goose
POST {{host}}/geese
Content-Type: application/json

{"name": "gooseman"}
```

- **Blocks** are separated by lines starting with `###`. `:Honk` sends the block under the cursor.
- **Comments**: lines starting with `#` or `//` (outside the body).
- **Variables**: `@name = value` anywhere in the file, used as `{{name}}`.
  They can reference each other: `@url = {{host}}/v1`.
- **Environment**: `{{NAME}}` with no matching file variable reads `$NAME`.
- **Shell variables**: `@token = $(some command)` runs through `sh` when a request uses it,
  and the trimmed stdout becomes the value. This is how you fetch tokens, read secrets, and encode things.
  It runs on every `:Honk` that uses it.
- **Raw flags**: `# @args ...` inside a block appends flags to curl/grpcurl/websocat for that request only
  (`-u`, `--cert`, `-insecure`, `-proto`, `--basic-auth`, …). Split on whitespace, no quoting.

> ⚠️ `$(…)` variables run shell commands, so only honk `.http` files you trust.

## 🔐 Authorization cookbook

Full, runnable versions of all of these are in [`examples/auth.http`](examples/auth.http).

**Basic auth.** Let curl encode it, or build the header yourself:

```http
### curl does the base64
# @args -u gooseman:secret
GET {{host}}/basic

### manual header
@basic = $(printf '%s:%s' '{{user}}' '{{pass}}' | base64 -w0)
GET {{host}}/basic
Authorization: Basic {{basic}}
```

**Bearer token.** Inline, from the environment, or from a password manager:

```http
### from $GOOSE_TOKEN
GET {{host}}/bearer
Authorization: Bearer {{GOOSE_TOKEN}}

### from pass / secret-tool / 1password-cli / vault …
@token = $(pass show work/api-token)
GET {{host}}/bearer
Authorization: Bearer {{token}}
```

**Login, then use the token**:

```http
@login_token = $(curl -s {{host}}/login -H 'Content-Type: application/json' -d '{"user":"gooseman","password":"secret"}' | jq -r .token)
GET {{host}}/bearer
Authorization: Bearer {{login_token}}
```

**OAuth2 client credentials**:

```http
@oauth_token = $(curl -s -u '{{client_id}}:{{client_secret}}' -d grant_type=client_credentials {{host}}/oauth/token | jq -r .access_token)
GET {{host}}/bearer
Authorization: Bearer {{oauth_token}}
```

**API key** in a header (`X-API-Key: …`) or the query string (`?api_key=…`).

**Cookies.** Send `Cookie: session=…` by hand, or use a curl cookie jar:

```http
### log in, store cookies
# @args -c /tmp/gooseman.cookies
POST {{host}}/login
...

### reuse them
# @args -b /tmp/gooseman.cookies
GET {{host}}/cookie
```

**mTLS / self-signed certs**:

```http
# @args --cert ./client.crt --key ./client.key --cacert ./ca.crt
GET https://mtls.example.com/whoami
```

**gRPC.** Headers become metadata, so auth looks the same as HTTP. TLS flags go through `@args`:

```http
### grpc:// = plaintext, grpcs:// or bare host = TLS
GRPC grpc://localhost:50051 grpc.health.v1.Health/Check
Authorization: Bearer {{GOOSE_TOKEN}}

{"service": "goose"}

### mTLS
# @args -cert ./client.crt -key ./client.key -cacert ./ca.crt
GRPC grpcs://grpc.example.com:443 pkg.Service/Method
```

**WebSocket.** Headers go on the handshake. For Basic auth use websocat's flag:

```http
WS wss://api.example.com/stream
Authorization: Bearer {{GOOSE_TOKEN}}

{"subscribe": "geese"}

### Basic
# @args --basic-auth gooseman:secret
WS wss://api.example.com/stream
```

## 🛰️ gRPC

- `GRPC host:port` lists services (uses server reflection).
- `GRPC host:port pkg.Service` lists that service's methods.
- `GRPC host:port pkg.Service/Method` calls it. The body is the JSON request (empty body sends `{}`).
- No reflection on the server? Use `# @args -import-path ./proto -proto service.proto`.

## 🔌 WebSocket

`WS` opens a terminal split running websocat. Body lines are sent as the first messages
right after connecting. After that, type a line and press Enter to send it, and Ctrl-C hangs up.

## 🧪 Playground

Fake servers for trying every example locally:

```sh
python3 tests/echo_server.py                    # HTTP on :8080, auth routes listed at top of file
(cd tests/grpc_server && go run .)              # gRPC on :50051, health service + reflection
websocat -t ws-l:127.0.0.1:9000 mirror:         # WebSocket echo on :9000
```

Then open [`examples/`](examples) and honk away:
[`basics.http`](examples/basics.http) · [`auth.http`](examples/auth.http) ·
[`grpc.http`](examples/grpc.http) · [`websocket.http`](examples/websocket.http)

Parser tests: `nvim -l tests/parse.lua`

## 📄 License

MIT
