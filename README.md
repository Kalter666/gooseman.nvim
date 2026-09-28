<div align="center">

# 🪿 gooseman.nvim

**A goose that delivers your requests. Point it at one, it honks it at the server.**

*HTTP, gRPC and WebSocket requests from plain `.http` files, right in Neovim.*

[![Neovim](https://img.shields.io/badge/Neovim-0.10+-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Made%20with-Lua-2C2D72?logo=lua&logoColor=white)](https://lua.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

</div>

---

Write requests in a `.http` file, put the cursor inside one, run `:Honk`.
Name a login once and every other request reuses its token. Switch between dev and prod environments,
assert on responses and run a whole file as a smoke test, and paste curl commands straight from browser devtools.
A built-in LSP completes it all.
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

## ⌨️ Commands

| Command                 | What it does                                                               |
| ----------------------- | -------------------------------------------------------------------------- |
| `:Honk`                 | send the request under the cursor                                          |
| `:Honk!`                | same, but forget cached named responses first (fresh login)                |
| `:Honk all`             | run every request in the file top to bottom; ✓/✗ report + quickfix        |
| `:Honk env [name]`      | pick an environment from `gooseman.json` (no name = picker, `none` = off)  |
| `:Honk curl`            | copy the request under the cursor as a shell command                      |
| `:Honk import`          | clipboard curl command → `.http` block (`:'<,'>Honk import` converts a selection in place) |

Statusline: `require("gooseman").statusline()` returns `🪿 dev` while an environment is active.

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
- **Named requests**: `# @name login` lets any request use its response:
  `{{login.body.token}}`, `{{login.headers.Set-Cookie}}`, `{{login.status}}`. See [reusing auth](#️-reusing-auth-across-requests).
- **File-wide settings**: before the first `###`, `# @header K: V` adds a header to every request
  and `# @args ...` adds flags to every request. A request's own header with the same name wins.

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

**Login, then use the token.** The best way is a named request (see [below](#️-reusing-auth-across-requests)).
A one-off shell variable works too:

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

## ♻️ Reusing auth across requests

Name the login request once, then point a file-wide header at its response:

```http
@host = http://localhost:8080
# @header Authorization: Bearer {{login.body.token}}

### login
# @name login
POST {{host}}/login
Content-Type: application/json

{"user": "gooseman", "password": "secret"}

### every request below is authorized, HTTP and gRPC alike
GET {{host}}/me

### override for one request
GET {{host}}/me
Authorization: Bearer someone-else
```

- **Runs on demand.** The first `:Honk` that needs `{{login.…}}` runs `login` first, then caches its response.
- **Cached for the session.** Any file can use the cache: honk `login` in `auth.http` and use `{{login.body.token}}` in `orders.http`.
- **Auto-refresh.** A request that gets a **401** while using a cached response re-runs that dependency
  and retries once. Honk `login` again to refresh it by hand, or run `:Honk!` to forget every cached response.
- **No self-reference.** A request never uses its own response: `login` skips the file-wide header built from it.
- **Response fields:** `status`, `headers.<name>` (any case), and `body.<key>.<key>`. Arrays use a 0-based index: `{{list.body.items.0.id}}`.
  gRPC responses work the same way (`body` is the JSON reply).
- **Chaining** works the same way: create something, then use `{{created.body.id}}` in the next request.
- **Rate limits.** Auto-refresh stays conservative:
  - only on 401 (403 means forbidden, and a new token won't help)
  - each named request is refreshed at most once per 60s (`require("gooseman").REFRESH_COOLDOWN`), so a run with
    ten 401s logs in once, not ten times
  - `vim.g.gooseman_auto_refresh = false` turns it off
- **Cookie sessions:** put `# @args -b /tmp/jar -c /tmp/jar` before the first `###` (HTTP-only files, since
  file-wide `@args` go to every tool).

## 🌍 Environments

Put a `gooseman.json` next to your `.http` files (or in any parent directory):

```json
{
  "$shared": { "user": "gooseman" },
  "dev":     { "host": "http://localhost:8080" },
  "prod":    { "host": "https://api.example.com" }
}
```

`:Honk env prod` switches, and `{{host}}` follows. `$shared` applies to every environment.
Keep secrets in `gooseman.private.json` (same shape, add it to `.gitignore`). It wins over `gooseman.json`,
and the LSP hover masks its values. Environment values can use `{{refs}}` and `$(shell)` like `@vars`.
An `@var` in the file wins over the environment.

## ✅ Asserts & smoke tests

```http
### login
# @name login
# @expect status == 200
# @expect body.token exists
# @expect headers.content-type contains json
POST {{host}}/login
...
```

`# @expect <path> <op> [value]`:

- **path:** `status`, `headers.<name>` or `body.<key>.<0-based index>`, the same paths as `{{name.…}}`.
- **op:** `==` `!=` `<` `<=` `>` `>=` `contains` `matches` (Lua pattern) `exists` `!exists`. Numbers compare as numbers.
- **values** can use `{{refs}}`: `# @expect body.owner == {{user}}`.
- **no `@expect`:** the request passes when it exits 0 with status < 400.

`:Honk` shows the ✓/✗ lines above the response. `:Honk all` runs the whole file in order, so logins and
chains work, and prints a report. Failures go to the quickfix list. See [`examples/tests.http`](examples/tests.http).

## 📋 curl in and out

- **`:Honk curl`** copies the request under the cursor as a ready-to-share command: curl, grpcurl, or websocat.
  Variables are already filled in.
- **`:Honk import`** turns a curl command (from devtools **Copy as cURL**, docs, Slack…) into a `.http` block:
  - `-u` becomes a Basic header, `-b` a Cookie header, `--json` sets the JSON headers
  - `-d`/`--data-raw` becomes the body
  - `-L`, `-k`, `--compressed` and other flags go into `# @args`
  - It handles `'…'`, `"…"`, `$'…'` quoting and `\` line continuations.

## 🧠 Built-in LSP

Opening a `.http` file starts a tiny language server inside Neovim. There's no binary and nothing to configure,
and your usual LSP keymaps and completion plugin (blink.cmp, nvim-cmp) pick it up.

| Feature         | What it does                                                                             |
| --------------- | ---------------------------------------------------------------------------------------- |
| Completion      | `{{` variables, environment variables and named requests, `{{login.body.` response fields (from the cache), methods, headers, common header values, `# @` directives, `@expect` paths and operators |
| Hover           | what `{{ref}}` resolves to. Shell vars show their command without running it; private environment values and OS env vars are masked |
| Go to definition| `{{ref}}` jumps to its `@var` line, the `# @name` line, or the entry in `gooseman.json`  |
| Diagnostics     | undefined `{{refs}}` (re-checked on `:Honk env`), unknown methods, unknown directives, invalid `@expect`, duplicate `@name`s |

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
[`basics.http`](examples/basics.http) · [`auth.http`](examples/auth.http) · [`reuse.http`](examples/reuse.http) ·
[`grpc.http`](examples/grpc.http) · [`websocket.http`](examples/websocket.http) ·
[`environments.http`](examples/environments.http) + [`gooseman.json`](examples/gooseman.json) ·
[`tests.http`](examples/tests.http) (`:Honk all`)

Parser tests: `nvim -l tests/parse.lua`

## 📄 License

MIT
