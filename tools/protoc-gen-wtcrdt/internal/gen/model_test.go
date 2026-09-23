package gen

import (
	"bytes"
	"strings"
	"testing"
)

func TestDefaults(t *testing.T) {
	tbl := table(t, `
message Inner { double x = 1; }
enum Shade { SHADE_UNSPECIFIED = 0; }
message TestProps {
  CommonProps common = 1;
  double width = 2;
  string label = 3;
  bytes blob = 4;
  Shade shade = 5;
  repeated uint32 tags = 6;
  Inner inner = 7;
  optional bool flag = 8;
  oneof choice { string a = 9; Inner b = 10; }
}`)
	for number, want := range map[int32]Policy{2: PolicyAtomic, 3: PolicyAtomic, 4: PolicyAtomic, 5: PolicyAtomic,
		6: PolicyAtomic, 7: PolicyStruct, 8: PolicyAtomic, 9: PolicyAtomic, 10: PolicyStruct, 1: PolicyStruct} {
		f := field(t, tbl, "TestProps", number)
		if f.Policy != want || f.Explicit {
			t.Errorf("field %d (%s): policy %s explicit %v, want default %s", number, f.Name, f.Policy, f.Explicit, want)
		}
	}
	if f := field(t, tbl, "TestProps", 10); f.Oneof != "choice" || f.TypeName != "wiretuner.doc.v1.Inner" {
		t.Errorf("oneof member: %+v", f)
	}
	if f := field(t, tbl, "TestProps", 6); !f.Repeated || f.Type != "uint32" {
		t.Errorf("repeated scalar: %+v", f)
	}
	// Everything reachable is covered: the fixture roots, the kind message, nested messages.
	for _, name := range []string{"Node", "NodeProps", "CommonProps", "OpId", "TestProps", "Inner"} {
		if _, ok := tbl.Messages["wiretuner.doc.v1."+name]; !ok {
			t.Errorf("%s missing from the table", name)
		}
	}
}

func TestExplicitPolicies(t *testing.T) {
	tbl := table(t, `
message Point { double x = 1; double y = 2; }
message Stop { ElementId id = 1; double offset = 2; }
message RichText { repeated uint32 chars = 1; }
enum FillKind { FILL_KIND_UNSPECIFIED = 0; FILL_KIND_SOLID = 1; }
message Solid { double opacity = 1; }
message Fill { FillKind kind = 1; Solid solid = 2; double shared = 3; Solid gradient = 4; }
message TestProps {
  CommonProps common = 1;
  Point at = 2 [(wt.crdt.field).merge = MERGE_ATOMIC];
  Point grid = 3 [(wt.crdt.field).merge = MERGE_STRUCT];
  repeated Stop stops = 4 [(wt.crdt.field).merge = MERGE_SEQUENCE];
  RichText text = 5 [(wt.crdt.field).merge = MERGE_TEXT];
  repeated string keywords = 6 [(wt.crdt.field).merge = MERGE_SET];
  repeated ElementId members = 7 [(wt.crdt.field).merge = MERGE_SET];
  repeated OpId nodes = 8 [(wt.crdt.field).merge = MERGE_SET];
  Fill fill = 9 [(wt.crdt.field).merge = MERGE_VARIANT];
  NodeRef swatch = 10 [(wt.crdt.field) = { on_dangling: REF_FALLBACK_CACHED }];
  NodeRef symbol = 11 [(wt.crdt.field).on_dangling = REF_FALLBACK_PLACEHOLDER];
  double zoom = 12 [(wt.crdt.field).local_only = true];
  repeated Point outline = 13 [(wt.crdt.field).merge = MERGE_ATOMIC];
}`)
	want := map[int32]Policy{2: PolicyAtomic, 3: PolicyStruct, 4: PolicySequence, 5: PolicyText, 6: PolicySet,
		7: PolicySet, 8: PolicySet, 9: PolicyVariant, 13: PolicyAtomic}
	for number, policy := range want {
		if f := field(t, tbl, "TestProps", number); f.Policy != policy || !f.Explicit {
			t.Errorf("field %d: %s explicit=%v, want explicit %s", number, f.Policy, f.Explicit, policy)
		}
	}
	if f := field(t, tbl, "TestProps", 4); f.ElementMessage != "wiretuner.doc.v1.Stop" {
		t.Errorf("sequence element: %q", f.ElementMessage)
	}
	if f := field(t, tbl, "TestProps", 10); f.OnDangling != FallbackCached || f.Policy != PolicyStruct {
		t.Errorf("swatch: %+v", f)
	}
	if f := field(t, tbl, "TestProps", 11); f.OnDangling != FallbackPlaceholder {
		t.Errorf("symbol: %+v", f)
	}
	if f := field(t, tbl, "TestProps", 12); !f.LocalOnly || f.Policy != PolicyAtomic {
		t.Errorf("zoom: %+v", f)
	}
	if f := field(t, tbl, "TestProps", 2); f.OnDangling != FallbackUnset {
		t.Errorf("default on_dangling: %s", f.OnDangling)
	}
	v, ok := tbl.Variants["wiretuner.doc.v1.Fill"]
	if !ok || v.KindField != 1 || len(v.CaseFields) != 2 || v.CaseFields[0] != 2 || v.CaseFields[1] != 4 {
		t.Errorf("variant: %+v", v)
	}
	// Elements of a sequence are walked like any other message.
	if f := field(t, tbl, "Stop", 1); f.TypeName != elementIDName {
		t.Errorf("Stop.id: %+v", f)
	}
}

