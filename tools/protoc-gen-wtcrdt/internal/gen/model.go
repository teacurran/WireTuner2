package gen

import (
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"

	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"

	"github.com/villagecompute/wiretuner/tools/protoc-gen-wtcrdt/internal/wtcrdtpb"
)

// The document schema's anchor types (docs/spec/crdt-model.adoc).
const (
	docPackage       = "wiretuner.doc.v1"
	nodePropsName    = docPackage + ".NodeProps"
	commonPropsName  = docPackage + ".CommonProps"
	nodeName         = docPackage + ".Node"
	elementIDName    = docPackage + ".ElementId"
	opIDName         = docPackage + ".OpId"
	nodeRefName      = docPackage + ".NodeRef"
	richTextName     = docPackage + ".RichText"
	variantKindField = "kind"
)

// Roots are the messages the merge table is walked from; everything reachable through
// message-typed fields is covered.
var Roots = []string{nodePropsName, commonPropsName, nodeName}

// Policy is a merge policy as written in the table: the wt.crdt.Merge value name without its
// `MERGE_` prefix.
type Policy string

// The six policies of docs/spec/crdt-model.adoc, "Merge policies".
const (
	PolicyAtomic   Policy = "ATOMIC"
	PolicyStruct   Policy = "STRUCT"
	PolicySequence Policy = "SEQUENCE"
	PolicyText     Policy = "TEXT"
	PolicySet      Policy = "SET"
	PolicyVariant  Policy = "VARIANT"
)

// Fallback is a wt.crdt.RefFallback value name without its `REF_FALLBACK_` prefix.
type Fallback string

// The three fallbacks of wt.crdt.RefFallback.
const (
	FallbackUnset       Fallback = "UNSET"
	FallbackCached      Fallback = "CACHED"
	FallbackPlaceholder Fallback = "PLACEHOLDER"
)

// AllPolicies lists every policy in wt.crdt.Merge order.
var AllPolicies = []Policy{PolicyAtomic, PolicyStruct, PolicySequence, PolicyText, PolicySet, PolicyVariant}

// AllFallbacks lists every fallback in wt.crdt.RefFallback order.
var AllFallbacks = []Fallback{FallbackUnset, FallbackCached, FallbackPlaceholder}

// Field is one row of the merge table: the effective policy of one field of one message.
type Field struct {
	Number     int32
	Name       string
	Policy     Policy
	OnDangling Fallback
	LocalOnly  bool
	// Type is the protobuf kind: "double", "string", "bytes", "enum", "message", ...
	Type     string
	Repeated bool
	// TypeName is the fully qualified message or enum name for those kinds, else "".
	TypeName string
	// ElementMessage is the element message of a SEQUENCE field, else "".
	ElementMessage string
	// Oneof is the name of the oneof the field belongs to, else "".
	Oneof string
	// Explicit is true when the policy was written on the field rather than defaulted.
	Explicit bool
}

// Variant describes a MERGE_VARIANT message: its `kind` discriminator and the message-typed
// sibling fields that hold each case's registers.
type Variant struct {
	KindField  int32
	CaseFields []int32
}

// Message is the table for one message, fields sorted by number.
type Message struct {
	Name   string
	Fields []Field
}

// Table is the merge table for every message reachable from the roots.
type Table struct {
	Messages map[string]*Message
	Variants map[string]*Variant
}

