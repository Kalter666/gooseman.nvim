# :Honk openapi turns a spec into requests
Output demo/openapi.gif
Source demo/setup.tape

Type "nvim -u demo/init.lua" Enter
Sleep 2s
Show
Sleep 1s

Type ":Honk openapi demo/petstore.json" Sleep 500ms Enter
Sleep 3s
Type ":%s/{{limit}}/2/" Sleep 300ms Enter Sleep 400ms
Type "5G" Sleep 300ms
Type ":Honk" Sleep 300ms Enter
Sleep 3s

Hide
Type ":qa!" Enter
Type "kill $(jobs -p)" Enter
