// Package gen turns a CodeGeneratorRequest into the merge tables and validators
// protoc-gen-wtcrdt emits (docs/spec/crdt-model.adoc "Merge policies" and "Schema
// evolution"; docs/spec/api-conventions.adoc "Validation").
package gen

import (
	"fmt"
	"strings"
)

// DefaultJavaPackage is the package MergeTable.java is emitted into when java_package is not
// given.  It sits beside the engine (server/wt-crdt) under the Java package the wt.crdt options
// file declares.
const DefaultJavaPackage = "com.villagecompute.wiretuner.crdt.schema"

// Params are the plugin parameters: `swift_out=<dir>,java_out=<dir>,java_package=<pkg>`.
// Directories are relative to the plugin's output directory (buf's `out:`, protoc's
// `--wtcrdt_out`).  Either output may be left out, in which case that language is skipped.
type Params struct {
	SwiftOut    string
	JavaOut     string
	JavaPackage string
}

// ParseParams parses the comma-separated `key=value` parameter string protoc hands a plugin.
// Parameters protoc-gen-go understands (`M<file>=...`, `paths=`, `module=`) are accepted and
// ignored so a shared buf.gen.yaml `opt:` list never breaks this plugin.
func ParseParams(parameter string) (Params, error) {
	p := Params{JavaPackage: DefaultJavaPackage}
	if strings.TrimSpace(parameter) == "" {
		return p, fmt.Errorf("no parameters: expected swift_out=<dir> and/or java_out=<dir>")
	}
	for _, kv := range strings.Split(parameter, ",") {
		kv = strings.TrimSpace(kv)
		if kv == "" {
			continue
		}
		key, value, found := strings.Cut(kv, "=")
		if !found {
			return p, fmt.Errorf("parameter %q is not key=value", kv)
		}
		value = strings.TrimSpace(value)
		switch key {
		case "swift_out":
			p.SwiftOut = strings.TrimSuffix(value, "/")
		case "java_out":
			p.JavaOut = strings.TrimSuffix(value, "/")
		case "java_package":
			if value == "" {
				return p, fmt.Errorf("java_package must not be empty")
			}
			p.JavaPackage = value
		case "paths", "module":
			// protoc-gen-go parameters; harmless here.
		default:
			if strings.HasPrefix(key, "M") {
				continue
			}
			return p, fmt.Errorf("unknown parameter %q (known: swift_out, java_out, java_package)", key)
		}
	}
	if p.SwiftOut == "" && p.JavaOut == "" {
		return p, fmt.Errorf("at least one of swift_out=<dir> or java_out=<dir> is required")
	}
	return p, nil
}
