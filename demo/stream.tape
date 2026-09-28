# WebSocket and Server-Sent Events in a terminal split
Output demo/stream.gif
Source demo/setup.tape

Type "nvim -u demo/init.lua demo/stream.http" Enter
Sleep 2s
Show
Sleep 1.5s

Type "2G" Sleep 300ms
Type ":Honk" Sleep 300ms Enter
Sleep 2s
Type `{"honk": true}` Sleep 300ms Enter
Sleep 2s
Ctrl+C Sleep 800ms
Enter
Sleep 1s

Type "7G" Sleep 300ms
Type ":Honk" Sleep 300ms Enter
Sleep 5.5s
Enter
Sleep 1s

Hide
Type ":qa!" Enter
Type "kill $(jobs -p)" Enter
