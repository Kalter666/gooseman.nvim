# The response window: folded headers, yr copies a {{ref}}, raw view, binary bodies, :Honk save
Output demo/response.gif
Source demo/setup.tape

Type "nvim -u demo/init.lua demo/response.http" Enter
Sleep 2s
Show
Sleep 1s

Type "]r" Sleep 400ms
Type ":Honk" Sleep 300ms Enter
Sleep 2s

# into the response: open the folded headers, then close them again
Ctrl+W Type "l" Sleep 500ms
Type "5G" Sleep 400ms Type "zo" Sleep 2s Type "zc" Sleep 1s

# yr on a value copies its {{ref}}; the request gets a name first
Type "/chaotic" Sleep 300ms Enter Sleep 800ms
Type "yr" Sleep 1.2s
Ctrl+U Sleep 200ms Type "goose" Sleep 500ms Enter
Sleep 2.5s

# R: everything curl printed, as is
Type "R" Sleep 2s Type "R" Sleep 1s

# binary body, and saving it
Ctrl+W Type "h" Sleep 500ms
Type "]r" Sleep 400ms
Type ":Honk" Sleep 300ms Enter
Sleep 2.5s
Type ":Honk save goose.png" Sleep 400ms Enter
Sleep 2.5s

Hide
Type ":qa!" Enter
Type "rm -f goose.png; kill $(jobs -p)" Enter
