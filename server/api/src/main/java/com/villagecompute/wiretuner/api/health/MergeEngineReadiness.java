package com.villagecompute.wiretuner.api.health;

import com.villagecompute.wiretuner.crdt.Engine;

import org.eclipse.microprofile.health.HealthCheck;
import org.eclipse.microprofile.health.HealthCheckResponse;
import org.eclipse.microprofile.health.Readiness;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * Readiness reports the merge engine the node snapshots with, so a mixed deploy is visible from
 * {@code /q/health/ready} and the compose health probe.
 */
@Readiness
@ApplicationScoped
public class MergeEngineReadiness implements HealthCheck {

    static final String NAME = "merge-engine";

    @Override
    public HealthCheckResponse call() {
        return HealthCheckResponse.named(NAME).up().withData("wt-crdt", Engine.version()).build();
    }
}
