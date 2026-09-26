.PHONY: docs docs-guide docs-spec docs-check docs-clean help-catalog help-catalog-check

# Full render through Maven (the CI path; same plugin pair as dissipate-server).
docs:
	cd docs && mvn -q generate-resources

docs-guide:
	cd docs && mvn -q org.asciidoctor:asciidoctor-maven-plugin:process-asciidoc@render-guide

docs-spec:
	cd docs && mvn -q org.asciidoctor:asciidoctor-maven-plugin:process-asciidoc@render-spec \
		org.asciidoctor:asciidoctor-maven-plugin:process-asciidoc@render-arch

# Fast local check with the Ruby asciidoctor CLI: renders both books and fails on any warning,
# after checking the Help panel's catalog still matches the guide.
docs-check: help-catalog-check
	rm -rf docs/target/check docs/docs
	asciidoctor --failure-level WARN -B docs -D $(CURDIR)/docs/target/check/guide docs/guide/*.adoc
	asciidoctor --failure-level WARN -B docs -a spec -D $(CURDIR)/docs/target/check/spec docs/guide/*.adoc docs/spec/*.adoc

docs-clean:
	rm -rf docs/target

# The Help panel's catalog, client/WTApp/Help/HelpCatalog.swift, generated from docs/guide
# (BASIC-007; docs/spec/building.adoc, "Help catalog").  The check fails when a guide edit was
# committed without the regenerated Swift; CI runs it in the client workflow.
help-catalog:
	tools/help/help-catalog.py

help-catalog-check:
	tools/help/help-catalog.py --check

.PHONY: proto-lint proto-gen proto-plugins

# The proto gate CI runs (.github/workflows/proto.yml); breaking is compared with main.
proto-lint:
	buf format --diff --exit-code
	buf lint
	tools/proto/check-no-bidi.sh
	$(MAKE) -C tools/protoc-gen-wtcrdt test check
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

.PHONY: client-ios
# Every shared package built for generic iOS (decisions.adoc D-073; client.adoc, "iOS readiness").
IOS_PACKAGES = WTGeometry WTProto WTCRDT WTRender WTText WTInterchange WTModel WTSync WTTestSupport
client-ios:
	set -e; for package in $(IOS_PACKAGES); do \
		echo "==> $$package (iOS)"; \
		(cd client/Packages/$$package && xcodebuild -quiet -scheme $$package -destination 'generic/platform=iOS' \
			-derivedDataPath $(CURDIR)/client/build/DerivedDataIOS build); \
	done

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
	tools/launch-smoke/launch-smoke.sh

.PHONY: client-perf

# Timing budgets (docs/spec/testing.adoc, "Client budgets"): every package whose tests hold a
# PerfBudget runs them in release with WT_PERF=1, one test at a time (a budget must not share the
# cores with the rest of its suite, which the load average does not show), then the app's budget
# suites run (Debug, the only configuration its tests build; their rows come from the log, as the
# sandboxed test host cannot write here).  The table is client/build/perf-results.md.  Under load
# (one-minute load average over 1.5 x the cores) a budget skips with the load as its reason; the
# target fails on a missed budget or a failing test, after every package has run.
PERF_RESULTS = client/build/perf-results.md
PERF_APP_TESTS = -only-testing:WireTunerTests/CanvasPerformanceTests -only-testing:WireTunerTests/CommandPaletteModelTests -only-testing:WireTunerTests/CanvasMetalTests -only-testing:WireTunerTests/InspectOverlayPerformanceTests -only-testing:WireTunerTests/BranchMergePerformanceTests

client-perf:
	@rm -f $(PERF_RESULTS); mkdir -p client/build; status=0; \
	for package in client/Packages/*/; do \
		grep -rqs --exclude='PerfBudget*.swift' 'PerfBudget\.' "$$package/Tests" || continue; \
		echo "==> WT_PERF=1 swift test -c release --no-parallel ($$package)"; \
		(cd "$$package" && WT_PERF=1 swift test -c release -Xswiftc -enable-testing --no-parallel) || status=1; \
	done; \
	echo "==> app budgets: xcodebuild test $(PERF_APP_TESTS)"; \
	TEST_RUNNER_WT_PERF=1 TEST_RUNNER_WT_PERF_RESULTS=/dev/null/perf-results.md \
		xcodebuild test -project client/WireTuner.xcodeproj -scheme WireTuner -destination 'platform=macOS' \
		-derivedDataPath client/build/DerivedData -parallel-testing-enabled NO $(PERF_APP_TESTS) \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO > client/build/perf-app.log 2>&1 || status=1; \
	grep -E '^(Test Suite|\*\*|Executed|error:)|[✔✘] (Suite|Test run)' client/build/perf-app.log || true; \
	test -s $(PERF_RESULTS) || printf '| Measure | Measured | Budget | Build | Result |\n|---|---|---|---|---|\n' > $(PERF_RESULTS); \
	sed -n 's/^PERF \(| .* |\)$$/\1/p' client/build/perf-app.log >> $(PERF_RESULTS); \
	cat $(PERF_RESULTS); \
	exit $$status

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

.PHONY: conformance
# Both engines replay every crdt-conformance vector (docs/spec/testing.adoc, CRDT-011).
conformance:
	$(MAKE) -C crdt-conformance run

.PHONY: client-sim
# The multi-client simulator (docs/spec/testing.adoc, "Multi-client simulation"); SIM_RUNS=n seeded random runs, SIM_COMPOSE=1 also against the compose server.
client-sim:
	cd client/Packages/WTTestSupport && WT_SIM_RUNS=$(or $(SIM_RUNS),4) $(if $(SIM_COMPOSE),WT_SIM_COMPOSE=1) swift test --filter 'ScenarioTests|RandomizedSimulationTests|ComposeSimulationTests'
