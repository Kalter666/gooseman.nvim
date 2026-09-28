// Fake gRPC server for trying gooseman: standard health service + server reflection.
//
// run: cd tests/grpc_server && go run . [addr]   (default localhost:50051)
//
// Reflection (grpcurl list/describe) is open. Unary calls need metadata
// "authorization: Bearer static-token" (or a login-* token from echo_server.py),
// otherwise Unauthenticated.
package main

import (
	"context"
	"log"
	"net"
	"os"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"
)

func auth(ctx context.Context, req any, _ *grpc.UnaryServerInfo, next grpc.UnaryHandler) (any, error) {
	md, _ := metadata.FromIncomingContext(ctx)
	if v := md.Get("authorization"); len(v) == 0 || (v[0] != "Bearer static-token" && !strings.HasPrefix(v[0], "Bearer login-")) {
		return nil, status.Error(codes.Unauthenticated, "want authorization: Bearer static-token")
	}
	return next(ctx, req)
}

func main() {
	addr := "localhost:50051"
	if len(os.Args) > 1 {
		addr = os.Args[1]
	}
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	s := grpc.NewServer(grpc.UnaryInterceptor(auth))
	hs := health.NewServer()
	hs.SetServingStatus("goose", healthpb.HealthCheckResponse_SERVING)
	healthpb.RegisterHealthServer(s, hs)
	reflection.Register(s)
	log.Printf("grpc server on %s", addr)
	log.Fatal(s.Serve(lis))
}
