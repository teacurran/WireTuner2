module github.com/villagecompute/wiretuner/tools/protoc-gen-wtcrdt

go 1.27

require (
	buf.build/gen/go/bufbuild/protovalidate/protocolbuffers/go v1.36.12-20260825204119-511051f7f437.2
	github.com/bufbuild/protocompile v0.14.1
	google.golang.org/protobuf v1.36.12
)

require golang.org/x/sync v0.8.0 // indirect

tool google.golang.org/protobuf/cmd/protoc-gen-go
