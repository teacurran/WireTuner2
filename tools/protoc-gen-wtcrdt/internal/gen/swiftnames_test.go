package gen

import (
	"testing"

	"google.golang.org/protobuf/reflect/protoreflect"

	"github.com/villagecompute/wiretuner/tools/protoc-gen-wtcrdt/internal/protoset"
)

func TestSwiftCamel(t *testing.T) {
	cases := map[string][2]string{ // proto name: lower, upper
		"document_id":   {"documentID", "DocumentID"},
		"url":           {"url", "URL"},
		"go_to_page":    {"goToPage", "GoToPage"},
		"avatar_sha256": {"avatarSha256", "AvatarSha256"},
		"http_url":      {"httpURL", "HTTPURL"},
		"wall_time_ms":  {"wallTimeMs", "WallTimeMs"},
		"fooBar":        {"fooBar", "FooBar"},
		"HTTPServer":    {"httpserver", "Httpserver"},
		"trailing_":     {"trailing_", "Trailing_"},
		"double__under": {"double_Under", "Double_Under"},
		"2d_point":      {"_2DPoint", "_2DPoint"},
		"x":             {"x", "X"},
	}
	for in, want := range cases {
		if got := swiftLowerCamel(in); got != want[0] {
			t.Errorf("lower(%q) = %q, want %q", in, got, want[0])
		}
		if got := swiftUpperCamel(in); got != want[1] {
			t.Errorf("upper(%q) = %q, want %q", in, got, want[1])
		}
	}
}

func TestSwiftSanitize(t *testing.T) {
	cases := map[[2]string]string{
		{"hasPassword", "hasPassword"}: "hasPassword_p",
		{"clearCache", "clearCache"}:   "clearCache_p",
		{"description", "description"}: "description_p",
		{"in", "in"}:                   "`in`",
		{"hasIn", "in"}:                "hasIn",
		{"override", "override"}:       "override",
		{"_", "_"}:                     "___",
		{"plain", "plain"}:             "plain",
	}
	for in, want := range cases {
		if got := sanitizeSwiftFieldName(in[0], in[1]); got != want {
			t.Errorf("sanitize(%q, %q) = %q, want %q", in[0], in[1], got, want)
		}
	}
	if got := sanitizeSwiftTypeName("Type", "Message"); got != "TypeMessage" {
		t.Errorf("got %s", got)
	}
	if got := sanitizeSwiftTypeName("TypeMessage", "Message"); got != "TypeMessageMessage" {
		t.Errorf("got %s", got)
	}
	if got := sanitizeSwiftTypeName("__", "Enum"); got != "__Enum" {
		t.Errorf("got %s", got)
	}
}

func compileOne(t *testing.T, name, src string) protoreflect.FileDescriptor {
	t.Helper()
	files, err := protoset.Compile("", map[string]string{name: src}, []string{name})
	if err != nil {
		t.Fatal(err)
	}
	return files[0]
}

func TestSwiftTypeNames(t *testing.T) {
	f := compileOne(t, "a.proto", `syntax = "proto3"; package my_pkg.sub.v1;
message Outer { message Type { string has_x = 1; } oneof the_choice { string a = 2; } Type t = 3; optional int32 o = 4; }`)
	outer := f.Messages().Get(0)
	if got := swiftMessageName(outer); got != "MyPkg_Sub_V1_Outer" {
		t.Errorf("got %s", got)
	}
	inner := outer.Messages().Get(0)
	if got := swiftMessageName(inner); got != "MyPkg_Sub_V1_Outer.TypeMessage" {
		t.Errorf("got %s", got)
	}
	if got := swiftFieldName(inner.Fields().Get(0)); got != "hasX_p" {
		t.Errorf("got %s", got)
	}
	od := outer.Oneofs().Get(0)
	if got := swiftOneofName(od); got != "theChoice" {
		t.Errorf("got %s", got)
	}
	if got := swiftOneofTypeName(od); got != "MyPkg_Sub_V1_Outer.OneOf_TheChoice" {
		t.Errorf("got %s", got)
	}
	if got := swiftHasName(outer.Fields().ByName("o")); got != "hasO" {
		t.Errorf("got %s", got)
	}

	withPrefix := compileOne(t, "b.proto", `syntax = "proto3"; package p.v1; option swift_prefix = "WT"; message M {}`)
	if got := swiftMessageName(withPrefix.Messages().Get(0)); got != "WTM" {
		t.Errorf("got %s", got)
	}
	blankPrefix := compileOne(t, "c.proto", `syntax = "proto3"; package p.v1; option swift_prefix = ""; message M {}`)
	if got := swiftMessageName(blankPrefix.Messages().Get(0)); got != "M" {
		t.Errorf("got %s", got)
	}
	noPackage := compileOne(t, "d.proto", `syntax = "proto3"; message M {}`)
	if got := swiftMessageName(noPackage.Messages().Get(0)); got != "M" {
		t.Errorf("got %s", got)
	}
	digit := compileOne(t, "e.proto", `syntax = "proto3"; package _9lives; message M {}`)
	if got := swiftMessageName(digit.Messages().Get(0)); got != "_9lives_M" {
		t.Errorf("got %s", got)
	}
}
