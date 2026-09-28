# :Honk diff against the previous response, :Honk history to go back
Output demo/diff.gif
Source demo/setup.tape

Type "nvim -u demo/init.lua demo/diff.http" Enter
Sleep 2s
Show
Sleep 1s

Type "]r" Sleep 400ms
Type ":Honk" Sleep 300ms Enter
Sleep 2s

# change the body and send again
Type "7G" Sleep 300ms Type "fbciwgrass" Escape Sleep 300ms
Type "f1r3" Sleep 800ms
Type ":Honk" Sleep 300ms Enter
Sleep 2s

Type ":Honk diff" Sleep 300ms Enter
Sleep 4s
Type ":tabclose" Sleep 300ms Enter
Sleep 800ms

Type ":Honk history" Sleep 300ms Enter
Sleep 2.5s
Type "2" Sleep 500ms Enter
Sleep 3s

Hide
Type ":qa!" Enter
Type "kill $(jobs -p)" Enter
