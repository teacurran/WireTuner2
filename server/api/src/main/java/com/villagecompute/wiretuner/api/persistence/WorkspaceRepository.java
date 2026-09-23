package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;

import jakarta.enterprise.context.ApplicationScoped;

/** Workspaces by team id. */
@ApplicationScoped
public class WorkspaceRepository implements PanacheRepositoryBase<Workspace, UUID> {
}
