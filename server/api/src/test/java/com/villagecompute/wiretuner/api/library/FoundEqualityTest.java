package com.villagecompute.wiretuner.api.library;

import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.RecordContent;
import com.villagecompute.wiretuner.api.persistence.TeamColorLibraryRepository.Listed;

/** A library found for Fetch compares its stored colors by content (Sonar java:S6218). */
class FoundEqualityTest {

    @Test
    void foundLibrariesCompareTheirColors() {
        UUID doc = UUID.randomUUID();
        UUID team = UUID.randomUUID();
        Listed listed = new Listed(doc, team, "Brand", true, 3, team, 4, 5, null);
        Listed other = new Listed(doc, team, "Other", true, 3, team, 4, 5, null);
        RecordContent.byContent(() -> new ColorLibraryGrpcService.Found(listed, new byte[] {1, 2}), "colors=2 bytes",
                new ColorLibraryGrpcService.Found(other, new byte[] {1, 2}),
                new ColorLibraryGrpcService.Found(listed, new byte[] {1, 3}));
    }
}
