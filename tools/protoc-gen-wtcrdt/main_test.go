package main

import (
	"bytes"
	"errors"
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/pluginpb"

	"github.com/villagecompute/wiretuner/tools/protoc-gen-wtcrdt/internal/protoset"
)

func TestRunRoundTrip(t *testing.T) {
	names, err := protoset.ModuleFiles("../../proto")
	if err != nil {
		t.Fatal(err)
	}
	files, err := protoset.Compile("../../proto", nil, names)
	if err != nil {
		t.Fatal(err)
	}
	req, err := protoset.Request(files, "swift_out=s")
	if err != nil {
		t.Fatal(err)
	}
	in, _ := proto.Marshal(req)
	var out, warn bytes.Buffer
	if err := run(bytes.NewReader(in), &out, &warn); err != nil {
		t.Fatal(err)
	}
	resp := &pluginpb.CodeGeneratorResponse{}
	if err := proto.Unmarshal(out.Bytes(), resp); err != nil {
		t.Fatal(err)
	}
	if resp.GetError() != "" || len(resp.GetFile()) != 4 {
		t.Fatalf("response: error %q, %d files", resp.GetError(), len(resp.GetFile()))
	}
	if resp.GetSupportedFeatures()&uint64(pluginpb.CodeGeneratorResponse_FEATURE_PROTO3_OPTIONAL) == 0 {
		t.Error("proto3 optional not declared")
	}
}

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("boom") }

func TestRunErrors(t *testing.T) {
	var out bytes.Buffer
	if err := run(failingReader{}, &out, &out); err == nil || !strings.Contains(err.Error(), "reading the request") {
		t.Errorf("err = %v", err)
	}
	if err := run(strings.NewReader("\xff\xff\xff"), &out, &out); err == nil || !strings.Contains(err.Error(), "decoding") {
		t.Errorf("err = %v", err)
	}
}
