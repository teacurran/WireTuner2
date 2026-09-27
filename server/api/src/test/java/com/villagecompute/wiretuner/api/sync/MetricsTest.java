package com.villagecompute.wiretuner.api.sync;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static io.restassured.RestAssured.given;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.docs.v1.SearchRequest;
import com.villagecompute.wiretuner.sync.v1.AckRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangesRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangesResponse;
import com.villagecompute.wiretuner.sync.v1.ServerFrame.FrameCase;

import io.grpc.stub.StreamObserver;
import io.quarkus.test.junit.QuarkusTest;

/**
 * SRV-014: the metrics of docs/spec/server.adoc (Observability) on {@code /q/metrics}: per RPC
 * (Quarkus's gRPC binder) and per document (changes, sessions, backlog, ingest time, stable lag).
 */
@QuarkusTest
class MetricsTest extends SyncTestSupport {

    static String metrics() {
        return given().get("/q/metrics").then().statusCode(200).extract().asString();
    }

    @Test
    void perRpcAndPerDocumentSeriesArePublished() throws Exception {
        UUID doc = document(ALICE);
        String tag = "document=\"" + doc + "\"";
        Subscription first = subscribe(ALICE, null, doc, replicaId(), 0);
        first.next(FrameCase.PRESENCE);
        Subscription second = subscribe(ALICE, null, doc, replicaId(), 0);
        second.next(FrameCase.PRESENCE);
        assertThat(metrics()).contains("wt_subscriptions_open{" + tag + "} 2.0");

        long replica = replicaId();
        blocking(ALICE, null).pushChange(PushChangeRequest.newBuilder().setDocumentId(doc.toString())
                .setChange(change(replica, 1)).build());
        failure(() -> blocking(ALICE, null).pushChange(PushChangeRequest.newBuilder().setDocumentId(doc.toString())
                .setChange(change(replica, 5)).build()));
        blocking(ALICE, null).ack(AckRequest.newBuilder().setDocumentId(doc.toString()).setReplica(replica)
                .setAppliedServerSeq(1).build());
        CompletableFuture<PushChangesResponse> bulk = new CompletableFuture<>();
        StreamObserver<PushChangesRequest> upload = async(ALICE, null).pushChanges(new StreamObserver<>() {
            @Override
            public void onNext(PushChangesResponse value) {
                bulk.complete(value);
            }

            @Override
            public void onError(Throwable t) {
                bulk.completeExceptionally(t);
            }

            @Override
            public void onCompleted() {
                // The test only counts what arrives; completion needs no action.
            }
        });
        upload.onNext(PushChangesRequest.newBuilder().setDocumentId(doc.toString()).addChanges(change(replica, 2))
                .addChanges(change(replica, 3)).build());
        upload.onCompleted();
        assertThat(bulk.get(WAIT.toMillis(), TimeUnit.MILLISECONDS).getLastAcceptedSeq()).isEqualTo(3);
        TestUsers.as(docs, ALICE).search(SearchRequest.newBuilder().setSpaceId(alice.toString()).setQuery("x").build());

        String scraped = metrics();
        assertThat(scraped).contains("wt_changes_accepted_total{" + tag + "} 3.0")
                .contains("wt_stable_lag_seq{" + tag + "}")
                .contains("wt_backlog_bytes_count{" + tag + "} 1")
                .contains("wt_ingest_seconds_count")
                .contains("wt_seq_gap_total")
                .contains("wt_push_inflight")
                .contains("wt_search_seconds_count")
                .contains("grpc_server_processing_duration_seconds_count")
                .contains("service=\"wiretuner.sync.v1.SyncService\"");

        first.cancel();
        await(() -> metrics().contains("wt_subscriptions_open{" + tag + "} 1.0"));
        second.cancel();
        await(() -> !metrics().contains("wt_subscriptions_open{" + tag));
        assertThat(metrics()).doesNotContain("wt_stable_lag_seq{" + tag);

        // A document whose sessions never acked has no lag gauge to remove.
        UUID quiet = document(ALICE);
        Subscription once = subscribe(ALICE, null, quiet, replicaId(), 0);
        once.next(FrameCase.PRESENCE);
        once.cancel();
        await(() -> !metrics().contains("wt_subscriptions_open{document=\"" + quiet));
    }
}
