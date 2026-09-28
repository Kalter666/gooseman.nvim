# gRPC: list services, complete method names from reflection, fill the body, call
Output demo/grpc.gif
Source demo/setup.tape

Type "nvim -u demo/init.lua demo/grpc.http" Enter
Sleep 2s
Show
Sleep 1s

Type "5G" Sleep 300ms
Type ":Honk" Sleep 300ms Enter
Sleep 2.5s

# method names come from the server's reflection
Type "8G" Sleep 300ms
Type "Agrpc.health.v1.Health/" Sleep 1.5s
Ctrl+X Ctrl+O Sleep 1.5s
Ctrl+N Sleep 600ms Ctrl+Y Sleep 300ms Escape Sleep 1s

# code action: request body template from the method's input message
Type "gra" Sleep 1.5s
Type "4" Sleep 400ms Enter
Sleep 2s

Type ":Honk" Sleep 300ms Enter
Sleep 3s

Hide
Type ":qa!" Enter
Type "kill $(jobs -p)" Enter
