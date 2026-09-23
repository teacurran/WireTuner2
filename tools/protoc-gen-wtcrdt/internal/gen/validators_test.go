package gen

import (
	"strings"
	"testing"
)

// v is a violation line as emitted for a field path under `path`.
func v(field, rule string) string {
	return `out.append(ValidationViolation(fieldPath: "\(path)` + field + `", ruleID: "` + rule + `"`
}

func validatorSource(t *testing.T, message, extra string) (string, map[string]string) {
	t.Helper()
	outs, _ := generate(t, extra)
	return validatorFor(t, outs["Validators.swift"], message), outs
}

func TestRequired(t *testing.T) {
	src, _ := validatorSource(t, "TestProps", `
message Inner { double x = 1; }
message TestProps {
  Inner msg = 1 [(buf.validate.field).required = true];
  string s = 2 [(buf.validate.field).required = true];
  uint64 n = 3 [(buf.validate.field).required = true];
  bool b = 4 [(buf.validate.field).required = true];
  bytes raw = 5 [(buf.validate.field).required = true];
  repeated string list = 6 [(buf.validate.field).required = true];
  map<string, string> dict = 7 [(buf.validate.field).required = true, (wt.crdt.field).merge = MERGE_ATOMIC];
  optional int32 opt = 8 [(buf.validate.field).required = true];
  oneof pick { string a = 9 [(buf.validate.field).required = true]; }
  Shade shade = 10 [(buf.validate.field).required = true];
}
enum Shade { SHADE_UNSPECIFIED = 0; }`)
	mustContain(t, src,
		"if !m.hasMsg {\n            "+v("msg", "required"),
		"if m.s.isEmpty {\n            "+v("s", "required"),
		"if m.n == 0 {\n            "+v("n", "required"),
		"if !m.b {\n            "+v("b", "required"),
		"if m.raw.isEmpty {\n            "+v("raw", "required"),
		"if m.list.isEmpty {\n            "+v("list", "required"),
		"if m.dict.isEmpty {\n            "+v("dict", "required"),
		"if !m.hasOpt {\n            "+v("opt", "required"),
		"if case .a(_)? = m.pick {\n        } else {\n            "+v("a", "required"),
		"if m.shade.rawValue == 0 {\n            "+v("shade", "required"),
	)
}

func TestOneofRequired(t *testing.T) {
	src, _ := validatorSource(t, "TestProps", `
message TestProps {
  oneof pick {
    option (buf.validate.oneof).required = true;
    string a = 1;
    double b = 2;
  }
  oneof free { string c = 3; }
}`)
	mustContain(t, src, "if m.pick == nil {\n            "+v("pick", "required"))
	mustNotContain(t, src, "m.free == nil")
}

func TestNumericRules(t *testing.T) {
	src, _ := validatorSource(t, "TestProps", `
message TestProps {
  double a = 1 [(buf.validate.field).double.gt = 0];
  float b = 2 [(buf.validate.field).float.gte = 0.5];
  int32 c = 3 [(buf.validate.field).int32.lt = 10];
  int64 d = 4 [(buf.validate.field).int64.lte = -1];
  uint32 e = 5 [(buf.validate.field).uint32 = { gte: 1, lte: 536870911 }];
  uint64 f = 6 [(buf.validate.field).uint64 = { gt: 1, lt: 5 }];
  sint32 g = 7 [(buf.validate.field).sint32 = { gt: 10, lt: 5 }];
  sint64 h = 8 [(buf.validate.field).sint64.gte = -3];
  fixed32 i = 9 [(buf.validate.field).fixed32.lte = 7];
  fixed64 j = 10 [(buf.validate.field).fixed64.gt = 0];
  sfixed32 k = 11 [(buf.validate.field).sfixed32.lt = 0];
  sfixed64 l = 12 [(buf.validate.field).sfixed64.gte = 2];
  double m = 13 [(buf.validate.field).double = { gte: 0, lte: 1e6 }];
}`)
	mustContain(t, src,
		"let v = m.a\n            if !(v > 0) {\n                "+v("a", "double.gt"),
		"if !(v >= 0.5) {\n                "+v("b", "float.gte"),
		"if !(v < 10) {\n                "+v("c", "int32.lt"),
		"if !(v <= -1) {\n                "+v("d", "int64.lte"),
		"if !(v >= 1 && v <= 536870911) {\n                "+v("e", "uint32.gte_lte"),
		`message: "value must be greater than or equal to 1 and less than or equal to 536870911"`,
		"if !(v > 1 && v < 5) {\n                "+v("f", "uint64.gt_lt"),
		"if !(v > 10 || v < 5) {\n                "+v("g", "sint32.gt_lt_exclusive"),
		`message: "value must be greater than 10 or less than 5"`,
		"if !(v >= -3) {\n                "+v("h", "sint64.gte"),
		"if !(v <= 7) {\n                "+v("i", "fixed32.lte"),
		"if !(v > 0) {\n                "+v("j", "fixed64.gt"),
		"if !(v < 0) {\n                "+v("k", "sfixed32.lt"),
		"if !(v >= 2) {\n                "+v("l", "sfixed64.gte"),
		"if !(v >= 0 && v <= 1e+06) {\n                "+v("m", "double.gte_lte"),
	)
}

