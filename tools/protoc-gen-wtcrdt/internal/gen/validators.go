package gen

import (
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"

	validate "buf.build/gen/go/bufbuild/protovalidate/protocolbuffers/go/buf/validate"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
)

// Swift validators for the standard protovalidate rules (docs/spec/api-conventions.adoc,
// "Validation").  The client has no CEL interpreter, so CEL expressions -- and the few standard
// rules below that have no generated check -- are listed in SkippedRules.md instead; the server
// enforces every rule with protovalidate-java.
//
// Semantics follow protovalidate: a field that tracks presence (message, `optional`, oneof
// member) is checked only when set, and `required` means set; an implicit-presence scalar is
// always checked, `required` means non-zero, and IGNORE_IF_ZERO_VALUE skips a zero value;
// repeated and map fields treat "empty" as zero.  Nested messages are validated recursively.

// SkippedRule is one rule the Swift validators do not check.
type SkippedRule struct {
	// Kind is "cel" for a CEL expression (server-only by design) or "standard" for a standard
	// rule this generator has no Swift check for.
	Kind    string
	Message string
	// Field is the field (or oneof) name; "" for a message-level rule.
	Field  string
	Rule   string
	Detail string
}

// supported standard rules per rule-type message; `example` is documentation only.
var supportedRules = map[string]map[string]bool{
	"string":   set("min_len", "max_len", "len", "min_bytes", "max_bytes", "len_bytes", "pattern", "uuid", "example"),
	"bytes":    set("len", "min_len", "max_len", "example"),
	"enum":     set("defined_only", "in", "not_in", "example"),
	"repeated": set("min_items", "max_items", "items"),
	"map":      set("min_pairs", "max_pairs", "keys", "values"),
}

var numericRuleTypes = set("float", "double", "int32", "int64", "uint32", "uint64", "sint32",
	"sint64", "fixed32", "fixed64", "sfixed32", "sfixed64")

func init() {
	for t := range numericRuleTypes {
		supportedRules[t] = set("gt", "gte", "lt", "lte", "example")
	}
}

const uuidPattern = `^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`

var validatorPackage = regexp.MustCompile(`^wiretuner\.[a-z0-9_]+\.v1$`)

func fieldRules(fd protoreflect.FieldDescriptor) *validate.FieldRules {
	opts, ok := fd.Options().(*descriptorpb.FieldOptions)
	if !ok || opts == nil || !proto.HasExtension(opts, validate.E_Field) {
		return nil
	}
	fr, _ := proto.GetExtension(opts, validate.E_Field).(*validate.FieldRules)
	return fr
}

func oneofRequired(od protoreflect.OneofDescriptor) bool {
	opts, ok := od.Options().(*descriptorpb.OneofOptions)
	if !ok || opts == nil || !proto.HasExtension(opts, validate.E_Oneof) {
		return false
	}
	r, _ := proto.GetExtension(opts, validate.E_Oneof).(*validate.OneofRules)
	return r.GetRequired()
}

func messageRules(md protoreflect.MessageDescriptor) *validate.MessageRules {
	opts, ok := md.Options().(*descriptorpb.MessageOptions)
	if !ok || opts == nil || !proto.HasExtension(opts, validate.E_Message) {
		return nil
	}
	r, _ := proto.GetExtension(opts, validate.E_Message).(*validate.MessageRules)
	return r
}

// typedRules returns the name ("string", "double", ...) and message of the set `type` case.
func typedRules(fr *validate.FieldRules) (string, protoreflect.Message) {
	if fr == nil {
		return "", nil
	}
	m := fr.ProtoReflect()
	od := m.Descriptor().Oneofs().ByName("type")
	fd := m.WhichOneof(od)
	if fd == nil {
		return "", nil
	}
	return string(fd.Name()), m.Get(fd).Message()
}

