package gen

import (
	"strings"

	"google.golang.org/protobuf/reflect/protoreflect"
)

// The naming rules of protoc-gen-swift (swift-protobuf's SwiftProtobufPluginLibrary/
// NamingUtils.swift and SwiftProtobufNamer.swift), reproduced so the validators address the
// same properties the committed WTProto code declares.  Compiling WTCRDTSchema is the check
// that they still agree.

var swiftKeywordsUsedInDeclarations = set("associatedtype", "class", "deinit", "enum",
	"extension", "fileprivate", "func", "import", "init", "inout", "internal", "let", "open",
	"operator", "private", "protocol", "public", "static", "struct", "subscript", "typealias",
	"var")

var swiftKeywordsUsedInStatements = set("break", "case", "continue", "default", "defer", "do",
	"else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where",
	"while")

var swiftKeywordsUsedInExpressionsAndTypes = set("as", "Any", "catch", "false", "is", "nil",
	"rethrows", "super", "self", "Self", "throw", "throws", "true", "try")

var swiftCommonTypes = set("Bool", "Data", "Double", "Float", "Int", "String", "UInt")

var swiftSpecialVariables = set("__COLUMN__", "__FILE__", "__FUNCTION__", "__LINE__")

// quotableFieldNames can be used as property names inside backticks.
var quotableFieldNames = union(swiftKeywordsUsedInDeclarations, swiftKeywordsUsedInStatements,
	swiftKeywordsUsedInExpressionsAndTypes)

// reservedFieldNames get a `_p` suffix.
var reservedFieldNames = union(set("isInitialized", "unknownFields", "debugDescription",
	"description", "dynamicType", "hashValue", "init", "self", "Type", "Protocol"),
	swiftCommonTypes, swiftSpecialVariables)

// reservedTypeNames get a disambiguating suffix ("Message", "Enum", "Oneof").
var reservedTypeNames = union(set("SwiftProtobuf", "Extensions", "protoMessageName",
	"decodeMessage", "traverse", "isInitialized", "unknownFields", "debugDescription",
	"description", "dynamicType", "hashValue", "Type", "Protocol", "Swift", "Equatable",
	"Hashable", "Sendable"), swiftKeywordsUsedInDeclarations, swiftKeywordsUsedInStatements,
	swiftKeywordsUsedInExpressionsAndTypes, swiftCommonTypes, swiftSpecialVariables)

var camelAbbreviations = set("url", "http", "https", "id")

func set(items ...string) map[string]bool {
	m := make(map[string]bool, len(items))
	for _, s := range items {
		m[s] = true
	}
	return m
}

func union(sets ...map[string]bool) map[string]bool {
	m := map[string]bool{}
	for _, s := range sets {
		for k := range s {
			m[k] = true
		}
	}
	return m
}

// swiftTypePrefix is the `Package_Segments_` prefix protoc-gen-swift puts on every top-level
// type of a file: the `swift_prefix` option when set, else the proto package with each
// dot-separated segment UpperCamelCased and joined by underscores.
func swiftTypePrefix(file protoreflect.FileDescriptor) string {
	if opts, ok := file.Options().(interface{ GetSwiftPrefix() string }); ok {
		if p := opts.GetSwiftPrefix(); p != "" || hasSwiftPrefix(file) {
			return p
		}
	}
	pkg := string(file.Package())
	if pkg == "" {
		return ""
	}
	var prefix strings.Builder
	makeUpper := true
	for i := 0; i < len(pkg); i++ {
		c := pkg[i]
		switch {
		case c == '_':
			makeUpper = true
		case c == '.':
			makeUpper = true
			prefix.WriteByte('_')
		default:
			if prefix.Len() == 0 && c >= '0' && c <= '9' {
				prefix.WriteByte('_')
			}
			if makeUpper {
				prefix.WriteByte(asciiUpper(c))
				makeUpper = false
			} else {
				prefix.WriteByte(c)
			}
		}
	}
	prefix.WriteByte('_')
	return prefix.String()
}

func hasSwiftPrefix(file protoreflect.FileDescriptor) bool {
	opts := file.Options()
	if opts == nil {
		return false
	}
	m := opts.ProtoReflect()
	fd := m.Descriptor().Fields().ByName("swift_prefix")
	return fd != nil && m.Has(fd)
}

// swiftMessageName is the fully qualified Swift type of a message: the file prefix, then the
// nesting chain joined with dots (`Wiretuner_Doc_V1_Outer.Inner`).
func swiftMessageName(md protoreflect.MessageDescriptor) string {
	var chain []string
	for d := protoreflect.Descriptor(md); d != nil; d = d.Parent() {
		if _, isFile := d.(protoreflect.FileDescriptor); isFile {
			break
		}
		chain = append([]string{sanitizeSwiftTypeName(string(d.Name()), "Message")}, chain...)
	}
	return swiftTypePrefix(md.ParentFile()) + strings.Join(chain, ".")
}

