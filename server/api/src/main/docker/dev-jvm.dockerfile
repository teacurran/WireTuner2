####
# Development image for the compose `api` service: runs the WireTuner API in Quarkus dev mode
# (live reload, debugger on 5005) from the sources mounted at /app, the way dissipate-server's
# dev-jvm.dockerfile does. It is not a deployment image.
#
# Build and run it through compose from the repository root:
#
#   docker compose up api
#
# The repository is mounted at /app and the reactor runs from /app/server: the api depends on
# wt-crdt, and api/src/main/proto is a symlink to the repo's proto/ that must resolve here.
# ~/.m2 is a named volume shared with the main-db-migrations job, and the target dirs are named
# volumes so dev-mode class files never collide with a host `./mvnw verify`.
#
# Debian-family base on purpose: Quarkus generate-code downloads a protoc binary that is not
# built for Alpine's musl. Temurin 25 images are Ubuntu.
###
FROM maven:3.9-eclipse-temurin-25

ENV LANG='en_US.UTF-8' LANGUAGE='en_US:en'

# wt-crdt's generate-sources runs `make -C tools/protoc-gen-wtcrdt generate-java`, which needs make,
# Go (the plugin) and protoc on the PATH (docs/spec/server.adoc, "Generated code").
# Go comes from go.dev: the distribution package lags the version tools/protoc-gen-wtcrdt/go.mod needs.
ARG GO_VERSION=1.27.1
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends make protobuf-compiler curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH:-amd64}.tar.gz" | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

RUN mkdir -p /app/server
WORKDIR /app/server

EXPOSE 8080 5005

ENV JAVA_OPTS="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager"

# -pl api -am builds wt-crdt in the same reactor before dev mode starts on the api.
CMD ["mvn", "-pl", "api", "-am", "quarkus:dev", "-Dquarkus.http.host=0.0.0.0"]