func TestSequenceWithoutElementIDFails(t *testing.T) {
	cases := map[string]string{
		"no field 1": `message Stop { double offset = 2; }
message TestProps { repeated Stop stops = 2 [(wt.crdt.field).merge = MERGE_SEQUENCE]; }`,
		"field 1 wrong name": `message Stop { ElementId key = 1; }
message TestProps { repeated Stop stops = 2 [(wt.crdt.field).merge = MERGE_SEQUENCE]; }`,
		"field 1 wrong type": `message Stop { OpId id = 1; }
message TestProps { repeated Stop stops = 2 [(wt.crdt.field).merge = MERGE_SEQUENCE]; }`,
		"field 1 scalar": `message Stop { uint64 id = 1; }
message TestProps { repeated Stop stops = 2 [(wt.crdt.field).merge = MERGE_SEQUENCE]; }`,
	}
	for name, extra := range cases {
		t.Run(name, func(t *testing.T) {
			msg := generateErr(t, extra)
			mustContain(t, msg, "wiretuner.doc.v1.TestProps.stops: MERGE_SEQUENCE requires a repeated message whose field 1 is `wiretuner.doc.v1.ElementId id`")
		})
	}
	msg := generateErr(t, `message TestProps { ElementId one = 2 [(wt.crdt.field).merge = MERGE_SEQUENCE]; }`)
	mustContain(t, msg, "TestProps.one: MERGE_SEQUENCE requires a repeated message field", "this field is `wiretuner.doc.v1.ElementId`")
}

func TestPolicyShapeErrors(t *testing.T) {
	cases := map[string]struct{ extra, want string }{
		"text on string": {`message TestProps { string t = 2 [(wt.crdt.field).merge = MERGE_TEXT]; }`,
			"TestProps.t: MERGE_TEXT requires a singular RichText field; this field is `string`"},
		"text on other message": {`message Other { string s = 1; }
message TestProps { Other t = 2 [(wt.crdt.field).merge = MERGE_TEXT]; }`,
			"TestProps.t: MERGE_TEXT requires a singular RichText field"},
		"set on singular": {`message TestProps { string s = 2 [(wt.crdt.field).merge = MERGE_SET]; }`,
			"TestProps.s: MERGE_SET requires a repeated scalar or a repeated"},
		"set on message": {`message Other { string s = 1; }
message TestProps { repeated Other s = 2 [(wt.crdt.field).merge = MERGE_SET]; }`,
			"TestProps.s: MERGE_SET requires a repeated scalar"},
		"set on map": {`message TestProps { map<string, string> s = 2 [(wt.crdt.field).merge = MERGE_SET]; }`,
			"TestProps.s: MERGE_SET requires"},
		"variant without kind": {`message V { double a = 1; }
message TestProps { V v = 2 [(wt.crdt.field).merge = MERGE_VARIANT]; }`,
			"TestProps.v: MERGE_VARIANT requires a message with an enum field named `kind`; wiretuner.doc.v1.V has no field named `kind`"},
		"variant kind not enum": {`message V { string kind = 1; }
message TestProps { V v = 2 [(wt.crdt.field).merge = MERGE_VARIANT]; }`,
			"wiretuner.doc.v1.V.kind is `string`, not an enum"},
		"variant on scalar": {`message TestProps { double v = 2 [(wt.crdt.field).merge = MERGE_VARIANT]; }`,
			"TestProps.v: MERGE_VARIANT requires a singular message field"},
		"struct on scalar": {`message TestProps { double v = 2 [(wt.crdt.field).merge = MERGE_STRUCT]; }`,
			"TestProps.v: MERGE_STRUCT requires a singular message field; this field is `double`"},
		"repeated message unannotated": {`message Other { string s = 1; }
message TestProps { repeated Other items = 2; }`,
			"TestProps.items: a repeated message field has no default merge policy"},
		"map unannotated": {`message TestProps { map<string, double> m = 2; }`,
			"TestProps.m: a map field has no default merge policy"},
		"on_dangling off a NodeRef": {`message TestProps { OpId r = 2 [(wt.crdt.field).on_dangling = REF_FALLBACK_CACHED]; }`,
			"TestProps.r: on_dangling is only meaningful on a wiretuner.doc.v1.NodeRef field"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) { mustContain(t, generateErr(t, c.extra), c.want) })
	}
}

