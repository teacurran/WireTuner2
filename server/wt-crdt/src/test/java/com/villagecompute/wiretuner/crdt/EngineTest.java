package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class EngineTest {

    @Test
    void versionIsTheDeclaredConstant() {
        assertThat(Engine.version()).isEqualTo(Engine.VERSION).matches("\\d+\\.\\d+\\.\\d+");
    }
}
