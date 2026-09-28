# Asserts, @each, :Honk all + quickfix, and the same file as a CI check
Output demo/tests.gif
Source demo/setup.tape

Type "nvim -u demo/init.lua demo/tests.http" Enter
Sleep 2s
Show
Sleep 2.5s

Type ":Honk all" Sleep 300ms Enter
Sleep 3.5s

# failures land in the quickfix list
Type ":copen" Sleep 300ms Enter
Sleep 2s
Enter
Sleep 2s
Type ":qa!" Sleep 300ms Enter
Hide
Type "clear" Enter
Show
Sleep 800ms

# headless: prints the report, exit code 1 on failure
Type `nvim --headless -u demo/init.lua demo/tests.http +"Honk all"; echo "exit code: $?"` Sleep 500ms Enter
Sleep 4s

Hide
Type "kill $(jobs -p)" Enter
