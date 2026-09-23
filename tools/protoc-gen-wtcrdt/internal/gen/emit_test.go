package gen

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
)

const emitFixture = `
message Stop { ElementId id = 1; double offset = 2; }
enum FillKind { FILL_KIND_UNSPECIFIED = 0; }
message Solid { double opacity = 1; }
message Fill { FillKind kind = 1; Solid solid = 2; }
message TestProps {
  CommonProps common = 1;
  repeated Stop stops = 2 [(wt.crdt.field).merge = MERGE_SEQUENCE];
  NodeRef swatch = 3 [(wt.crdt.field).on_dangling = REF_FALLBACK_CACHED];
  double zoom = 4 [(wt.crdt.field).local_only = true];
  Fill fill = 5 [(wt.crdt.field).merge = MERGE_VARIANT];
}`

func TestJSONSchemaAndVersion(t *testing.T) {
	outs, _ := generate(t, emitFixture)
	var doc struct {
		Version  string `json:"version"`
		Messages map[string]struct {
			Fields map[string]map[string]any `json:"fields"`
		} `json:"messages"`
		Variants map[string]struct {
			KindField  int   `json:"kind_field"`
			CaseFields []int `json:"case_fields"`
		} `json:"variants"`
	}
	if err := json.Unmarshal([]byte(outs["MergeTable.json"]), &doc); err != nil {
		t.Fatal(err)
	}
	stops := doc.Messages["wiretuner.doc.v1.TestProps"].Fields["2"]
	if stops["policy"] != "SEQUENCE" || stops["element_message"] != "wiretuner.doc.v1.Stop" || stops["repeated"] != true || stops["name"] != "stops" {
		t.Errorf("stops row: %v", stops)
	}
	if row := doc.Messages["wiretuner.doc.v1.TestProps"].Fields["3"]; row["on_dangling"] != "CACHED" || row["type_name"] != "wiretuner.doc.v1.NodeRef" {
		t.Errorf("swatch row: %v", row)
	}
	if row := doc.Messages["wiretuner.doc.v1.TestProps"].Fields["4"]; row["local_only"] != true || row["type_name"] != nil || row["oneof"] != nil {
		t.Errorf("zoom row: %v", row)
	}
	if row := doc.Messages["wiretuner.doc.v1.NodeProps"].Fields["1"]; row["oneof"] != "kind" {
		t.Errorf("NodeProps.test row: %v", row)
	}
	if v := doc.Variants["wiretuner.doc.v1.Fill"]; v.KindField != 1 || len(v.CaseFields) != 1 || v.CaseFields[0] != 2 {
		t.Errorf("variant: %+v", v)
	}

	// version = SHA-256 of the compact JSON with the version key removed, keys sorted.
	var generic map[string]any
	_ = json.Unmarshal([]byte(outs["MergeTable.json"]), &generic)
	delete(generic, "version")
	var canonicalBuf strings.Builder
	enc := json.NewEncoder(&canonicalBuf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(generic) // encoding/json sorts map keys
	canonical := []byte(strings.TrimSuffix(canonicalBuf.String(), "\n"))
	sum := sha256.Sum256(canonical)
	if hex.EncodeToString(sum[:]) != doc.Version {
		t.Errorf("version %s is not the hash of the canonical document", doc.Version)
	}
}

func TestSwiftMergeTable(t *testing.T) {
	outs, _ := generate(t, emitFixture)
	swift := outs["MergeTable.swift"]
	mustContain(t, swift,
		"public enum WTMergeTable {",
		`"wiretuner.doc.v1.TestProps": wiretuner_doc_v1_TestProps,`,
		`fieldNumber: 2, name: "stops", policy: .sequence, onDangling: .unset,`,
		`elementMessage: "wiretuner.doc.v1.Stop", oneof: nil`,
		`fieldNumber: 3, name: "swatch", policy: .atomic, onDangling: .cached,`,
		`localOnly: true, type: "double", repeated: false, typeName: nil,`,
		`fieldNumber: 5, name: "fill", policy: .variant,`,
		`"wiretuner.doc.v1.Fill": VariantPolicy(kindField: 1, caseFields: [2]),`,
		`oneof: "kind"`,
		`public static let json: String = #"""`,
	)
	if !strings.Contains(swift, outs["MergeTable.json"]) {
		t.Error("MergeTable.swift does not embed the JSON document verbatim")
	}
	// Every policy and fallback has a Swift case.
	for _, p := range AllPolicies {
		mustContain(t, swift, "case "+swiftPolicyCase[p]+` = "`+string(p)+`"`)
	}
	for _, f := range AllFallbacks {
		mustContain(t, swift, "case "+swiftFallbackCase[f]+` = "`+string(f)+`"`)
	}

	noVariants, _ := generate(t, `message TestProps { double x = 1; }`)
	mustContain(t, noVariants["MergeTable.swift"], "public static let variants: [String: VariantPolicy] = [\n        :\n    ]")
}

func TestJavaMergeTable(t *testing.T) {
	outs, _ := generate(t, emitFixture)
	java := outs["MergeTable.java"]
	mustContain(t, java,
		"package com.villagecompute.wiretuner.crdt.schema;",
		"public final class MergeTable {",
		`Map.entry("wiretuner.doc.v1.TestProps", table_wiretuner_doc_v1_TestProps())`,
		`Map.entry(2, new FieldPolicy(2, "stops", Policy.SEQUENCE, RefFallback.UNSET, false, "message", true, "wiretuner.doc.v1.Stop", "wiretuner.doc.v1.Stop", null))`,
		`Map.entry(3, new FieldPolicy(3, "swatch", Policy.ATOMIC, RefFallback.CACHED,`,
		`Map.entry(4, new FieldPolicy(4, "zoom", Policy.ATOMIC, RefFallback.UNSET, true, "double", false, null, null, null))`,
		`Map.entry("wiretuner.doc.v1.Fill", new VariantPolicy(1, List.of(2)))`,
		`public static final String RESOURCE = "merge-table.json";`,
	)
	if outs["merge-table.json"] != outs["MergeTable.json"] {
		t.Error("Java resource differs from the Swift JSON")
	}
}

func TestParseParams(t *testing.T) {
	p, err := ParseParams("swift_out=a/,java_out=b, java_package=x.y ,Mfoo.proto=bar,paths=source_relative,module=m")
	if err != nil || p.SwiftOut != "a" || p.JavaOut != "b" || p.JavaPackage != "x.y" {
		t.Errorf("got %+v, %v", p, err)
	}
	p, err = ParseParams("swift_out=s")
	if err != nil || p.JavaPackage != DefaultJavaPackage || p.JavaOut != "" {
		t.Errorf("got %+v, %v", p, err)
	}
	for _, bad := range []string{"", "  ", "swift_out", "colour=red", "java_package=", "java_package=a.b", ",,"} {
		if _, err := ParseParams(bad); err == nil {
			t.Errorf("ParseParams(%q) accepted", bad)
		}
	}
}
