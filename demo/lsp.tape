# The built-in LSP: completion from cached responses, hover, go to definition,
# diagnostics, code actions and snippets
Output demo/lsp.gif
Source demo/setup.tape

Type "nvim -u demo/init.lua demo/lsp.http" Enter
Sleep 2s
Show
Sleep 1s

# log in once so completion knows the response
Type "5G" Sleep 300ms
Type ":Honk" Sleep 300ms Enter
Sleep 1.5s

# completion: {{ lists variables and named requests, login.body. lists its fields
Type "11G" Sleep 300ms
Type "oAuthorization: Bearer {{" Sleep 1.5s
Type "login.body." Sleep 1.5s
Ctrl+N Sleep 600ms Ctrl+Y Sleep 300ms
Type "}}" Escape Sleep 1.5s

# hover shows what it resolves to; gd jumps to the definition
Type "12G" Sleep 200ms Type "fl" Sleep 300ms
Type "K" Sleep 2.5s
Type "l" Sleep 200ms Type "h" Sleep 300ms
Type "gd" Sleep 2s
Ctrl+O Sleep 1s

# diagnostics: an undefined variable
Type "11GA?goose={{nope}}" Escape Sleep 2.5s
Type "u" Sleep 800ms

# code action: add @expect lines from the last response
Type "5G" Sleep 300ms
Type "gra" Sleep 2s
Type "3" Sleep 500ms Enter
Sleep 2.5s

# snippets
Type "G" Sleep 200ms
Type "o" Enter Type "post-json" Sleep 300ms
Ctrl+X Ctrl+O Sleep 1.5s
Ctrl+N Sleep 500ms Ctrl+Y Sleep 2.5s
Escape Sleep 1s

Hide
Type ":qa!" Enter
Type "kill $(jobs -p)" Enter