// ValidatorRoots are the request messages of every wiretuner.*.v1 service and every message of
// the document schema, sorted by name.
func ValidatorRoots(files []protoreflect.FileDescriptor) []protoreflect.MessageDescriptor {
	seen := map[protoreflect.FullName]protoreflect.MessageDescriptor{}
	for _, f := range files {
		pkg := string(f.Package())
		if !validatorPackage.MatchString(pkg) {
			continue
		}
		svcs := f.Services()
		for i := 0; i < svcs.Len(); i++ {
			methods := svcs.Get(i).Methods()
			for j := 0; j < methods.Len(); j++ {
				in := methods.Get(j).Input()
				seen[in.FullName()] = in
			}
		}
		if pkg == docPackage {
			var walk func(protoreflect.MessageDescriptors)
			walk = func(ms protoreflect.MessageDescriptors) {
				for i := 0; i < ms.Len(); i++ {
					md := ms.Get(i)
					if md.IsMapEntry() {
						continue
					}
					seen[md.FullName()] = md
					walk(md.Messages())
				}
			}
			walk(f.Messages())
		}
	}
	return sortedMessages(seen)
}

func sortedMessages(m map[protoreflect.FullName]protoreflect.MessageDescriptor) []protoreflect.MessageDescriptor {
	out := make([]protoreflect.MessageDescriptor, 0, len(m))
	for _, md := range m {
		out = append(out, md)
	}
	sort.Slice(out, func(a, b int) bool { return out[a].FullName() < out[b].FullName() })
	return out
}

// inWTProto reports whether a message's Swift type is generated into WTProto (everything but
// the well-known types and the protovalidate schema).
func inWTProto(md protoreflect.MessageDescriptor) bool {
	pkg := string(md.ParentFile().Package())
	return !strings.HasPrefix(pkg, "google.") && !strings.HasPrefix(pkg, "buf.")
}

// fieldMessage is the message a field's validation may recurse into: the field's own type, a
// map's value type, or nil.
func fieldMessage(fd protoreflect.FieldDescriptor) protoreflect.MessageDescriptor {
	if fd.IsMap() {
		return fd.MapValue().Message()
	}
	return fd.Message()
}

type validatorGen struct {
	needs    map[protoreflect.FullName]bool
	skipped  []SkippedRule
	patterns []string
	errs     []string
}

// ValidatorOutput is what EmitSwiftValidators produces.
type ValidatorOutput struct {
	Swift   []byte
	Skipped []SkippedRule
}

// EmitSwiftValidators renders Validators.swift for the roots and every message they reach that
// has rules.
func EmitSwiftValidators(roots []protoreflect.MessageDescriptor) (ValidatorOutput, error) {
	g := &validatorGen{needs: map[protoreflect.FullName]bool{}}

	// The closure of messages reachable from the roots.
	closure := map[protoreflect.FullName]protoreflect.MessageDescriptor{}
	queue := append([]protoreflect.MessageDescriptor{}, roots...)
	for len(queue) > 0 {
		md := queue[0]
		queue = queue[1:]
		if _, ok := closure[md.FullName()]; ok || !inWTProto(md) || md.IsMapEntry() {
			continue
		}
		closure[md.FullName()] = md
		fields := md.Fields()
		for i := 0; i < fields.Len(); i++ {
			if m := fieldMessage(fields.Get(i)); m != nil {
				queue = append(queue, m)
			}
		}
	}
	all := sortedMessages(closure)

	// needs: a message with a rule of its own, or a field leading to one.
	for _, md := range all {
		g.needs[md.FullName()] = hasDirectRules(md)
	}
	for changed := true; changed; {
		changed = false
		for _, md := range all {
			if g.needs[md.FullName()] {
				continue
			}
			fields := md.Fields()
			for i := 0; i < fields.Len(); i++ {
				fd := fields.Get(i)
				if fieldRules(fd).GetIgnore() == validate.Ignore_IGNORE_ALWAYS {
					continue
				}
				if m := fieldMessage(fd); m != nil && g.needs[m.FullName()] {
					g.needs[md.FullName()] = true
					changed = true
					break
				}
			}
		}
	}

	rootSet := map[protoreflect.FullName]bool{}
	for _, r := range roots {
		rootSet[r.FullName()] = true
	}
	var funcs strings.Builder
	for _, md := range all {
		if !rootSet[md.FullName()] && !g.needs[md.FullName()] {
			continue
		}
		funcs.WriteString(g.messageFunc(md))
	}
	if len(g.errs) > 0 {
		sort.Strings(g.errs)
		return ValidatorOutput{}, fmt.Errorf("%s", strings.Join(g.errs, "\n"))
	}

	var b strings.Builder
	b.WriteString(generatedHeader)
	b.WriteString(`// swiftlint:disable all

import Foundation
import WTProto

/// One failed rule: the field path from the validated message (` + "`ops[3].create.position`" + `), the
/// protovalidate rule id and a human-readable message.
public struct ValidationViolation: Sendable, Hashable, CustomStringConvertible {
    public let fieldPath: String
    public let ruleID: String
    public let message: String

    public init(fieldPath: String, ruleID: String, message: String) {
        self.fieldPath = fieldPath
        self.ruleID = ruleID
        self.message = message
    }

    public var description: String { "\(fieldPath): \(message) [\(ruleID)]" }
}

/// Client-side checks of the standard protovalidate rules (docs/spec/api-conventions.adoc,
/// "Validation").  ` + "`WTModel`" + ` runs them before a change enters the outbox.  CEL expressions and
/// the standard rules listed in SkippedRules.md are enforced by the server only.
public enum WTValidators {
`)
	for i, p := range g.patterns {
		fmt.Fprintf(&b, "    nonisolated(unsafe) private static let pattern%d = try! Regex(%s)\n", i, swiftRawString(p))
	}
	if len(g.patterns) > 0 {
		b.WriteString("\n")
	}
	b.WriteString(strings.TrimSuffix(funcs.String(), "\n"))
	b.WriteString("\n}\n")

	sort.Slice(g.skipped, func(a, c int) bool {
		x, y := g.skipped[a], g.skipped[c]
		if x.Kind != y.Kind {
			return x.Kind < y.Kind
		}
		if x.Message != y.Message {
			return x.Message < y.Message
		}
		if x.Field != y.Field {
			return x.Field < y.Field
		}
		return x.Rule < y.Rule
	})
	return ValidatorOutput{Swift: []byte(b.String()), Skipped: g.skipped}, nil
}

