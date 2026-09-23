# protoc-gen-wtcrdt (docs/spec/backlog.adoc PROTO-005).  Run from anywhere with
# `make -C tools/protoc-gen-wtcrdt <target>`; needs Go (see go.mod) and protoc.
#
#   build     tools/bin/protoc-gen-wtcrdt (gitignored)
#   test      go test ./... (policies, validator rules, failures, golden over proto/)
#   golden    rewrite testdata/golden from the current proto/ (review the diff!)
#   generate  run the plugin over proto/ with protoc: the committed Swift in
#             client/Packages/WTCRDT/Sources/WTCRDTSchema/Generated and the Java in
#             server/wt-crdt/target/generated-sources/wtcrdt (gitignored)
#   generate-java  the Java half of `generate` only: what server/wt-crdt's Maven build runs at
#             generate-sources, so a server build never rewrites the committed client files
#   check     fail if the committed Swift differs from a fresh generate (CI drift check)
#   options   regenerate internal/wtcrdtpb from proto/wt/crdt/options.proto
#
# `generate` uses protoc rather than buf so it runs without the BSR: wtcrdt-descriptors
# compiles proto/ with buf/validate/validate.proto taken from the protovalidate Go module this
# tool pins (the same BSR commit as buf.lock).  `buf generate --template
# tools/protoc-gen-wtcrdt/buf.gen.yaml` from the repository root produces identical output.

ROOT      := $(abspath ../..)
BIN       := $(ROOT)/tools/bin/protoc-gen-wtcrdt
SWIFT_OUT := client/Packages/WTCRDT/Sources/WTCRDTSchema/Generated
JAVA_OUT  := server/wt-crdt/target/generated-sources/wtcrdt
VERSION   := $(shell git -C $(ROOT) rev-parse --short HEAD 2>/dev/null || echo dev)
WORK      := $(ROOT)/tools/bin/wtcrdt-work
GO_SRC    := $(shell find . -name '*.go' -not -path './testdata/*') go.mod go.sum

.PHONY: build test golden generate generate-java check options clean

build: $(BIN)

$(BIN): $(GO_SRC)
	go build -trimpath -ldflags "-X main.version=$(VERSION)" -o $(BIN) .

test:
	go test ./...

golden:
	go test ./internal/gen -run TestGolden -update

# $(1) = output root for swift_out/java_out (relative paths below it); $(2) = plugin options
# (default: both languages).  $(3) = descriptor set name, so the Maven build's generate-java
# and a concurrent `generate` never share one scratch file.
define run_plugin
	mkdir -p $(WORK) $(1)
	go run ./cmd/wtcrdt-descriptors $(ROOT)/proto $(WORK)/$(or $(3),module).binpb
	cd $(ROOT)/proto && protoc --descriptor_set_in=$(WORK)/$(or $(3),module).binpb \
		--plugin=protoc-gen-wtcrdt=$(BIN) \
		--wtcrdt_out=$(1) \
		--wtcrdt_opt=$(or $(2),swift_out=$(SWIFT_OUT)$(COMMA)java_out=$(JAVA_OUT)) \
		$$(find wiretuner wt -name '*.proto' -not -path 'wiretuner/internal/*' | LC_ALL=C sort)
endef
COMMA := ,

generate: build
	rm -rf $(ROOT)/$(SWIFT_OUT) $(ROOT)/$(JAVA_OUT)
	$(call run_plugin,$(ROOT))

generate-java: build
	rm -rf $(ROOT)/$(JAVA_OUT)
	$(call run_plugin,$(ROOT),java_out=$(JAVA_OUT),module-java)

check: build
	rm -rf $(WORK)/check
	$(call run_plugin,$(WORK)/check)
	diff -ru $(WORK)/check/$(SWIFT_OUT) $(ROOT)/$(SWIFT_OUT)

options:
	cd $(ROOT)/proto && protoc --plugin=protoc-gen-go="$$(cd $(CURDIR) && go tool -n protoc-gen-go)" \
		--go_out=$(CURDIR)/internal/wtcrdtpb \
		--go_opt=paths=source_relative,Mwt/crdt/options.proto=github.com/villagecompute/wiretuner/tools/protoc-gen-wtcrdt/internal/wtcrdtpb \
		wt/crdt/options.proto
	mv internal/wtcrdtpb/wt/crdt/options.pb.go internal/wtcrdtpb/options.pb.go
	rm -r internal/wtcrdtpb/wt

clean:
	rm -rf $(BIN) $(WORK)
