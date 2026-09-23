/**
 * Hibernate Reactive Panache entities and repositories over the SRV-003 schema
 * (docs/spec/server.adoc, Persistence). Entities use public fields, as dissipate-server's do;
 * composite keys are {@code @Embeddable} records. {@code document_search} and
 * {@code cold_segment} stay plain SQL behind native-query repositories.
 */
package com.villagecompute.wiretuner.api.persistence;