func sanitizeSwiftTypeName(s, disambiguator string) string {
	switch {
	case reservedTypeNames[s]:
		return s + disambiguator
	case isAllUnderscore(s):
		return s + disambiguator
	case strings.HasSuffix(s, disambiguator) && len(s) > len(disambiguator):
		return sanitizeSwiftTypeName(strings.TrimSuffix(s, disambiguator), disambiguator) + disambiguator
	}
	return s
}

// swiftFieldName is the property protoc-gen-swift declares for a field (or the case name of a
// oneof member, which uses the same rule).
func swiftFieldName(fd protoreflect.FieldDescriptor) string {
	lower := swiftLowerCamel(string(fd.Name()))
	return sanitizeSwiftFieldName(lower, lower)
}

// swiftHasName is the `hasFoo` presence property of a singular message or `optional` field.
func swiftHasName(fd protoreflect.FieldDescriptor) string {
	lower := swiftLowerCamel(string(fd.Name()))
	return sanitizeSwiftFieldName("has"+swiftUpperCamel(string(fd.Name())), lower)
}

// swiftOneofName is the property holding a oneof's case (`components`).
func swiftOneofName(od protoreflect.OneofDescriptor) string {
	lower := swiftLowerCamel(string(od.Name()))
	return sanitizeSwiftFieldName(lower, lower)
}

// swiftOneofTypeName is the nested enum type of a oneof (`Wiretuner_Doc_V1_Color.OneOf_Components`).
func swiftOneofTypeName(od protoreflect.OneofDescriptor) string {
	parent := od.Parent().(protoreflect.MessageDescriptor)
	return swiftMessageName(parent) + "." + sanitizeSwiftTypeName("OneOf_"+swiftUpperCamel(string(od.Name())), "Oneof")
}

func sanitizeSwiftFieldName(s, basedOn string) string {
	switch {
	case strings.HasPrefix(basedOn, "clear") && isUpperAt(basedOn, 5):
		return s + "_p"
	case strings.HasPrefix(basedOn, "has") && isUpperAt(basedOn, 3):
		return s + "_p"
	case reservedFieldNames[basedOn]:
		return s + "_p"
	case basedOn == s && quotableFieldNames[basedOn]:
		return "`" + s + "`"
	case isAllUnderscore(basedOn):
		return s + "__"
	}
	return s
}

func isUpperAt(s string, i int) bool {
	return len(s) > i && s[i] >= 'A' && s[i] <= 'Z'
}

func isAllUnderscore(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] != '_' {
			return false
		}
	}
	return true
}

func asciiUpper(c byte) byte {
	if c >= 'a' && c <= 'z' {
		return c - 'a' + 'A'
	}
	return c
}

func asciiLower(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c - 'A' + 'a'
	}
	return c
}

func swiftLowerCamel(s string) string { return swiftCamel(s, false) }
func swiftUpperCamel(s string) string { return swiftCamel(s, true) }

type charClass int

const (
	classNone charClass = iota
	classDigit
	classLower
	classUpper
	classUnderscore
	classOther
)

func classify(c byte) charClass {
	switch {
	case c >= '0' && c <= '9':
		return classDigit
	case c >= 'a' && c <= 'z':
		return classLower
	case c >= 'A' && c <= 'Z':
		return classUpper
	case c == '_':
		return classUnderscore
	}
	return classOther
}

// swiftCamel is swift-protobuf's CamelCaser.transform: segments split on underscores, case
// changes and digit runs; each segment capitalised (abbreviations `url`, `http`, `https`, `id`
// fully upper-cased) except a leading lower-case one; extra underscores carried over.
// Proto identifiers are ASCII so the `other` class never occurs here.
func swiftCamel(s string, initialUpper bool) string {
	var result strings.Builder
	var current []byte
	last := classNone
	addCurrent := func() {
		if len(current) == 0 {
			return
		}
		seg := string(current)
		switch {
		case result.Len() == 0 && !initialUpper:
			// stays lower-case
		case camelAbbreviations[seg]:
			seg = strings.ToUpper(seg)
		default:
			seg = string(asciiUpper(seg[0])) + seg[1:]
		}
		result.WriteString(seg)
		current = current[:0]
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		class := classify(c)
		switch class {
		case classDigit:
			if last != classDigit {
				addCurrent()
			}
			if result.Len() == 0 {
				result.WriteByte('_')
			}
			current = append(current, c)
		case classUpper:
			if last != classUpper {
				addCurrent()
			}
			current = append(current, asciiLower(c))
		case classLower:
			if last != classLower && last != classUpper {
				addCurrent()
			}
			current = append(current, c)
		case classUnderscore:
			addCurrent()
			if last == classUnderscore {
				result.WriteByte('_')
			}
		default:
			addCurrent()
			current = append(current, c)
		}
		last = class
	}
	addCurrent()
	if last == classUnderscore {
		result.WriteByte('_')
	}
	return result.String()
}
