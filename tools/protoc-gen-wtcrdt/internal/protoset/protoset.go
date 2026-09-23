// Package protoset compiles the repository's proto/ tree into descriptors without the BSR:
// buf/validate/validate.proto comes from the protovalidate Go module this tool pins (the same
// BSR commit as the repository's buf.lock) and google/protobuf/* from protocompile's standard
// imports.  The generate target feeds the result to protoc (`--descriptor_set_in`) and the
// golden tests build CodeGeneratorRequests from it.
package protoset

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	validate "buf.build/gen/go/bufbuild/protovalidate/protocolbuffers/go/buf/validate"
	"github.com/bufbuild/protocompile"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/pluginpb"
)

// ModuleFiles lists the module's .proto files under root, relative and sorted, leaving out
// what buf.yaml excludes (wiretuner/internal) and generated output (gen/).
func ModuleFiles(root string) ([]string, error) {
	var files []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		rel = filepath.ToSlash(rel)
		if d.IsDir() && (rel == "gen" || rel == "wiretuner/internal") {
			return filepath.SkipDir
		}
		if !d.IsDir() && strings.HasSuffix(rel, ".proto") {
			files = append(files, rel)
		}
		return nil
	})
	sort.Strings(files)
	return files, err
}

// Compile compiles files. Each file is read from overlay when present there, else from root.
func Compile(root string, overlay map[string]string, files []string) ([]protoreflect.FileDescriptor, error) {
	validateProto := protodesc.ToFileDescriptorProto(validate.File_buf_validate_validate_proto)
	resolver := protocompile.WithStandardImports(protocompile.ResolverFunc(func(name string) (protocompile.SearchResult, error) {
		if name == validateProto.GetName() {
			return protocompile.SearchResult{Proto: validateProto}, nil
		}
		if src, ok := overlay[name]; ok {
			return protocompile.SearchResult{Source: strings.NewReader(src)}, nil
		}
		if root == "" {
			return protocompile.SearchResult{}, fmt.Errorf("%s: not found", name)
		}
		f, err := os.Open(filepath.Join(root, filepath.FromSlash(name)))
		if err != nil {
			return protocompile.SearchResult{}, err
		}
		return protocompile.SearchResult{Source: f}, nil
	}))
	compiler := protocompile.Compiler{Resolver: resolver, SourceInfoMode: protocompile.SourceInfoNone}
	linked, err := compiler.Compile(context.Background(), files...)
	if err != nil {
		return nil, err
	}
	out := make([]protoreflect.FileDescriptor, len(linked))
	for i, f := range linked {
		out[i] = f
	}
	return out, nil
}

// DescriptorSet is every file and its transitive imports, dependencies first.
func DescriptorSet(files []protoreflect.FileDescriptor) *descriptorpb.FileDescriptorSet {
	set := &descriptorpb.FileDescriptorSet{}
	seen := map[string]bool{}
	var add func(protoreflect.FileDescriptor)
	add = func(f protoreflect.FileDescriptor) {
		if seen[f.Path()] {
			return
		}
		seen[f.Path()] = true
		imports := f.Imports()
		for i := 0; i < imports.Len(); i++ {
			add(imports.Get(i).FileDescriptor)
		}
		set.File = append(set.File, protodesc.ToFileDescriptorProto(f))
	}
	for _, f := range files {
		add(f)
	}
	return set
}

// Request is the CodeGeneratorRequest protoc would send for files with parameter.  It is
// marshalled and re-parsed so custom options decode through the global registry exactly as
// they do in the plugin binary.
func Request(files []protoreflect.FileDescriptor, parameter string) (*pluginpb.CodeGeneratorRequest, error) {
	req := &pluginpb.CodeGeneratorRequest{Parameter: proto.String(parameter)}
	for _, f := range files {
		req.FileToGenerate = append(req.FileToGenerate, f.Path())
	}
	req.ProtoFile = DescriptorSet(files).File
	data, err := proto.Marshal(req)
	if err != nil {
		return nil, err
	}
	parsed := &pluginpb.CodeGeneratorRequest{}
	return parsed, proto.Unmarshal(data, parsed)
}