func hasDirectRules(md protoreflect.MessageDescriptor) bool {
	fields := md.Fields()
	for i := 0; i < fields.Len(); i++ {
		fr := fieldRules(fields.Get(i))
		if fr == nil || fr.GetIgnore() == validate.Ignore_IGNORE_ALWAYS {
			continue
		}
		if fr.GetRequired() || fr.HasType() {
			return true
		}
	}
	oneofs := md.Oneofs()
	for i := 0; i < oneofs.Len(); i++ {
		if oneofRequired(oneofs.Get(i)) {
			return true
		}
	}
	return false
}

// swiftRawString renders s as a Swift raw string literal with enough `#`s.
func swiftRawString(s string) string {
	hashes := "#"
	for strings.Contains(s, "\""+hashes) {
		hashes += "#"
	}
	return hashes + "\"" + s + "\"" + hashes
}

func (g *validatorGen) pattern(p string) string {
	for i, q := range g.patterns {
		if q == p {
			return fmt.Sprintf("Self.pattern%d", i)
		}
	}
	g.patterns = append(g.patterns, p)
	return fmt.Sprintf("Self.pattern%d", len(g.patterns)-1)
}

func (g *validatorGen) skip(kind string, md protoreflect.MessageDescriptor, field, rule, detail string) {
	g.skipped = append(g.skipped, SkippedRule{Kind: kind, Message: string(md.FullName()), Field: field, Rule: rule, Detail: detail})
}

func celDetail(r *validate.Rule) string {
	d := r.GetExpression()
	if r.GetId() != "" {
		d = r.GetId() + ": " + d
	}
	return d
}

func violation(path, rule, message string) string {
	return fmt.Sprintf("out.append(ValidationViolation(fieldPath: %s, ruleID: %s, message: %s))", path, strconv.Quote(rule), strconv.Quote(message))
}

func indent(lines []string, by string) []string {
	out := make([]string, len(lines))
	for i, l := range lines {
		if l == "" {
			out[i] = l
		} else {
			out[i] = by + l
		}
	}
	return out
}