// MessageNames returns the covered message names, sorted.
func (t *Table) MessageNames() []string {
	names := make([]string, 0, len(t.Messages))
	for n := range t.Messages {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// VariantNames returns the variant message names, sorted.
func (t *Table) VariantNames() []string {
	names := make([]string, 0, len(t.Variants))
	for n := range t.Variants {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// BuildTable walks every message reachable from the roots and computes each field's effective
// policy, validating the explicit ones.  Every problem is reported at once, one per line, each
// naming the field.  Warnings (a missing RichText message) go to warn.
func BuildTable(plugin *protogen.Plugin, warn io.Writer) (*Table, error) {
	files := plugin.Files
	byName := map[protoreflect.FullName]protoreflect.MessageDescriptor{}
	for _, f := range files {
		collectMessages(f.Desc.Messages(), byName)
	}
	var roots []protoreflect.MessageDescriptor
	for _, r := range Roots {
		md, ok := byName[protoreflect.FullName(r)]
		if !ok {
			return nil, fmt.Errorf("root message %s is not in the request; is wiretuner/doc/v1/node.proto among the files to generate?", r)
		}
		roots = append(roots, md)
	}
	if _, ok := byName[richTextName]; !ok && warn != nil {
		fmt.Fprintf(warn, "protoc-gen-wtcrdt: warning: no message %s exists yet; MERGE_TEXT fields cannot be checked against it\n", richTextName)
	}

	table := &Table{Messages: map[string]*Message{}, Variants: map[string]*Variant{}}
	var problems []string
	queue := append([]protoreflect.MessageDescriptor{}, roots...)
	for len(queue) > 0 {
		md := queue[0]
		queue = queue[1:]
		name := string(md.FullName())
		if _, seen := table.Messages[name]; seen {
			continue
		}
		msg := &Message{Name: name}
		fields := md.Fields()
		for i := 0; i < fields.Len(); i++ {
			fd := fields.Get(i)
			field, variant, errs := effectivePolicy(fd)
			problems = append(problems, errs...)
			msg.Fields = append(msg.Fields, field)
			if variant != nil {
				table.Variants[string(fd.Message().FullName())] = variant
			}
			if fd.Message() != nil && !fd.IsMap() {
				queue = append(queue, fd.Message())
			}
		}
		sort.Slice(msg.Fields, func(a, b int) bool { return msg.Fields[a].Number < msg.Fields[b].Number })
		table.Messages[name] = msg
	}
	if len(problems) > 0 {
		sort.Strings(problems)
		return nil, errors.New(strings.Join(problems, "\n"))
	}
	return table, nil
}

func collectMessages(msgs protoreflect.MessageDescriptors, into map[protoreflect.FullName]protoreflect.MessageDescriptor) {
	for i := 0; i < msgs.Len(); i++ {
		md := msgs.Get(i)
		into[md.FullName()] = md
		collectMessages(md.Messages(), into)
	}
}

// crdtOptions reads the `(wt.crdt.field)` option of a field, nil when absent.
func crdtOptions(fd protoreflect.FieldDescriptor) *wtcrdtpb.FieldOptions {
	opts, ok := fd.Options().(*descriptorpb.FieldOptions)
	if !ok || opts == nil || !proto.HasExtension(opts, wtcrdtpb.E_Field) {
		return nil
	}
	ext, _ := proto.GetExtension(opts, wtcrdtpb.E_Field).(*wtcrdtpb.FieldOptions)
	return ext
}

func policyOf(m wtcrdtpb.Merge) Policy {
	return Policy(strings.TrimPrefix(m.String(), "MERGE_"))
}

func fallbackOf(f wtcrdtpb.RefFallback) Fallback {
	return Fallback(strings.TrimPrefix(f.String(), "REF_FALLBACK_"))
}

// effectivePolicy applies the defaults (scalars, strings, bytes, enums and repeated scalars
// ATOMIC; a singular NodeRef ATOMIC, since a reference is one register -- crdt-model.adoc,
// "References"; other singular messages STRUCT) and checks an explicit policy against the field's shape.
func effectivePolicy(fd protoreflect.FieldDescriptor) (Field, *Variant, []string) {
	where := string(fd.FullName())
	f := Field{
		Number:     int32(fd.Number()),
		Name:       string(fd.Name()),
		OnDangling: FallbackUnset,
		Type:       fd.Kind().String(),
		Repeated:   fd.Cardinality() == protoreflect.Repeated,
	}
	if fd.IsMap() {
		f.Type = "map"
	}
	switch {
	case fd.Message() != nil:
		f.TypeName = string(fd.Message().FullName())
	case fd.Enum() != nil:
		f.TypeName = string(fd.Enum().FullName())
	}
	if od := fd.ContainingOneof(); od != nil {
		f.Oneof = string(od.Name())
	}

	var problems []string
	opts := crdtOptions(fd)
	var explicit wtcrdtpb.Merge
	if opts != nil {
		explicit = opts.GetMerge()
		f.LocalOnly = opts.GetLocalOnly()
		f.OnDangling = fallbackOf(opts.GetOnDangling())
		if _, known := wtcrdtpb.RefFallback_name[int32(opts.GetOnDangling())]; !known {
			problems = append(problems, fmt.Sprintf("%s: on_dangling = %d is not a wt.crdt.RefFallback value", where, opts.GetOnDangling()))
		}
		if opts.GetOnDangling() != wtcrdtpb.RefFallback_REF_FALLBACK_UNSET && f.TypeName != nodeRefName {
			problems = append(problems, fmt.Sprintf("%s: on_dangling is only meaningful on a %s field; this field is %s", where, nodeRefName, describeType(fd)))
		}
	}

	isMessage := fd.Message() != nil && !fd.IsMap()
	if explicit == wtcrdtpb.Merge_MERGE_UNSPECIFIED {
		switch {
		case fd.IsMap():
			problems = append(problems, fmt.Sprintf("%s: a map field has no default merge policy and none is supported; use a repeated message with MERGE_SEQUENCE", where))
			f.Policy = PolicyAtomic
		case isMessage && f.Repeated:
			problems = append(problems, fmt.Sprintf("%s: a repeated message field has no default merge policy; annotate it [(wt.crdt.field).merge = MERGE_SEQUENCE] (elements need `%s id = 1`) or MERGE_ATOMIC", where, elementIDName))
			f.Policy = PolicyAtomic
		case isMessage && f.TypeName == nodeRefName:
			f.Policy = PolicyAtomic
		case isMessage:
			f.Policy = PolicyStruct
		default:
			f.Policy = PolicyAtomic
		}
		return f, nil, problems
	}

	f.Explicit = true
	f.Policy = policyOf(explicit)
	var variant *Variant
	switch explicit {
	case wtcrdtpb.Merge_MERGE_ATOMIC:
		// Anything may be one register.
	case wtcrdtpb.Merge_MERGE_STRUCT:
		if !isMessage || f.Repeated {
			problems = append(problems, fmt.Sprintf("%s: MERGE_STRUCT requires a singular message field; this field is %s", where, describeType(fd)))
		}
	case wtcrdtpb.Merge_MERGE_SEQUENCE:
		if !isMessage || !f.Repeated {
			problems = append(problems, fmt.Sprintf("%s: MERGE_SEQUENCE requires a repeated message field whose field 1 is `%s id`; this field is %s", where, elementIDName, describeType(fd)))
			break
		}
		f.ElementMessage = f.TypeName
		if err := checkSequenceElement(fd.Message()); err != "" {
			problems = append(problems, fmt.Sprintf("%s: MERGE_SEQUENCE requires a repeated message whose field 1 is `%s id`; %s", where, elementIDName, err))
		}
	case wtcrdtpb.Merge_MERGE_TEXT:
		if !isMessage || f.Repeated || fd.Message().Name() != "RichText" {
			problems = append(problems, fmt.Sprintf("%s: MERGE_TEXT requires a singular RichText field; this field is %s", where, describeType(fd)))
		}
	case wtcrdtpb.Merge_MERGE_SET:
		switch {
		case !f.Repeated || fd.IsMap():
			problems = append(problems, fmt.Sprintf("%s: MERGE_SET requires a repeated scalar or a repeated %s/%s; this field is %s", where, elementIDName, opIDName, describeType(fd)))
		case isMessage && f.TypeName != elementIDName && f.TypeName != opIDName:
			problems = append(problems, fmt.Sprintf("%s: MERGE_SET requires a repeated scalar or a repeated %s/%s; this field is %s", where, elementIDName, opIDName, describeType(fd)))
		}
	case wtcrdtpb.Merge_MERGE_VARIANT:
		if !isMessage || f.Repeated {
			problems = append(problems, fmt.Sprintf("%s: MERGE_VARIANT requires a singular message field with an enum field named `%s`; this field is %s", where, variantKindField, describeType(fd)))
			break
		}
		v, err := variantOf(fd.Message())
		if err != "" {
			problems = append(problems, fmt.Sprintf("%s: MERGE_VARIANT requires a message with an enum field named `%s`; %s", where, variantKindField, err))
		}
		variant = v
	default:
		problems = append(problems, fmt.Sprintf("%s: merge = %d is not a wt.crdt.Merge value this plugin knows", where, explicit))
	}
	return f, variant, problems
}

// checkSequenceElement reports why a message cannot be a SEQUENCE element, or "".
func checkSequenceElement(md protoreflect.MessageDescriptor) string {
	first := md.Fields().ByNumber(1)
	switch {
	case first == nil:
		return fmt.Sprintf("%s has no field 1", md.FullName())
	case first.Name() != "id":
		return fmt.Sprintf("field 1 of %s is `%s %s`", md.FullName(), typeLabel(first), first.Name())
	case first.Message() == nil || first.Message().FullName() != elementIDName || first.Cardinality() == protoreflect.Repeated:
		return fmt.Sprintf("field 1 of %s is `%s id`", md.FullName(), typeLabel(first))
	}
	return ""
}

// variantOf reads a MERGE_VARIANT message: an enum `kind` plus its message-typed case fields.
func variantOf(md protoreflect.MessageDescriptor) (*Variant, string) {
	kind := md.Fields().ByName(variantKindField)
	if kind == nil {
		return nil, fmt.Sprintf("%s has no field named `%s`", md.FullName(), variantKindField)
	}
	if kind.Enum() == nil || kind.Cardinality() == protoreflect.Repeated {
		return nil, fmt.Sprintf("%s.%s is `%s`, not an enum", md.FullName(), variantKindField, typeLabel(kind))
	}
	v := &Variant{KindField: int32(kind.Number())}
	fields := md.Fields()
	for i := 0; i < fields.Len(); i++ {
		fd := fields.Get(i)
		if fd.Message() != nil && fd.Cardinality() != protoreflect.Repeated && !fd.IsMap() {
			v.CaseFields = append(v.CaseFields, int32(fd.Number()))
		}
	}
	sort.Slice(v.CaseFields, func(a, b int) bool { return v.CaseFields[a] < v.CaseFields[b] })
	return v, ""
}

func typeLabel(fd protoreflect.FieldDescriptor) string {
	label := fd.Kind().String()
	switch {
	case fd.IsMap():
		label = fmt.Sprintf("map<%s, %s>", typeLabel(fd.MapKey()), typeLabel(fd.MapValue()))
	case fd.Message() != nil:
		label = string(fd.Message().FullName())
	case fd.Enum() != nil:
		label = string(fd.Enum().FullName())
	}
	if fd.Cardinality() == protoreflect.Repeated && !fd.IsMap() {
		label = "repeated " + label
	}
	return label
}

func describeType(fd protoreflect.FieldDescriptor) string {
	return "`" + typeLabel(fd) + "`"
}
