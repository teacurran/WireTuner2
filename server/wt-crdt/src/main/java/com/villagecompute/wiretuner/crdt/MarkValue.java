package com.villagecompute.wiretuner.crdt;

/** Reading a {@code TextMarkValue}: which attribute it sets and whether it clears it. Mirrors {@code WTCRDT.MarkValue}. */
final class MarkValue {

    private MarkValue() {
    }

    /**
     * The attribute {@code value} sets: its last record's field number, plus the embedded
     * {@code tag} records (field 1) when that field is {@code featureField}; {@code null} when it
     * sets none or does not parse.
     */
    static MarkKey key(byte[] value, Integer featureField) {
        WireMessage message = WireMessage.parse(value);
        Integer field = message == null ? null : message.lastField();
        if (field == null) {
            return null;
        }
        if (!field.equals(featureField)) {
            return new MarkKey(field);
        }
        WireMessage feature = message.message(field);
        byte[] tag = feature == null ? null : feature.records(1);
        return new MarkKey(field, tag == null ? new byte[0] : tag);
    }

    /**
     * Whether {@code value}'s attribute holds its default -- a zero varint or fixed value, or an
     * empty length-delimited payload (for a {@code feature}, nothing but its tag) -- which reads as
     * the attribute cleared.
     */
    static boolean isCleared(byte[] value, MarkKey key) {
        WireMessage message = WireMessage.parse(value);
        byte[] last = message == null ? null : message.lastRecordPayload();
        if (last == null) {
            return false;
        }
        byte[] tag = key.tag();
        int from = tag.length > 0 && last.length >= tag.length
                && java.util.Arrays.equals(last, 0, tag.length, tag, 0, tag.length) ? tag.length : 0;
        for (int i = from; i < last.length; i++) {
            if (last[i] != 0) {
                return false;
            }
        }
        return true;
    }

    /** A value clearing the attribute of {@code value} (same case, default payload; a feature keeps its tag). */
    static byte[] cleared(byte[] value, MarkKey key) {
        WireMessage message = WireMessage.parse(value);
        Integer wireType = message == null ? null : message.lastWireType();
        if (wireType == null) {
            return new byte[0];
        }
        WireWriter out = new WireWriter();
        switch (wireType) {
            case WireMessage.VARINT -> out.varintField(key.field(), 0, true);
            case WireMessage.FIXED64 -> {
                out.tag(key.field(), WireMessage.FIXED64);
                out.raw(new byte[8]);
            }
            case WireMessage.FIXED32 -> {
                out.tag(key.field(), WireMessage.FIXED32);
                out.raw(new byte[4]);
            }
            default -> out.lenField(key.field(), key.tag());
        }
        return out.bytes();
    }
}