func TestStringRules(t *testing.T) {
	src, outs := validatorSource(t, "TestProps", `
message TestProps {
  string a = 1 [(buf.validate.field).string = { min_len: 1, max_len: 256 }];
  string b = 2 [(buf.validate.field).string.len = 4];
  string c = 3 [(buf.validate.field).string = { min_bytes: 2, max_bytes: 65536 }];
  string d = 4 [(buf.validate.field).string.len_bytes = 8];
  string e = 5 [(buf.validate.field).string.pattern = "^[a-z]+(\\.[a-z]+)*$"];
  string f = 6 [(buf.validate.field).string.uuid = true];
  string g = 7 [(buf.validate.field).string.pattern = "^[a-z]+(\\.[a-z]+)*$"];
}`)
	mustContain(t, src,
		"if v.unicodeScalars.count < 1 {\n                "+v("a", "string.min_len"),
		"if v.unicodeScalars.count > 256 {\n                "+v("a", "string.max_len"),
		"if v.unicodeScalars.count != 4 {\n                "+v("b", "string.len"),
		"if v.utf8.count < 2 {\n                "+v("c", "string.min_bytes"),
		"if v.utf8.count > 65536 {\n                "+v("c", "string.max_bytes"),
		"if v.utf8.count != 8 {\n                "+v("d", "string.len_bytes"),
		"if v.firstMatch(of: Self.pattern0) == nil {\n                "+v("e", "string.pattern"),
		"if v.isEmpty {\n                "+v("f", "string.uuid_empty"),
		"} else if v.wholeMatch(of: Self.pattern1) == nil {\n                "+v("f", "string.uuid"),
		// the same pattern is compiled once
		"if v.firstMatch(of: Self.pattern0) == nil {\n                "+v("g", "string.pattern"),
	)
	mustContain(t, outs["Validators.swift"],
		`nonisolated(unsafe) private static let pattern0 = try! Regex(#"^[a-z]+(\.[a-z]+)*$"#)`,
		`nonisolated(unsafe) private static let pattern1 = try! Regex(#"`+uuidPattern+`"#)`)
	mustNotContain(t, outs["Validators.swift"], "pattern2")
}

func TestBadPatternFails(t *testing.T) {
	msg := generateErr(t, `message TestProps { string a = 1 [(buf.validate.field).string.pattern = "(["]; }`)
	mustContain(t, msg, `wiretuner.doc.v1.TestProps.a: pattern "([" does not compile`)
}

func TestRawStringDelimiters(t *testing.T) {
	if got := swiftRawString(`a"#b`); got != `##"a"#b"##` {
		t.Errorf("got %s", got)
	}
	if got := swiftRawString(`plain`); got != `#"plain"#` {
		t.Errorf("got %s", got)
	}
}

func TestBytesRules(t *testing.T) {
	src, _ := validatorSource(t, "TestProps", `
message TestProps {
  bytes a = 1 [(buf.validate.field).bytes.len = 32];
  bytes b = 2 [(buf.validate.field).bytes = { min_len: 1, max_len: 1024 }];
}`)
	mustContain(t, src,
		"if v.count != 32 {\n                "+v("a", "bytes.len"),
		"if v.count < 1 {\n                "+v("b", "bytes.min_len"),
		"if v.count > 1024 {\n                "+v("b", "bytes.max_len"),
	)
}

