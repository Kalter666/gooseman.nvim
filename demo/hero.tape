# Record: vhs demo/hero.tape   (from the repo root; needs vhs, go, grpcurl, websocat, jq)
Output demo/hero.gif
Source demo/setup.tape

Type "nvim -u demo/init.lua demo/hero.http" Enter
Sleep 2s
Show

# the file: variables resolve inline, the token comes from the login response
Sleep 2s

# log in
Type "]r"
Sleep 500ms
Type ":Honk" Sleep 400ms Enter
Sleep 3s

# the next request reuses the login token via the file-wide header
Type "]r"
Sleep 500ms
Type ":Honk" Sleep 400ms Enter
Sleep 3s

# create a goose, then filter the response with jq
Type "]r"
Sleep 500ms
Type ":Honk" Sleep 400ms Enter
Sleep 2.5s
Type ":Honk jq .body" Sleep 400ms Enter
Sleep 3s

# run the whole file as a smoke test
Type ":Honk all" Sleep 400ms Enter
Sleep 4s

Hide
Type ":qa!" Enter
Type "kill $(jobs -p)" Enter
