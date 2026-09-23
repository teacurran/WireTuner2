package gen

import (
	"io"
	"path"
	"strings"

	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/pluginpb"
)

// Output is one generated file, its name relative to the plugin's output directory.
type Output struct {
	Name    string
	Content []byte
}

// Generate produces every output file for a request.  The request must carry the whole module
// (buf `strategy: all`, or every file on one protoc command line): the merge table is one
// document over every message reachable from the roots.
func Generate(req *pluginpb.CodeGeneratorRequest, warn io.Writer) ([]Output, error) {
	params, err := ParseParams(req.GetParameter())
	if err != nil {
		return nil, err
	}
	plugin, err := newPlugin(req)
	if err != nil {
		return nil, err
	}
	table, err := BuildTable(plugin, warn)
	if err != nil {
		return nil, err
	}
	var outs []Output
	jsonDoc := table.SerializedJSON()
	if params.SwiftOut != "" {
		files := make([]protoreflect.FileDescriptor, 0, len(plugin.Files))
		for _, f := range plugin.Files {
			files = append(files, f.Desc)
		}
		v, err := EmitSwiftValidators(ValidatorRoots(files))
		if err != nil {
			return nil, err
		}
		outs = append(outs,
			Output{path.Join(params.SwiftOut, "MergeTable.json"), jsonDoc},
			Output{path.Join(params.SwiftOut, "MergeTable.swift"), EmitSwiftMergeTable(table)},
			Output{path.Join(params.SwiftOut, "SkippedRules.md"), EmitSkippedRules(v.Skipped)},
			Output{path.Join(params.SwiftOut, "Validators.swift"), v.Swift},
		)
	}
	if params.JavaOut != "" {
		dir := path.Join(params.JavaOut, strings.ReplaceAll(params.JavaPackage, ".", "/"))
		outs = append(outs,
			Output{path.Join(dir, "MergeTable.java"), EmitJavaMergeTable(table, params.JavaPackage)},
			Output{path.Join(dir, JavaResourceName), jsonDoc},
		)
	}
	return outs, nil
}

// newPlugin builds protogen's view of the request.  protogen insists on a Go import path for
// every file; ours emit no Go, so each file without go_package gets a placeholder, and the
// parameters (ours, not protoc-gen-go's) are withheld from protogen's own parser.
func newPlugin(req *pluginpb.CodeGeneratorRequest) (*protogen.Plugin, error) {
	req = proto.Clone(req).(*pluginpb.CodeGeneratorRequest)
	req.Parameter = nil
	for _, f := range req.GetProtoFile() {
		if f.GetOptions().GetGoPackage() != "" {
			continue
		}
		if f.Options == nil {
			f.Options = &descriptorpb.FileOptions{}
		}
		f.Options.GoPackage = proto.String("wtcrdt.invalid/" + path.Dir(f.GetName()))
	}
	return protogen.Options{}.New(req)
}

// Response wraps Generate for the plugin protocol: an error becomes the response's error.
func Response(req *pluginpb.CodeGeneratorRequest, warn io.Writer) *pluginpb.CodeGeneratorResponse {
	resp := &pluginpb.CodeGeneratorResponse{
		SupportedFeatures: proto.Uint64(uint64(pluginpb.CodeGeneratorResponse_FEATURE_PROTO3_OPTIONAL)),
	}
	outs, err := Generate(req, warn)
	if err != nil {
		resp.Error = proto.String("protoc-gen-wtcrdt: " + err.Error())
		return resp
	}
	for _, o := range outs {
		resp.File = append(resp.File, &pluginpb.CodeGeneratorResponse_File{
			Name:    proto.String(o.Name),
			Content: proto.String(string(o.Content)),
		})
	}
	return resp
}
