package gen

import (
	"bytes"
	"flag"
	"os"
	"path/filepath"
	"testing"

	"github.com/villagecompute/wiretuner/tools/protoc-gen-wtcrdt/internal/protoset"
)

var update = flag.Bool("update", false, "rewrite testdata/golden from the current proto/")

var goldenDir = filepath.Join("..", "..", "testdata", "golden")

// committedSwift is where `make generate` writes the Swift the client builds.
var committedSwift = filepath.Join("..", "..", "..", "..", "client", "Packages", "WTCRDT", "Sources", "WTCRDTSchema", "Generated")

// TestGolden generates over the repository's proto/ and compares every output with
// testdata/golden (`make golden` rewrites them).  A schema change shows up here as a reviewed
// diff of the merge table and validators.
func TestGolden(t *testing.T) {
	names, err := protoset.ModuleFiles(protoRoot)
	if err != nil {
		t.Fatal(err)
	}
	files, err := protoset.Compile(protoRoot, nil, names)
	if err != nil {
		t.Fatal(err)
	}
	req, err := protoset.Request(files, "swift_out=swift,java_out=java")
	if err != nil {
		t.Fatal(err)
	}
	outs, err := Generate(req, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(outs) != 6 {
		t.Fatalf("got %d outputs, want 6", len(outs))
	}
	for _, o := range outs {
		path := filepath.Join(goldenDir, filepath.FromSlash(o.Name))
		if *update {
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, o.Content, 0o644); err != nil {
				t.Fatal(err)
			}
			continue
		}
		want, err := os.ReadFile(path)
		if err != nil {
			t.Errorf("%s: %v (run `make golden`)", o.Name, err)
			continue
		}
		if !bytes.Equal(want, o.Content) {
			t.Errorf("%s differs from %s; review and run `make golden`", o.Name, path)
		}
	}
}

// TestCommittedSwiftMatchesGolden is the drift check `make check` also runs: the Swift the
// client compiles is exactly what the plugin produces today.
func TestCommittedSwiftMatchesGolden(t *testing.T) {
	entries, err := os.ReadDir(filepath.Join(goldenDir, "swift"))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		golden, _ := os.ReadFile(filepath.Join(goldenDir, "swift", e.Name()))
		committed, err := os.ReadFile(filepath.Join(committedSwift, e.Name()))
		if err != nil {
			t.Errorf("%s: %v (run `make generate`)", e.Name(), err)
			continue
		}
		if !bytes.Equal(golden, committed) {
			t.Errorf("committed %s is stale; run `make -C tools/protoc-gen-wtcrdt generate`", e.Name())
		}
	}
}
