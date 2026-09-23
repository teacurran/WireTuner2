package com.villagecompute.wiretuner.api;

import static io.restassured.RestAssured.given;
import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.hasItem;
import static org.hamcrest.Matchers.is;

import grpc.health.v1.HealthGrpc;
import grpc.health.v1.HealthOuterClass.HealthCheckRequest;
import grpc.health.v1.HealthOuterClass.HealthCheckResponse.ServingStatus;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

import org.junit.jupiter.api.Test;

/**
 * Boots the application against Dev Services (Testcontainers Postgres and Valkey) and checks the
 * two probes compose and the load balancer rely on.
 */
@QuarkusTest
class HealthTest {

    @GrpcClient("health")
    HealthGrpc.HealthBlockingStub health;

    @Test
    void grpcHealthReportsServing() {
        var response = health.check(HealthCheckRequest.newBuilder().build());

        assertThat(response.getStatus()).isEqualTo(ServingStatus.SERVING);
    }

    @Test
    void httpReadinessIsUpAndNamesTheMergeEngine() {
        given().when().get("/q/health/ready")
                .then()
                .statusCode(200)
                .body("status", is("UP"))
                .body("checks.name", hasItem("merge-engine"))
                .body("checks.find { it.name == 'merge-engine' }.data.wt-crdt", is(com.villagecompute.wiretuner.crdt.Engine.version()));
    }
}