func TestEnumRules(t *testing.T) {
	src, _ := validatorSource(t, "TestProps", `
enum Shade { SHADE_UNSPECIFIED = 0; SHADE_A = 1; SHADE_B = 2; }
message TestProps {
  Shade a = 1 [(buf.validate.field).enum.defined_only = true];
  Shade b = 2 [(buf.validate.field).enum = { in: [1, 2] }];
  Shade c = 3 [(buf.validate.field).enum = { not_in: [0] }];
}`)
	mustContain(t, src,
		"if case .UNRECOGNIZED = v {\n                "+v("a", "enum.defined_only"),
		"if ![1, 2].contains(v.rawValue) {\n                "+v("b", "enum.in"),
		"if [0].contains(v.rawValue) {\n                "+v("c", "enum.not_in"),
	)
}

func TestRepeatedRules(t *testing.T) {
	src, _ := validatorSource(t, "TestProps", `
message Item { string s = 1 [(buf.validate.field).string.max_len = 3]; }
message TestProps {
  repeated Item items = 1 [(buf.validate.field).repeated = { min_items: 1, max_items: 32 }, (wt.crdt.field).merge = MERGE_ATOMIC];
  repeated string names = 2 [(buf.validate.field).repeated = { max_items: 8, items: { string: { max_len: 64 } } }];
  repeated bytes blobs = 3 [(buf.validate.field).repeated.items = { ignore: IGNORE_IF_ZERO_VALUE, bytes: { len: 4 } }];
  repeated string opt = 4 [(buf.validate.field) = { ignore: IGNORE_IF_ZERO_VALUE, repeated: { min_items: 2 } }];
}`)
	mustContain(t, src,
		"if m.items.count < 1 {\n            "+v("items", "repeated.min_items"),
		"if m.items.count > 32 {\n            "+v("items", "repeated.max_items"),
		"for (i, v) in m.items.enumerated() {\n            out += validate(v, path: \"\\(path)items[\\(i)].\")",
		"if m.names.count > 8 {\n            "+v("names", "repeated.max_items"),
		"for (i, v) in m.names.enumerated() {\n            if v.unicodeScalars.count > 64 {\n                "+v(`names[\(i)]`, "string.max_len"),
		"for (i, v) in m.blobs.enumerated() {\n            if !(v.isEmpty) {\n                if v.count != 4 {",
		"if !m.opt.isEmpty {\n            if m.opt.count < 2 {",
	)
}

func TestMapRules(t *testing.T) {
	src, _ := validatorSource(t, "TestProps", `
message Val { string s = 1 [(buf.validate.field).required = true]; }
message TestProps {
  map<string, Val> values = 1 [(buf.validate.field).map = {
    min_pairs: 1
    max_pairs: 512
    keys: { string: { min_len: 3 } }
  }, (wt.crdt.field).merge = MERGE_ATOMIC];
  map<bool, string> flags = 2 [(buf.validate.field).map.values = { string: { max_len: 2 } }, (wt.crdt.field).merge = MERGE_ATOMIC];
  map<int32, int32> counts = 3 [(buf.validate.field).map.keys = { int32: { gt: 0 } }, (wt.crdt.field).merge = MERGE_ATOMIC];
}`)
	mustContain(t, src,
		"if m.values.count < 1 {\n            "+v("values", "map.min_pairs"),
		"if m.values.count > 512 {\n            "+v("values", "map.max_pairs"),
		"for (k, v) in m.values.sorted(by: { $0.key < $1.key }) {\n            if k.unicodeScalars.count < 3 {\n                "+v(`values[\(String(reflecting: k))]`, "string.min_len"),
		`out += validate(v, path: "\(path)values[\(String(reflecting: k))].")`,
		"for (k, v) in m.flags.sorted(by: { !$0.key && $1.key }) {\n            if v.unicodeScalars.count > 2 {",
		"for (k, _) in m.counts.sorted(by: { $0.key < $1.key }) {\n            if !(k > 0) {",
	)
}

func TestIgnore(t *testing.T) {
	src, _ := validatorSource(t, "TestProps", `
message Inner { string s = 1 [(buf.validate.field).required = true]; }
message TestProps {
  string a = 1 [(buf.validate.field).string.uuid = true, (buf.validate.field).ignore = IGNORE_IF_ZERO_VALUE];
  string b = 2 [(buf.validate.field).string.max_len = 1, (buf.validate.field).ignore = IGNORE_ALWAYS];
  Inner c = 3 [(buf.validate.field).ignore = IGNORE_ALWAYS];
  Inner d = 4;
  optional double e = 5 [(buf.validate.field).double.gt = 0];
  oneof pick { Inner f = 6; double g = 7 [(buf.validate.field).double.lt = 1]; string h = 8; }
}`)
	mustContain(t, src,
		"if !(m.a.isEmpty) {\n            let v = m.a",
		"if m.hasD {\n            let v = m.d\n            out += validate(v, path: \"\\(path)d.\")",
		"if m.hasE {\n            let v = m.e\n            if !(v > 0) {",
		"if case .f(let v)? = m.pick {\n            out += validate(v, path: \"\\(path)f.\")",
		"if case .g(let v)? = m.pick {\n            if !(v < 1) {",
	)
	mustNotContain(t, src, "m.b", "m.c", "m.hasC", ".h(")
}

