package gen

import (
	"bytes"
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/protobuf/types/pluginpb"

	"github.com/villagecompute/wiretuner/tools/protoc-gen-wtcrdt/internal/protoset"
)

// protoRoot is the repository's proto/ directory.
var protoRoot = filepath.Join("..", "..", "..", "..", "proto")

const fixtureName = "wiretuner/doc/v1/fixture.proto"

// fixture is a minimal document schema: the three roots plus the id types, and `extra`,
// which must define `message TestProps`.
func fixture(extra string) string {
	return `syntax = "proto3";
package wiretuner.doc.v1;
import "buf/validate/validate.proto";
import "wt/crdt/options.proto";
message OpId { uint64 counter = 1; fixed64 replica = 2; }
message ElementId { uint64 counter = 1; fixed64 replica = 2; }
message NodeRef { OpId id = 1; bytes cached = 2; }
message CommonProps { string name = 1; }
message Node { OpId id = 1; NodeProps props = 5; }
message NodeProps { oneof kind { TestProps test = 1; } }
` + extra
}

// request compiles extra into a CodeGeneratorRequest with parameter.
func request(t *testing.T, extra, parameter string, more map[string]string) *pluginpb.CodeGeneratorRequest {
	t.Helper()
	overlay := map[string]string{fixtureName: fixture(extra)}
	names := []string{fixtureName}
	for name, src := range more {
		overlay[name] = src
		names = append(names, name)
	}
	files, err := protoset.Compile(protoRoot, overlay, names)
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	req, err := protoset.Request(files, parameter)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	return req
}

// generate runs Generate over extra and returns the outputs by base name.
func generate(t *testing.T, extra string) (map[string]string, string) {
	t.Helper()
	var warn bytes.Buffer
	outs, err := Generate(request(t, extra, "swift_out=s,java_out=j", nil), &warn)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	byName := map[string]string{}
	for _, o := range outs {
		byName[filepath.Base(o.Name)] = string(o.Content)
	}
	return byName, warn.String()
}

// generateErr runs Generate over extra and returns its error, failing if there is none.
func generateErr(t *testing.T, extra string) string {
	t.Helper()
	_, err := Generate(request(t, extra, "swift_out=s", nil), nil)
	if err == nil {
		t.Fatalf("generate succeeded; want an error")
	}
	return err.Error()
}

// table builds the merge table of extra.
func table(t *testing.T, extra string) *Table {
	t.Helper()
	plugin, err := newPlugin(request(t, extra, "swift_out=s", nil))
	if err != nil {
		t.Fatal(err)
	}
	tbl, err := BuildTable(plugin, nil)
	if err != nil {
		t.Fatalf("BuildTable: %v", err)
	}
	return tbl
}

func field(t *testing.T, tbl *Table, message string, number int32) Field {
	t.Helper()
	m, ok := tbl.Messages["wiretuner.doc.v1."+message]
	if !ok {
		t.Fatalf("message %s not in table; have %v", message, tbl.MessageNames())
	}
	for _, f := range m.Fields {
		if f.Number == number {
			return f
		}
	}
	t.Fatalf("%s has no field %d", message, number)
	return Field{}
}

func mustContain(t *testing.T, haystack string, needles ...string) {
	t.Helper()
	for _, n := range needles {
		if !strings.Contains(haystack, n) {
			t.Errorf("output lacks %q", n)
		}
	}
	if t.Failed() {
		t.Logf("output:\n%s", haystack)
	}
}

func mustNotContain(t *testing.T, haystack string, needles ...string) {
	t.Helper()
	for _, n := range needles {
		if strings.Contains(haystack, n) {
			t.Errorf("output unexpectedly has %q", n)
		}
	}
}

// validatorFor returns the Swift validate function of one fixture message.
func validatorFor(t *testing.T, swift, message string) string {
	t.Helper()
	start := strings.Index(swift, fmt.Sprintf("func validate(_ m: Wiretuner_Doc_V1_%s,", message))
	if start < 0 {
		t.Fatalf("no validator for %s in:\n%s", message, swift)
	}
	end := strings.Index(swift[start:], "\n    }\n")
	return swift[start : start+end]
}
