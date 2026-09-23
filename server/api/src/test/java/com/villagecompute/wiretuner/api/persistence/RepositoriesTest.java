package com.villagecompute.wiretuner.api.persistence;

import static com.villagecompute.wiretuner.api.Reactive.tx;
import static org.assertj.core.api.Assertions.assertThat;

import java.time.Instant;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/** SRV-003: every repository persists and finds its rows inside a reactive transaction. */
@QuarkusTest
class RepositoriesTest {

    static final String HASH_A = "a".repeat(64);
    static final String HASH_B = "b".repeat(64);

    @Inject AccountRepository accounts;
    @Inject AccountIdentityRepository identities;
    @Inject DeviceRepository devices;
    @Inject TeamRepository teams;
    @Inject TeamMemberRepository teamMembers;
    @Inject DocumentRepository documents;
    @Inject DocumentMemberRepository documentMembers;
    @Inject ShareLinkRepository shareLinks;
    @Inject ShareLinkUseRepository shareLinkUses;
    @Inject ReplicaRepository replicas;
    @Inject ChangeLogRepository changeLog;
    @Inject SnapshotRepository snapshots;
    @Inject BlobRepository blobs;
    @Inject DocumentBlobRepository documentBlobs;
    @Inject DocumentSearchRepository search;
    @Inject ColdSegmentRepository coldSegments;

    @Test
    void accountsIdentitiesAndDevices() {
        Account account = newAccount();
        tx(() -> accounts.persist(account));
        assertThat(tx(() -> accounts.findBySubject(account.subject)).id).isEqualTo(account.id);
        assertThat(tx(() -> accounts.findBySubject("nobody-" + UUID.randomUUID()))).isNull();

        AccountIdentity identity = new AccountIdentity();
        identity.id = new AccountIdentityId("apple", "apple-" + account.id);
        identity.accountId = account.id;
        identity.email = "x@privaterelay.appleid.com";
        identity.emailVerified = true;
        identity.relay = true;
        tx(() -> identities.persist(identity));
        assertThat(tx(() -> identities.listForAccount(account.id)))
                .singleElement().satisfies(i -> assertThat(i.relay).isTrue());

        Device older = device(account.id, Instant.now().minusSeconds(3600));
        Device newer = device(account.id, Instant.now());
        tx(() -> devices.persist(older).chain(() -> devices.persist(newer)));
        assertThat(tx(() -> devices.listForAccount(account.id))).extracting(d -> d.id)
                .containsExactly(newer.id, older.id);
        assertThat(tx(() -> devices.findById(older.id)).authMethod).isEqualTo("apple");
    }

    @Test
    void teamsAndMembers() {
        Account owner = persisted(newAccount());
        Team team = persisted(newTeam(owner.id));
        assertThat(tx(() -> teams.findBySlug(team.slug)).id).isEqualTo(team.id);

        TeamMember member = new TeamMember();
        member.id = new TeamMemberId(team.id, owner.id);
        member.role = "owner";
        tx(() -> teamMembers.persist(member));
        assertThat(tx(() -> teamMembers.listForAccount(owner.id))).extracting(m -> m.role).containsExactly("owner");
    }

    @Test
    void documentsMembersAndShareLinks() {
        Account owner = persisted(newAccount());
        Account other = persisted(newAccount());
        Team team = persisted(newTeam(owner.id));
        Document personal = persisted(newDocument(owner.id, null, "b"));
        Document teamDoc = persisted(newDocument(null, team.id, "a"));
        assertThat(tx(() -> documents.listPersonal(owner.id))).extracting(d -> d.id).containsExactly(personal.id);
        assertThat(tx(() -> documents.listTeam(team.id))).extracting(d -> d.id).containsExactly(teamDoc.id);

        DocumentMember member = new DocumentMember();
        member.id = new DocumentMemberId(personal.id, other.id);
        member.role = "viewer";
        member.addedBy = owner.id;
        tx(() -> documentMembers.persist(member));
        assertThat(tx(() -> documentMembers.listForDocument(personal.id))).extracting(m -> m.role).containsExactly("viewer");

        ShareLink link = new ShareLink();
        link.id = UUID.randomUUID();
        link.documentId = personal.id;
        link.tokenHash = HexHash.random();
        link.role = "commenter";
        link.createdBy = owner.id;
        tx(() -> shareLinks.persist(link));
        assertThat(tx(() -> shareLinks.findByTokenHash(link.tokenHash)).id).isEqualTo(link.id);
        assertThat(tx(() -> shareLinks.listUsedBy(personal.id, other.id))).isEmpty();

        ShareLinkUse use = new ShareLinkUse();
        use.id = new ShareLinkUseId(link.id, other.id);
        tx(() -> shareLinkUses.persist(use));
        assertThat(tx(() -> shareLinkUses.findById(use.id))).isNotNull();
        assertThat(tx(() -> shareLinks.listUsedBy(personal.id, other.id))).extracting(l -> l.id).containsExactly(link.id);
    }

    @Test
    void replicasChangeLogAndSnapshots() {
        Account owner = persisted(newAccount());
        Document doc = persisted(newDocument(owner.id, null, "d"));

        Replica live = replica(doc.id, 11, owner.id, null);
        Replica retired = replica(doc.id, 12, owner.id, Instant.now());
        tx(() -> replicas.persist(live).chain(() -> replicas.persist(retired)));
        assertThat(tx(() -> replicas.listLive(doc.id))).extracting(r -> r.id.replicaId()).containsExactly(11L);

        for (long seq = 1; seq <= 3; seq++) {
            ChangeLog row = new ChangeLog();
            row.id = new ChangeLogId(doc.id, seq);
            row.replicaId = 11;
            row.seq = seq;
            row.bytes = new byte[] {(byte) seq};
            row.byteSize = 1;
            tx(() -> changeLog.persist(row));
        }
        assertThat(tx(() -> changeLog.listRange(doc.id, 2, 3))).extracting(c -> c.id.serverSeq()).containsExactly(2L, 3L);
        assertThat(tx(() -> changeLog.findById(new ChangeLogId(doc.id, 1))).bytes).containsExactly(1);

        tx(() -> snapshots.persist(snapshot(doc.id, 1)).chain(() -> snapshots.persist(snapshot(doc.id, 3))));
        assertThat(tx(() -> snapshots.findNewest(doc.id)).id.serverSeq()).isEqualTo(3L);
    }