func TestSkippedRules(t *testing.T) {
	outs, _ := generate(t, `
message TestProps {
  option (buf.validate.message).cel = { id: "props.pair", message: "m", expression: "this.a != this.b" };
  string a = 1 [(buf.validate.field).cel = { id: "a.len", expression: "size(this) < 3" }];
  string b = 2 [(buf.validate.field).string.email = true];
  repeated string c = 3 [(buf.validate.field).repeated = { unique: true, items: { cel: { id: "c.item", expression: "this != 'x'" } } }];
  double d = 4 [(buf.validate.field).double = { const: 1, finite: true }];
  bool e = 5 [(buf.validate.field).bool.const = true];
  string f = 6 [(buf.validate.field).string = { prefix: "wt|", hostname: true }];
}`)
	md := outs["SkippedRules.md"]
	mustContain(t, md,
		"## CEL expressions (server only)",
		"| `wiretuner.doc.v1.TestProps` | `(message)` | `(buf.validate.message).cel` | `props.pair: this.a != this.b` |",
		"| `wiretuner.doc.v1.TestProps` | `a` | `(buf.validate.field).cel` | `a.len: size(this) < 3` |",
		"| `wiretuner.doc.v1.TestProps` | `c` | `items.cel` | `c.item: this != 'x'` |",
		"## Standard rules without a generated Swift check",
		"| `wiretuner.doc.v1.TestProps` | `b` | `string.email` | `true` |",
		"| `wiretuner.doc.v1.TestProps` | `c` | `repeated.unique` | `true` |",
		"| `wiretuner.doc.v1.TestProps` | `d` | `double.const` | `1` |",
		"| `wiretuner.doc.v1.TestProps` | `d` | `double.finite` | `true` |",
		"| `wiretuner.doc.v1.TestProps` | `e` | `bool.const` | `true` |",
		"| `wiretuner.doc.v1.TestProps` | `f` | `string.prefix` | `wt\\|` |",
	)
	none, _ := generate(t, `message TestProps { double x = 1; }`)
	mustContain(t, none["SkippedRules.md"], "## CEL expressions (server only)\n\nNone.\n", "## Standard rules without a generated Swift check\n\nNone.\n")
}

func TestValidatorRootsAndRecursion(t *testing.T) {
	service := map[string]string{"wiretuner/svc/v1/svc.proto": `syntax = "proto3";
package wiretuner.svc.v1;
import "buf/validate/validate.proto";
import "wiretuner/doc/v1/fixture.proto";
service S { rpc Do(DoRequest) returns (DoResponse); }
message DoRequest { Wrapper w = 1; string plain = 2; }
message Wrapper { wiretuner.doc.v1.Node node = 1; }
message DoResponse { string s = 1 [(buf.validate.field).string.max_len = 1]; }
message Unused { string s = 1 [(buf.validate.field).string.max_len = 1]; }
`}
	outs, err := Generate(request(t, `message TestProps { string s = 1 [(buf.validate.field).string.max_len = 2]; }
message Quiet { double x = 1; }`, "swift_out=s", service), nil)
	if err != nil {
		t.Fatal(err)
	}
	var swift string
	for _, o := range outs {
		if strings.HasSuffix(o.Name, "Validators.swift") {
			swift = string(o.Content)
		}
	}
	mustContain(t, swift,
		// every doc message, even one without rules
		"public static func validate(_ m: Wiretuner_Doc_V1_Quiet, path: String = \"\") -> [ValidationViolation] {\n        return []\n    }",
		// the service request, recursing through Wrapper to Node to NodeProps to TestProps
		"func validate(_ m: Wiretuner_Svc_V1_DoRequest,",
		"func validate(_ m: Wiretuner_Svc_V1_Wrapper,",
		"if case .test(let v)? = m.kind {\n            out += validate(v, path: \"\\(path)test.\")",
	)
	// responses and unreferenced messages outside the doc package are not roots
	mustNotContain(t, swift, "Wiretuner_Svc_V1_DoResponse", "Wiretuner_Svc_V1_Unused")
}
