package com.villagecompute.wiretuner.api.account;

import static com.villagecompute.wiretuner.api.TestUsers.ERIN;
import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.account.v1.GetPreferencesRequest;
import com.villagecompute.wiretuner.account.v1.PreferenceValue;
import com.villagecompute.wiretuner.account.v1.Preferences;
import com.villagecompute.wiretuner.account.v1.SetPreferencesRequest;
import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

/** Synced preferences: stored per account, merged per key by updated_at_ms, capped at 64 KiB. */
@QuarkusTest
class PreferencesServiceTest extends ServiceTestSupport {

    @GrpcClient("account")
    AccountServiceGrpc.AccountServiceBlockingStub account;

    static PreferenceValue text(String value, long at) {
        return PreferenceValue.newBuilder().setStringValue(value).setUpdatedAtMs(at).build();
    }

    @Test
    void preferencesMergePerKeyAndStayUnderTheCap() {
        var erin = TestUsers.as(account, ERIN);
        long now = System.currentTimeMillis();
        var set = erin.setPreferences(SetPreferencesRequest.newBuilder().setChanges(Preferences.newBuilder()
                .putValues("document.new_template", text("Poster", now))).build()).getPreferences();
        assertThat(set.getValuesOrThrow("document.new_template").getStringValue()).isEqualTo("Poster");
        erin.setPreferences(SetPreferencesRequest.newBuilder().setChanges(Preferences.newBuilder()
                .putValues("document.new_template", text("Older", now - 1))).build());
        assertThat(erin.getPreferences(GetPreferencesRequest.getDefaultInstance()).getPreferences()
                .getValuesOrThrow("document.new_template").getStringValue()).isEqualTo("Poster");

        Preferences.Builder big = Preferences.newBuilder();
        for (int i = 0; i < 20; i++) {
            big.putValues("text.big_" + i, text("x".repeat(4096), now));
        }
        assertFails(() -> erin.setPreferences(SetPreferencesRequest.newBuilder().setChanges(big).build()),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
    }
}