func TestAllProblemsReportedTogether(t *testing.T) {
	msg := generateErr(t, `message Stop { double offset = 1; }
message TestProps {
  repeated Stop a = 2 [(wt.crdt.field).merge = MERGE_SEQUENCE];
  double b = 3 [(wt.crdt.field).merge = MERGE_STRUCT];
}`)
	if lines := strings.Split(msg, "\n"); len(lines) != 2 {
		t.Errorf("want 2 problems, got %d:\n%s", len(lines), msg)
	}
}

func TestRichTextAbsentWarns(t *testing.T) {
	_, warn := generate(t, `message TestProps { double x = 1; }`)
	mustContain(t, warn, "warning: no message wiretuner.doc.v1.RichText exists yet")
	_, warn = generate(t, `message RichText { string s = 1; }
message TestProps { RichText t = 1 [(wt.crdt.field).merge = MERGE_TEXT]; }`)
	if warn != "" {
		t.Errorf("unexpected warning %q", warn)
	}
}

func TestMissingRootFails(t *testing.T) {
	req := request(t, `message TestProps {}`, "swift_out=s", map[string]string{
		"other/v1/x.proto": `syntax = "proto3"; package other.v1; message X {}`,
	})
	// Drop the fixture so no root remains.
	req.ProtoFile = req.ProtoFile[len(req.ProtoFile)-1:]
	req.FileToGenerate = []string{"other/v1/x.proto"}
	_, err := Generate(req, nil)
	if err == nil || !strings.Contains(err.Error(), "root message wiretuner.doc.v1.NodeProps is not in the request") {
		t.Fatalf("err = %v", err)
	}
}

func TestParamErrorsSurface(t *testing.T) {
	if _, err := Generate(request(t, `message TestProps {}`, "", nil), nil); err == nil {
		t.Fatal("empty parameter accepted")
	}
	resp := Response(request(t, `message TestProps { double v = 2 [(wt.crdt.field).merge = MERGE_STRUCT]; }`, "swift_out=s", nil), nil)
	if !strings.HasPrefix(resp.GetError(), "protoc-gen-wtcrdt: ") || len(resp.GetFile()) != 0 {
		t.Errorf("response: %v", resp)
	}
	resp = Response(request(t, `message TestProps {}`, "java_out=j,java_package=a.b", nil), nil)
	if resp.GetError() != "" || len(resp.GetFile()) != 2 || resp.GetFile()[0].GetName() != "j/a/b/MergeTable.java" {
		t.Errorf("response: %v", resp)
	}
}

func TestDeterministicAndVersioned(t *testing.T) {
	extra := `message Point { double x = 1; }
message TestProps { CommonProps common = 1; Point a = 2; Point b = 3; double c = 4; }`
	first, _ := generate(t, extra)
	for i := 0; i < 5; i++ {
		again, _ := generate(t, extra)
		for name, content := range first {
			if again[name] != content {
				t.Fatalf("%s differs between runs", name)
			}
		}
	}
	changed := table(t, strings.Replace(extra, "Point b = 3;", "Point b = 3 [(wt.crdt.field).merge = MERGE_ATOMIC];", 1))
	if changed.Version() == table(t, extra).Version() {
		t.Error("version did not change with a policy change")
	}
	if !strings.Contains(first["MergeTable.swift"], table(t, extra).Version()) ||
		!strings.Contains(first["MergeTable.java"], table(t, extra).Version()) {
		t.Error("emitted sources do not carry the version")
	}
	if !bytes.Equal([]byte(first["MergeTable.json"]), []byte(first["merge-table.json"])) {
		t.Error("Swift and Java JSON resources differ")
	}
}