    @Test
    void blobsAndReferences() {
        Account owner = persisted(newAccount());
        Document doc = persisted(newDocument(owner.id, null, "b"));
        Blob blob = new Blob();
        blob.sha256 = HexHash.random();
        blob.sizeBytes = 42;
        blob.mediaType = "image/png";
        blob.storageKey = "blobs/" + blob.sha256;
        tx(() -> blobs.persist(blob));
        assertThat(tx(() -> blobs.findById(blob.sha256)).mediaType).isEqualTo("image/png");

        DocumentBlob ref = new DocumentBlob();
        ref.id = new DocumentBlobId(doc.id, blob.sha256);
        tx(() -> documentBlobs.persist(ref));
        assertThat(tx(() -> documentBlobs.listForDocument(doc.id))).extracting(r -> r.id.sha256()).containsExactly(blob.sha256);

        // The thumbnail column references the blob table.
        tx(() -> documents.findById(doc.id).invoke(d -> {
            d.thumbnailBlob = blob.sha256;
            d.thumbnailAt = Instant.now();
        }));
        assertThat(tx(() -> documents.findById(doc.id)).thumbnailBlob).isEqualTo(blob.sha256);
    }

    @Test
    void searchRecordsAreNativeSql() {
        Account owner = persisted(newAccount());
        Document doc = persisted(newDocument(owner.id, null, "s"));
        assertThat(tx(() -> search.find(doc.id))).isNull();

        String marker = "zq" + Long.toString(System.nanoTime(), 36);
        assertThat(tx(() -> search.upsert(doc.id, 5, "o:Logotype " + marker, "t:hello world"))).isEqualTo(1);
        assertThat(tx(() -> search.upsert(doc.id, 9, "o:Logotype " + marker + "\np:Cover", "t:brand guide text")))
                .isEqualTo(1);
        DocumentSearchRepository.SearchRecord record = tx(() -> search.find(doc.id));
        assertThat(record.serverSeq()).isEqualTo(9L);
        assertThat(record.names()).contains("p:Cover");

        assertThat(tx(() -> search.find(doc.id)).names()).isEqualTo("o:Logotype " + marker + "\np:Cover");
    }

    @Test
    void coldSegmentsAreNativeSql() {
        Account owner = persisted(newAccount());
        Document doc = persisted(newDocument(owner.id, null, "c"));
        var later = new ColdSegmentRepository.ColdSegment(doc.id, 101, 200, "cold/2", 2048);
        var earlier = new ColdSegmentRepository.ColdSegment(doc.id, 1, 100, "cold/1", 1024);
        tx(() -> coldSegments.insert(later).chain(() -> coldSegments.insert(earlier)));
        assertThat(tx(() -> coldSegments.listForDocument(doc.id))).containsExactly(earlier, later);
    }

    <T> T persisted(T entity) {
        return tx(() -> switch (entity) {
            case Account a -> accounts.persist(a).replaceWith(entity);
            case Team t -> teams.persist(t).replaceWith(entity);
            case Document d -> documents.persist(d).replaceWith(entity);
            default -> Uni.createFrom().failure(new IllegalArgumentException(entity.toString()));
        });
    }

    static Account newAccount() {
        Account account = new Account();
        account.id = UUID.randomUUID();
        account.subject = "repo-" + account.id;
        account.email = "repo@wiretuner.local";
        account.displayName = "Repo";
        return account;
    }

    static Team newTeam(UUID owner) {
        Team team = new Team();
        team.id = UUID.randomUUID();
        team.name = "Team";
        team.slug = "team-" + team.id;
        team.ownerAccountId = owner;
        return team;
    }

    static Document newDocument(UUID owner, UUID team, String name) {
        Document doc = new Document();
        doc.id = UUID.randomUUID();
        doc.ownerAccountId = owner;
        doc.teamId = team;
        doc.name = name;
        return doc;
    }

    static Device device(UUID account, Instant seen) {
        Device device = new Device();
        device.id = new DeviceId(account, UUID.randomUUID());
        device.name = "Mac";
        device.platform = "macos";
        device.authMethod = "apple";
        device.lastSeenAt = seen;
        return device;
    }

    static Replica replica(UUID doc, long id, UUID account, Instant retired) {
        Replica replica = new Replica();
        replica.id = new ReplicaId(doc, id);
        replica.accountId = account;
        replica.deviceId = UUID.randomUUID();
        replica.retiredAt = retired;
        return replica;
    }

    static Snapshot snapshot(UUID doc, long seq) {
        Snapshot snapshot = new Snapshot();
        snapshot.id = new SnapshotId(doc, seq);
        snapshot.objectKey = "snap/" + doc + "/" + seq;
        snapshot.stateHash = seq == 1 ? HASH_A : HASH_B;
        snapshot.sizeBytes = 100;
        snapshot.nodeCount = 3;
        return snapshot;
    }

    /** Random lower-case sha256-shaped hex. */
    static final class HexHash {
        static String random() {
            return (UUID.randomUUID().toString() + UUID.randomUUID()).replace("-", "");
        }
    }
}