func (g *validatorGen) messageFunc(md protoreflect.MessageDescriptor) string {
	var lines []string
	if mr := messageRules(md); mr != nil {
		for _, r := range mr.GetCel() {
			g.skip("cel", md, "", "(buf.validate.message).cel", celDetail(r))
		}
		for _, e := range mr.GetCelExpression() {
			g.skip("cel", md, "", "(buf.validate.message).cel_expression", e)
		}
		for _, o := range mr.GetOneof() {
			g.skip("standard", md, "", "(buf.validate.message).oneof", strings.Join(o.GetFields(), ", "))
		}
	}
	oneofs := md.Oneofs()
	for i := 0; i < oneofs.Len(); i++ {
		od := oneofs.Get(i)
		if od.IsSynthetic() || !oneofRequired(od) {
			continue
		}
		lines = append(lines, fmt.Sprintf("if m.%s == nil {", swiftOneofName(od)),
			"    "+violation(fmt.Sprintf(`"\(path)%s"`, od.Name()), "required", "exactly one field is required in oneof"),
			"}")
	}
	fields := md.Fields()
	for i := 0; i < fields.Len(); i++ {
		lines = append(lines, g.fieldLines(md, fields.Get(i))...)
	}

	var b strings.Builder
	fmt.Fprintf(&b, "    /// Validates `%s`; `path` prefixes every violation's field path.\n", md.FullName())
	fmt.Fprintf(&b, "    public static func validate(_ m: %s, path: String = \"\") -> [ValidationViolation] {\n", swiftMessageName(md))
	if len(lines) == 0 {
		b.WriteString("        return []\n    }\n\n")
		return b.String()
	}
	b.WriteString("        var out: [ValidationViolation] = []\n")
	for _, l := range indent(lines, "        ") {
		b.WriteString(l + "\n")
	}
	b.WriteString("        return out\n    }\n\n")
	return b.String()
}

// zeroExpr is a Swift boolean expression that is true when val is the kind's zero value.
func zeroExpr(fd protoreflect.FieldDescriptor, val string) string {
	switch fd.Kind() {
	case protoreflect.StringKind, protoreflect.BytesKind:
		return val + ".isEmpty"
	case protoreflect.BoolKind:
		return "!" + val
	case protoreflect.EnumKind:
		return val + ".rawValue == 0"
	}
	return val + " == 0"
}

func (g *validatorGen) fieldLines(md protoreflect.MessageDescriptor, fd protoreflect.FieldDescriptor) []string {
	fr := fieldRules(fd)
	if fr.GetIgnore() == validate.Ignore_IGNORE_ALWAYS {
		return nil
	}
	name := string(fd.Name())
	prop := "m." + swiftFieldName(fd)
	path := fmt.Sprintf(`"\(path)%s"`, name)
	for _, r := range fr.GetCel() {
		g.skip("cel", md, name, "(buf.validate.field).cel", celDetail(r))
	}
	for _, e := range fr.GetCelExpression() {
		g.skip("cel", md, name, "(buf.validate.field).cel_expression", e)
	}
	ignoreZero := fr.GetIgnore() == validate.Ignore_IGNORE_IF_ZERO_VALUE
	required := fr.GetRequired()

	switch {
	case fd.IsMap():
		return g.mapLines(md, fd, fr, prop, path, required, ignoreZero)
	case fd.Cardinality() == protoreflect.Repeated:
		return g.repeatedLines(md, fd, fr, prop, path, required, ignoreZero)
	}

	checks := g.valueChecks(md, fd, fr, "v", path, name)
	if od := fd.ContainingOneof(); od != nil && !od.IsSynthetic() {
		caseName := swiftFieldName(fd)
		if len(checks) == 0 && !required {
			return nil
		}
		binding := fmt.Sprintf(".%s(let v)?", caseName)
		if len(checks) == 0 {
			binding = fmt.Sprintf(".%s(_)?", caseName)
		}
		out := []string{fmt.Sprintf("if case %s = m.%s {", binding, swiftOneofName(od))}
		out = append(out, indent(checks, "    ")...)
		if required {
			out = append(out, "} else {", "    "+violation(path, "required", "value is required"))
		}
		return append(out, "}")
	}
	if fd.HasPresence() {
		if len(checks) == 0 && !required {
			return nil
		}
		var out []string
		if len(checks) == 0 {
			out = []string{fmt.Sprintf("if !m.%s {", swiftHasName(fd)), "    " + violation(path, "required", "value is required"), "}"}
			return out
		}
		out = []string{fmt.Sprintf("if m.%s {", swiftHasName(fd)), fmt.Sprintf("    let v = %s", prop)}
		out = append(out, indent(checks, "    ")...)
		if required {
			out = append(out, "} else {", "    "+violation(path, "required", "value is required"))
		}
		return append(out, "}")
	}

	// Implicit presence: checked always, zero is "unset".
	var out []string
	if required {
		out = append(out, fmt.Sprintf("if %s {", zeroExpr(fd, prop)), "    "+violation(path, "required", "value is required"), "}")
	}
	if len(checks) == 0 {
		return out
	}
	body := append([]string{fmt.Sprintf("let v = %s", prop)}, checks...)
	if ignoreZero {
		out = append(out, fmt.Sprintf("if !(%s) {", zeroExpr(fd, prop)))
		out = append(out, indent(body, "    ")...)
		return append(out, "}")
	}
	out = append(out, "do {")
	out = append(out, indent(body, "    ")...)
	return append(out, "}")
}

