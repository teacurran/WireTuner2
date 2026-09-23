package gen

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strconv"
)

// The serialized merge table is JSON (docs/spec/crdt-model.adoc, "Schema evolution"):
// `Welcome.merge_table` carries these bytes, the Swift and Java tables embed the same document,
// and `version` lets a client tell at a glance whether the server's table matches its own.
//
//	{
//	  "version": "<sha-256 hex of the canonical document without this key>",
//	  "messages": {
//	    "<message fqn>": {
//	      "fields": {
//	        "<field number>": {
//	          "name": "<proto field name>",
//	          "policy": "ATOMIC" | "STRUCT" | "SEQUENCE" | "TEXT" | "SET" | "VARIANT",
//	          "on_dangling": "UNSET" | "CACHED" | "PLACEHOLDER",
//	          "local_only": bool,
//	          "type": "<protobuf kind: double, string, bytes, enum, message, map, ...>",
//	          "repeated": bool,
//	          "type_name": "<message or enum fqn>" | null,
//	          "element_message": "<SEQUENCE element message fqn>" | null,
//	          "oneof": "<containing oneof name>" | null
//	        }
//	      }
//	    }
//	  },
//	  "variants": {
//	    "<message fqn>": { "kind_field": <number>, "case_fields": [<number>, ...] }
//	  }
//	}
//
// Canonical form: every object's keys sorted bytewise, no insignificant whitespace, no HTML
// escaping, field numbers as decimal strings (so "10" sorts before "2").  Anything reading the table must tolerate unknown keys: new keys are added, never
// renamed or removed.

// JSONTable is the JSON document.
type JSONTable struct {
	Version  string                 `json:"version,omitempty"`
	Messages map[string]JSONMessage `json:"messages"`
	Variants map[string]JSONVariant `json:"variants"`
}

// JSONMessage is one message's rows, keyed by decimal field number.
type JSONMessage struct {
	Fields map[string]JSONField `json:"fields"`
}

// JSONField is one row.
type JSONField struct {
	Name           string   `json:"name"`
	Policy         Policy   `json:"policy"`
	OnDangling     Fallback `json:"on_dangling"`
	LocalOnly      bool     `json:"local_only"`
	Type           string   `json:"type"`
	Repeated       bool     `json:"repeated"`
	TypeName       *string  `json:"type_name"`
	ElementMessage *string  `json:"element_message"`
	Oneof          *string  `json:"oneof"`
}

// JSONVariant is one MERGE_VARIANT message.
type JSONVariant struct {
	KindField  int32   `json:"kind_field"`
	CaseFields []int32 `json:"case_fields"`
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// ToJSON converts the table; Version is left empty (see Version).
func (t *Table) ToJSON() JSONTable {
	out := JSONTable{Messages: map[string]JSONMessage{}, Variants: map[string]JSONVariant{}}
	for name, m := range t.Messages {
		jm := JSONMessage{Fields: map[string]JSONField{}}
		for _, f := range m.Fields {
			jm.Fields[strconv.Itoa(int(f.Number))] = JSONField{
				Name:           f.Name,
				Policy:         f.Policy,
				OnDangling:     f.OnDangling,
				LocalOnly:      f.LocalOnly,
				Type:           f.Type,
				Repeated:       f.Repeated,
				TypeName:       optional(f.TypeName),
				ElementMessage: optional(f.ElementMessage),
				Oneof:          optional(f.Oneof),
			}
		}
		out.Messages[name] = jm
	}
	for name, v := range t.Variants {
		cases := v.CaseFields
		if cases == nil {
			cases = []int32{}
		}
		out.Variants[name] = JSONVariant{KindField: v.KindField, CaseFields: cases}
	}
	return out
}

// generic re-reads the document as nested maps so every object's keys, struct fields included,
// marshal in sorted order.
func (t *Table) generic(version string) any {
	doc := t.ToJSON()
	doc.Version = version
	data, err := json.Marshal(doc)
	if err != nil {
		panic(err) // the types above always marshal
	}
	var out any
	if err := json.Unmarshal(data, &out); err != nil {
		panic(err)
	}
	return out
}

func encode(v any, indent bool) []byte {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if indent {
		enc.SetIndent("", "  ")
	}
	if err := enc.Encode(v); err != nil {
		panic(err)
	}
	return buf.Bytes()
}

// Version is the SHA-256, hex encoded, of the canonical JSON without the `version` key.
func (t *Table) Version() string {
	canonical := bytes.TrimSuffix(encode(t.generic(""), false), []byte("\n"))
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:])
}

// SerializedJSON renders the table with its version, keys sorted, indented for review, ending
// in a newline.  Removing the whitespace and the `version` key gives the canonical form.
func (t *Table) SerializedJSON() []byte {
	return encode(t.generic(t.Version()), true)
}
