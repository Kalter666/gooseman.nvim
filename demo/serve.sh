# Sourced (hidden) by every tape: the fake servers the demos talk to, and a throwaway
# state dir so the active environment doesn't leak between recordings.
export XDG_STATE_HOME=$(mktemp -d)
bin=$XDG_STATE_HOME/grpc_server
go build -C tests/grpc_server -o "$bin" . && "$bin" >/dev/null 2>&1 &
python3 tests/echo_server.py >/dev/null 2>&1 &
websocat -t ws-l:127.0.0.1:9000 mirror: >/dev/null 2>&1 &
for port in 8080 9000 50051; do
  until (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; do sleep 0.2; done
done