// valueChecks are the checks of one value `val` of fd's element kind: nested validation for a
// message, the typed rules otherwise.
func (g *validatorGen) valueChecks(md protoreflect.MessageDescriptor, fd protoreflect.FieldDescriptor, fr *validate.FieldRules, val, path, name string) []string {
	var out []string
	if msg := fd.Message(); msg != nil && !fd.IsMap() {
		if g.needs[msg.FullName()] && inWTProto(msg) {
			out = append(out, fmt.Sprintf("out += validate(%s, path: %s)", val, strings.TrimSuffix(path, `"`)+`."`))
		}
	}
	typ, rules := typedRules(fr)
	if rules == nil {
		return out
	}
	return append(out, g.typedChecks(md, fd, typ, rules, val, path, name)...)
}

func (g *validatorGen) typedChecks(md protoreflect.MessageDescriptor, fd protoreflect.FieldDescriptor, typ string, rules protoreflect.Message, val, path, name string) []string {
	supported := supportedRules[typ]
	var names []string
	rules.Range(func(f protoreflect.FieldDescriptor, _ protoreflect.Value) bool {
		names = append(names, string(f.Name()))
		return true
	})
	sort.Strings(names)
	for _, n := range names {
		if !supported[n] {
			g.skip("standard", md, name, typ+"."+n, formatRuleValue(rules, n))
		}
	}
	get := func(n string) (protoreflect.Value, bool) {
		f := rules.Descriptor().Fields().ByName(protoreflect.Name(n))
		if f == nil || !rules.Has(f) {
			return protoreflect.Value{}, false
		}
		return rules.Get(f), true
	}

	var out []string
	switch {
	case numericRuleTypes[typ]:
		out = append(out, numericChecks(typ, get, val, path)...)
	case typ == "string":
		lengths := []struct{ rule, expr, cmp, what string }{
			{"len", val + ".unicodeScalars.count", "!=", "value length must be %s characters"},
			{"min_len", val + ".unicodeScalars.count", "<", "value length must be at least %s characters"},
			{"max_len", val + ".unicodeScalars.count", ">", "value length must be at most %s characters"},
			{"len_bytes", val + ".utf8.count", "!=", "value length must be %s bytes"},
			{"min_bytes", val + ".utf8.count", "<", "value length must be at least %s bytes"},
			{"max_bytes", val + ".utf8.count", ">", "value length must be at most %s bytes"},
		}
		for _, l := range lengths {
			if v, ok := get(l.rule); ok {
				n := strconv.FormatUint(v.Uint(), 10)
				out = append(out, fmt.Sprintf("if %s %s %s {", l.expr, l.cmp, n), "    "+violation(path, "string."+l.rule, fmt.Sprintf(l.what, n)), "}")
			}
		}
		if v, ok := get("pattern"); ok {
			p := v.String()
			if _, err := regexp.Compile(p); err != nil {
				g.errs = append(g.errs, fmt.Sprintf("%s: pattern %q does not compile: %v", fd.FullName(), p, err))
			}
			out = append(out, fmt.Sprintf("if %s.firstMatch(of: %s) == nil {", val, g.pattern(p)),
				"    "+violation(path, "string.pattern", fmt.Sprintf("value does not match regex pattern `%s`", p)), "}")
		}
		if v, ok := get("uuid"); ok && v.Bool() {
			out = append(out, fmt.Sprintf("if %s.isEmpty {", val),
				"    "+violation(path, "string.uuid_empty", "value is empty, which is not a valid UUID"),
				fmt.Sprintf("} else if %s.wholeMatch(of: %s) == nil {", val, g.pattern(uuidPattern)),
				"    "+violation(path, "string.uuid", "value must be a valid UUID"), "}")
		}
	case typ == "bytes":
		lengths := []struct{ rule, cmp, what string }{
			{"len", "!=", "value length must be %s bytes"},
			{"min_len", "<", "value length must be at least %s bytes"},
			{"max_len", ">", "value length must be at most %s bytes"},
		}
		for _, l := range lengths {
			if v, ok := get(l.rule); ok {
				n := strconv.FormatUint(v.Uint(), 10)
				out = append(out, fmt.Sprintf("if %s.count %s %s {", val, l.cmp, n), "    "+violation(path, "bytes."+l.rule, fmt.Sprintf(l.what, n)), "}")
			}
		}
	case typ == "enum":
		if v, ok := get("defined_only"); ok && v.Bool() {
			out = append(out, fmt.Sprintf("if case .UNRECOGNIZED = %s {", val), "    "+violation(path, "enum.defined_only", "value must be one of the defined enum values"), "}")
		}
		for _, rule := range []string{"in", "not_in"} {
			v, ok := get(rule)
			if !ok {
				continue
			}
			list := v.List()
			nums := make([]string, list.Len())
			for i := 0; i < list.Len(); i++ {
				nums[i] = strconv.FormatInt(list.Get(i).Int(), 10)
			}
			joined := strings.Join(nums, ", ")
			if rule == "in" {
				out = append(out, fmt.Sprintf("if ![%s].contains(%s.rawValue) {", joined, val), "    "+violation(path, "enum.in", "value must be in list ["+joined+"]"), "}")
			} else {
				out = append(out, fmt.Sprintf("if [%s].contains(%s.rawValue) {", joined, val), "    "+violation(path, "enum.not_in", "value must not be in list ["+joined+"]"), "}")
			}
		}
	}
	return out
}

