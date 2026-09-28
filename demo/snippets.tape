# Snippets: build a working file from an empty one, Tab through the placeholders
Output demo/snippets.gif
Source demo/setup.tape

Type "nvim -u demo/init.lua geese.http" Enter
Sleep 2s
Show
Sleep 1s

Type "i@host = http://localhost:8080" Enter Enter
Sleep 500ms

# auth-login: a named login, and the file-wide Authorization header lands at the top
Type "auth-login" Sleep 400ms Ctrl+X Ctrl+O Sleep 1.5s
Ctrl+N Sleep 500ms Ctrl+Y Sleep 1.5s
Tab Sleep 500ms Tab Sleep 500ms Tab Sleep 500ms
Escape Sleep 1.5s

# post-json: Tab from placeholder to placeholder
Type "Go" Enter
Type "post-json" Sleep 400ms Ctrl+X Ctrl+O Sleep 1.5s
Ctrl+N Sleep 500ms Ctrl+Y Sleep 1s
Type "create a goose" Tab Sleep 300ms
Type "geese" Tab Sleep 300ms
Type "name" Tab Sleep 300ms
Type "honk" Tab Sleep 300ms
Escape Sleep 1.5s

# expect-ok: asserts for it
Type "/create" Enter Sleep 300ms
Type "o"
Type "expect-ok" Sleep 400ms Ctrl+X Ctrl+O Sleep 1.5s
Ctrl+N Sleep 500ms Ctrl+Y Sleep 1s
Tab Sleep 300ms Type "body.name" Tab Sleep 300ms
Escape Sleep 300ms
Type ":noh" Enter Sleep 1.2s

# fill in the credentials and run it all
Type "2G" Sleep 300ms
Type "o@user = gooseman" Enter Type "@password = secret" Escape
Sleep 1.5s
Type ":Honk all" Sleep 300ms Enter
Sleep 3.5s

Hide
Type ":qa!" Enter
Type "rm -f geese.http; kill $(jobs -p)" Enter
