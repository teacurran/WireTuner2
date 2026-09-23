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

.PHONY: proto-lint proto-gen proto-plugins

# The proto gate CI runs (.github/workflows/proto.yml); breaking is compared with main.
proto-lint:
	buf format --diff --exit-code
	buf lint
	tools/proto/check-no-bidi.sh
	buf breaking --against '.git#branch=main'

# Builds tools/bin/protoc-gen-grpc-swift-2 at the version WTProto pins (docs/spec/decisions.adoc D-014).
proto-plugins:
	tools/proto/install-plugins.sh

# Regenerates the committed Swift and the HTML reference (proto/gen/docs, gitignored).
proto-gen: proto-plugins
	buf generate

.PHONY: client-build

# Every package's `swift test --enable-code-coverage`, then `xcodebuild test -enableCodeCoverage YES`,
# then client/build/coverage/sonar.xml (docs/spec/building.adoc).  XCUITest is skipped when macOS
# Automation Mode is off: sudo automationmodetool enable-automationmode-without-authentication

# Debug build, ad-hoc signed unless DEVELOPMENT_TEAM (and optionally CODE_SIGN_IDENTITY) are exported.
client-build:
	cd client && xcodebuild -project WireTuner.xcodeproj -scheme WireTuner -destination 'platform=macOS' \
		-derivedDataPath build/DerivedData \
		DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" CODE_SIGN_IDENTITY="$(or $(CODE_SIGN_IDENTITY),-)" build

.PHONY: server-test up down

server-test:
	cd server && JAVA_HOME=$$(sdk home java 25-amzn) ./mvnw -q verify


up:
	docker compose up -d

down:
	docker compose down

.PHONY: client-test sonar-server sonar-client sonar-gates sonar-tools-test

# SONAR_TOKEN from the environment, else ~/.sonar-token (docs/spec/testing.adoc).  Exported to
# the scanner's environment only; never echoed or passed as a -D flag.
SONAR_TOKEN_SHELL = token="$${SONAR_TOKEN:-$$(cat "$$HOME/.sonar-token" 2>/dev/null | tr -d '[:space:]')}"; \
	test -n "$$token" || { echo 'no Sonar token: export SONAR_TOKEN or write it to ~/.sonar-token' >&2; exit 2; }; \
	export SONAR_TOKEN="$$token"

client-test:
	tools/coverage/Tests/run.sh
	tools/coverage/client-coverage.sh --gate

sonar-server:
	@$(SONAR_TOKEN_SHELL); cd server && ./mvnw -B -ntp sonar:sonar -Dsonar.projectVersion="$$(git describe --tags --always)"

sonar-client:
	@$(SONAR_TOKEN_SHELL); cd client && sonar-scanner -Dsonar.projectVersion="$$(git describe --tags --always)"

# Creates or converges the two projects and their gates (idempotent; DRY_RUN=1 prints the calls).
sonar-gates:
	tools/sonar/configure-gates.sh $(if $(DRY_RUN),--dry-run)

sonar-tools-test:
	tools/coverage/Tests/run.sh
	tools/sonar/Tests/run.sh
	tools/sonar/check-no-token.sh
