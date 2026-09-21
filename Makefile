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