func formatRuleValue(rules protoreflect.Message, n string) string {
	f := rules.Descriptor().Fields().ByName(protoreflect.Name(n))
	v := rules.Get(f)
	switch {
	case f.IsList():
		l := v.List()
		parts := make([]string, l.Len())
		for i := 0; i < l.Len(); i++ {
			parts[i] = fmt.Sprint(l.Get(i).Interface())
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case f.Message() != nil:
		return "{...}"
	}
	return fmt.Sprint(v.Interface())
}

// swiftNumber renders a bound as a Swift literal; ok is false for NaN and infinities.
func swiftNumber(typ string, v protoreflect.Value) (lit string, f float64, ok bool) {
	switch typ {
	case "float", "double":
		f = v.Float()
		if math.IsNaN(f) || math.IsInf(f, 0) {
			return "", f, false
		}
		if typ == "float" {
			return strconv.FormatFloat(f, 'g', -1, 32), f, true
		}
		return strconv.FormatFloat(f, 'g', -1, 64), f, true
	case "uint32", "uint64", "fixed32", "fixed64":
		return strconv.FormatUint(v.Uint(), 10), float64(v.Uint()), true
	}
	return strconv.FormatInt(v.Int(), 10), float64(v.Int()), true
}

func numericChecks(typ string, get func(string) (protoreflect.Value, bool), val, path string) []string {
	type bound struct {
		rule, op, words, lit string
		f                    float64
	}
	var lo, hi *bound
	for _, c := range []struct{ rule, op, words string }{{"gt", ">", "greater than"}, {"gte", ">=", "greater than or equal to"}} {
		if v, ok := get(c.rule); ok {
			if lit, f, ok := swiftNumber(typ, v); ok {
				lo = &bound{c.rule, c.op, c.words, lit, f}
			}
		}
	}
	for _, c := range []struct{ rule, op, words string }{{"lt", "<", "less than"}, {"lte", "<=", "less than or equal to"}} {
		if v, ok := get(c.rule); ok {
			if lit, f, ok := swiftNumber(typ, v); ok {
				hi = &bound{c.rule, c.op, c.words, lit, f}
			}
		}
	}
	// Negated so NaN fails every bound, as in protovalidate.
	switch {
	case lo != nil && hi != nil && lo.f > hi.f:
		// Exclusive range: the value must lie outside (hi, lo).
		return []string{fmt.Sprintf("if !(%s %s %s || %s %s %s) {", val, lo.op, lo.lit, val, hi.op, hi.lit),
			"    " + violation(path, typ+"."+lo.rule+"_"+hi.rule+"_exclusive", fmt.Sprintf("value must be %s %s or %s %s", lo.words, lo.lit, hi.words, hi.lit)), "}"}
	case lo != nil && hi != nil:
		return []string{fmt.Sprintf("if !(%s %s %s && %s %s %s) {", val, lo.op, lo.lit, val, hi.op, hi.lit),
			"    " + violation(path, typ+"."+lo.rule+"_"+hi.rule, fmt.Sprintf("value must be %s %s and %s %s", lo.words, lo.lit, hi.words, hi.lit)), "}"}
	case lo != nil:
		return []string{fmt.Sprintf("if !(%s %s %s) {", val, lo.op, lo.lit), "    " + violation(path, typ+"."+lo.rule, fmt.Sprintf("value must be %s %s", lo.words, lo.lit)), "}"}
	case hi != nil:
		return []string{fmt.Sprintf("if !(%s %s %s) {", val, hi.op, hi.lit), "    " + violation(path, typ+"."+hi.rule, fmt.Sprintf("value must be %s %s", hi.words, hi.lit)), "}"}
	}
	return nil
}

// elementLines are the checks of one element `v` of a repeated field (or one map key/value)
// under the element rules `items`.
func (g *validatorGen) elementLines(md protoreflect.MessageDescriptor, fd protoreflect.FieldDescriptor, items *validate.FieldRules, val, path, name string) []string {
	if items.GetIgnore() == validate.Ignore_IGNORE_ALWAYS {
		return nil
	}
	for _, r := range items.GetCel() {
		g.skip("cel", md, name, "items.cel", celDetail(r))
	}
	for _, e := range items.GetCelExpression() {
		g.skip("cel", md, name, "items.cel_expression", e)
	}
	if items.GetRequired() {
		g.skip("standard", md, name, "items.required", "true")
	}
	checks := g.valueChecks(md, fd, items, val, path, name)
	if len(checks) > 0 && items.GetIgnore() == validate.Ignore_IGNORE_IF_ZERO_VALUE && fd.Message() == nil {
		checks = append([]string{fmt.Sprintf("if !(%s) {", zeroExpr(fd, val))}, append(indent(checks, "    "), "}")...)
	}
	return checks
}

func (g *validatorGen) repeatedLines(md protoreflect.MessageDescriptor, fd protoreflect.FieldDescriptor, fr *validate.FieldRules, prop, path string, required, ignoreZero bool) []string {
	name := string(fd.Name())
	var body []string
	var items *validate.FieldRules
	if typ, rules := typedRules(fr); rules != nil {
		if typ != "repeated" {
			g.skip("standard", md, name, typ, "rule type does not apply to a repeated field")
		} else {
			rr := fr.GetRepeated()
			if rr.HasMinItems() {
				n := strconv.FormatUint(rr.GetMinItems(), 10)
				body = append(body, fmt.Sprintf("if %s.count < %s {", prop, n), "    "+violation(path, "repeated.min_items", "value must contain at least "+n+" item(s)"), "}")
			}
			if rr.HasMaxItems() {
				n := strconv.FormatUint(rr.GetMaxItems(), 10)
				body = append(body, fmt.Sprintf("if %s.count > %s {", prop, n), "    "+violation(path, "repeated.max_items", "value must contain no more than "+n+" item(s)"), "}")
			}
			if rr.GetUnique() {
				g.skip("standard", md, name, "repeated.unique", "true")
			}
			items = rr.GetItems()
		}
	}
	elemPath := fmt.Sprintf(`"\(path)%s[\(i)]"`, name)
	elem := g.elementLines(md, fd, items, "v", elemPath, name)
	if len(elem) > 0 {
		body = append(body, fmt.Sprintf("for (i, v) in %s.enumerated() {", prop))
		body = append(body, indent(elem, "    ")...)
		body = append(body, "}")
	}
	var out []string
	if required {
		out = append(out, fmt.Sprintf("if %s.isEmpty {", prop), "    "+violation(path, "required", "value is required"), "}")
	}
	if len(body) == 0 {
		return out
	}
	if ignoreZero {
		out = append(out, fmt.Sprintf("if !%s.isEmpty {", prop))
		out = append(out, indent(body, "    ")...)
		return append(out, "}")
	}
	return append(out, body...)
}

func (g *validatorGen) mapLines(md protoreflect.MessageDescriptor, fd protoreflect.FieldDescriptor, fr *validate.FieldRules, prop, path string, required, ignoreZero bool) []string {
	name := string(fd.Name())
	var body []string
	var keys, values *validate.FieldRules
	if typ, rules := typedRules(fr); rules != nil {
		if typ != "map" {
			g.skip("standard", md, name, typ, "rule type does not apply to a map field")
		} else {
			mr := fr.GetMap()
			if mr.HasMinPairs() {
				n := strconv.FormatUint(mr.GetMinPairs(), 10)
				body = append(body, fmt.Sprintf("if %s.count < %s {", prop, n), "    "+violation(path, "map.min_pairs", "map must be at least "+n+" entries"), "}")
			}
			if mr.HasMaxPairs() {
				n := strconv.FormatUint(mr.GetMaxPairs(), 10)
				body = append(body, fmt.Sprintf("if %s.count > %s {", prop, n), "    "+violation(path, "map.max_pairs", "map must be at most "+n+" entries"), "}")
			}
			keys, values = mr.GetKeys(), mr.GetValues()
		}
	}
	entryPath := fmt.Sprintf(`"\(path)%s[\(String(reflecting: k))]"`, name)
	keyChecks := g.elementLines(md, fd.MapKey(), keys, "k", entryPath, name)
	valueChecks := g.elementLines(md, fd.MapValue(), values, "v", entryPath, name)
	if len(keyChecks)+len(valueChecks) > 0 {
		order := "$0.key < $1.key"
		if fd.MapKey().Kind() == protoreflect.BoolKind {
			order = "!$0.key && $1.key"
		}
		vName := "v"
		if len(valueChecks) == 0 {
			vName = "_"
		}
		body = append(body, fmt.Sprintf("for (k, %s) in %s.sorted(by: { %s }) {", vName, prop, order))
		body = append(body, indent(append(keyChecks, valueChecks...), "    ")...)
		body = append(body, "}")
	}
	var out []string
	if required {
		out = append(out, fmt.Sprintf("if %s.isEmpty {", prop), "    "+violation(path, "required", "value is required"), "}")
	}
	if len(body) == 0 {
		return out
	}
	if ignoreZero {
		out = append(out, fmt.Sprintf("if !%s.isEmpty {", prop))
		out = append(out, indent(body, "    ")...)
		return append(out, "}")
	}
	return append(out, body...)
}

// EmitSkippedRules renders SkippedRules.md.
func EmitSkippedRules(skipped []SkippedRule) []byte {
	var b strings.Builder
	b.WriteString(`<!-- DO NOT EDIT. Generated by protoc-gen-wtcrdt (tools/protoc-gen-wtcrdt). -->
# Rules the Swift validators skip

The client has no CEL interpreter, so ` + "`Validators.swift`" + ` checks only the standard
protovalidate rules (docs/spec/api-conventions.adoc, "Validation").  Every rule below is
enforced by the server (protovalidate-java) but not before a change enters the client's
outbox.  Review this list when adding a rule: a skipped rule on a document field means a user
can queue an offline change the server will reject.
`)
	for _, section := range []struct{ kind, title, empty string }{
		{"cel", "CEL expressions (server only)", "None."},
		{"standard", "Standard rules without a generated Swift check", "None."},
	} {
		fmt.Fprintf(&b, "\n## %s\n\n", section.title)
		var rows []SkippedRule
		for _, s := range skipped {
			if s.Kind == section.kind {
				rows = append(rows, s)
			}
		}
		if len(rows) == 0 {
			b.WriteString(section.empty + "\n")
			continue
		}
		b.WriteString("| Message | Field | Rule | Detail |\n|---|---|---|---|\n")
		for _, s := range rows {
			field := s.Field
			if field == "" {
				field = "(message)"
			}
			fmt.Fprintf(&b, "| `%s` | `%s` | `%s` | %s |\n", s.Message, field, s.Rule, markdownCell(s.Detail))
		}
	}
	return []byte(b.String())
}

func markdownCell(s string) string {
	s = strings.ReplaceAll(s, "|", `\|`)
	s = strings.ReplaceAll(s, "\n", " ")
	return "`" + strings.ReplaceAll(s, "`", "'") + "`"
}
