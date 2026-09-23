// Command protoc-gen-wtcrdt is the protoc/buf plugin of docs/spec/backlog.adoc PROTO-005.  It
// reads the wt.crdt merge-policy options and the buf.validate rules of the document schema and
// emits:
//
//   - <swift_out>/MergeTable.swift, MergeTable.json: the merge table for the Swift engine and
//     the serialized table `Welcome.merge_table` carries (docs/spec/crdt-model.adoc);
//   - <swift_out>/Validators.swift, SkippedRules.md: Swift checks of the standard protovalidate
//     rules and the list of rules they skip (docs/spec/api-conventions.adoc, "Validation");
//   - <java_out>/<java_package>/MergeTable.java, merge-table.json: the table for the Java engine.
//
// Parameters: swift_out=<dir>,java_out=<dir>,java_package=<pkg> (see internal/gen/params.go).
// It needs the whole module in one request (buf.gen.yaml `strategy: all`).
package main

import (
	"fmt"
	"io"
	"os"

	// Registers the buf.validate extensions so they are parsed out of the request's options.
	_ "buf.build/gen/go/bufbuild/protovalidate/protocolbuffers/go/buf/validate"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/pluginpb"

	"github.com/villagecompute/wiretuner/tools/protoc-gen-wtcrdt/internal/gen"
)

// version is set with -ldflags "-X main.version=..." by the Makefile.
var version = "dev"

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println("protoc-gen-wtcrdt " + version)
		return
	}
	if err := run(os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "protoc-gen-wtcrdt:", err)
		os.Exit(1)
	}
}

func run(in io.Reader, out, warn io.Writer) error {
	data, err := io.ReadAll(in)
	if err != nil {
		return fmt.Errorf("reading the request: %w", err)
	}
	req := &pluginpb.CodeGeneratorRequest{}
	if err := proto.Unmarshal(data, req); err != nil {
		return fmt.Errorf("decoding the CodeGeneratorRequest: %w", err)
	}
	resp := gen.Response(req, warn)
	encoded, err := proto.Marshal(resp)
	if err != nil {
		return fmt.Errorf("encoding the response: %w", err)
	}
	_, err = out.Write(encoded)
	return err
}
