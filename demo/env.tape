# Environments from gooseman.json, and the prod guard
Output demo/env.gif
Source demo/setup.tape

Type "nvim -u demo/init.lua demo/env.http" Enter
Sleep 2s
Show
Sleep 2s

Type ":Honk env" Sleep 300ms Enter
Sleep 2s
Type "1" Sleep 400ms Enter
Sleep 2.5s

Type "5G" Sleep 300ms
Type ":Honk" Sleep 300ms Enter
Sleep 2.5s

# anything named prod asks before sending
Type ":Honk env prod" Sleep 300ms Enter
Sleep 2s
Type ":Honk" Sleep 300ms Enter
Sleep 2.5s
Type "c"
Sleep 2s

Hide
Type ":qa!" Enter
Type "kill $(jobs -p)" Enter
