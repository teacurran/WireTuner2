.PHONY: docs docs-guide docs-spec docs-check docs-clean

# Full render through Maven (the CI path; same plugin pair as dissipate-server).
docs:
	cd docs && mvn -q generate-resources

docs-guide:
	cd docs && mvn -q org.asciidoctor:asciidoctor-maven-plugin:process-asciidoc@render-guide

docs-spec:
	cd docs && mvn -q org.asciidoctor:asciidoctor-maven-plugin:process-asciidoc@render-spec \
		org.asciidoctor:asciidoctor-maven-plugin:process-asciidoc@render-arch

# Fast local check with the Ruby asciidoctor CLI: renders both books and fails on any warning.
docs-check:
	rm -rf docs/target/check docs/docs
	asciidoctor --failure-level WARN -B docs -D $(CURDIR)/docs/target/check/guide docs/guide/*.adoc
	asciidoctor --failure-level WARN -B docs -a spec -D $(CURDIR)/docs/target/check/spec docs/guide/*.adoc docs/spec/*.adoc

docs-clean:
	rm -rf docs/target

.PHONY: proto-lint proto-gen

# The proto gate CI runs (.github/workflows/proto.yml); breaking is compared with main.
proto-lint:
	buf format --diff --exit-code
	buf lint
	buf breaking --against '.git#branch=main'

# Regenerates the committed Swift and the HTML reference (proto/gen/docs, gitignored).
proto-gen:
	buf generate

.PHONY: client-test client-build

# Every package's `swift test --enable-code-coverage`, then `xcodebuild test -enableCodeCoverage YES`,
# then client/build/coverage/sonar.xml (docs/spec/building.adoc).  XCUITest is skipped when macOS
# Automation Mode is off: sudo automationmodetool enable-automationmode-without-authentication
client-test:
	tools/coverage/Tests/run.sh
	tools/coverage/client-coverage.sh

# Debug build, ad-hoc signed unless DEVELOPMENT_TEAM (and optionally CODE_SIGN_IDENTITY) are exported.
client-build:
	cd client && xcodebuild -project WireTuner.xcodeproj -scheme WireTuner -destination 'platform=macOS' \
		-derivedDataPath build/DerivedData \
		DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" CODE_SIGN_IDENTITY="$(or $(CODE_SIGN_IDENTITY),-)" build
