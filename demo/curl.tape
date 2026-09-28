# :Honk curl copies a request as a command; :Honk import turns one back into a request
Output demo/curl.gif
Source demo/setup.tape

Type `nvim -u demo/init.lua demo/curl.http +"luafile demo/clip.lua"` Enter
Sleep 2s
Show
Sleep 1.5s

# in: the clipboard holds a command copied from browser devtools
Type "G" Sleep 300ms
Type ":Honk import" Sleep 300ms Enter
Sleep 3s
Type ":Honk" Sleep 300ms Enter
Sleep 3s

# out: the request under the cursor as a shell command, variables filled in
Type ":Honk curl" Sleep 300ms Enter
Sleep 1.5s
Type "G" Sleep 200ms
Type ":put +" Sleep 300ms Enter
Sleep 3s

Hide
Type ":qa!" Enter
Type "kill $(jobs -p)" Enter
