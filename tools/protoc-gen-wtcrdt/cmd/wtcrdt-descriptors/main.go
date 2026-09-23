// Command wtcrdt-descriptors compiles the proto/ module (without the BSR, see
// internal/protoset) and writes it as one FileDescriptorSet, so protoc can run the plugin with
// `--descriptor_set_in` (the Makefile's `generate` target).
//
//	wtcrdt-descriptors <proto root> <out.binpb>
package main

import (
	"fmt"
	"os"

	"google.golang.org/protobuf/proto"

	"github.com/villagecompute/wiretuner/tools/protoc-gen-wtcrdt/internal/protoset"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: wtcrdt-descriptors <proto root> <out.binpb>")
		os.Exit(2)
	}
	if err := run(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "wtcrdt-descriptors:", err)
		os.Exit(1)
	}
}

func run(root, out string) error {
	names, err := protoset.ModuleFiles(root)
	if err != nil {
		return err
	}
	files, err := protoset.Compile(root, nil, names)
	if err != nil {
		return err
	}
	data, err := proto.Marshal(protoset.DescriptorSet(files))
	if err != nil {
		return err
	}
	return os.WriteFile(out, data, 0o644)
}
