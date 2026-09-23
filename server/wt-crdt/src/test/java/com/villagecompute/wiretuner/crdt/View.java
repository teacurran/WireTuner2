package com.villagecompute.wiretuner.crdt;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;

/**
 * The observable document, for apply-then-invert identity; mirrors WTCRDTTests' {@code View}:
 * live nodes with placement and register values, live sequence elements, set members, and each
 * text's string, attributed runs (adjacent runs with equal values merged) and live newlines'
 * paragraph values. No OpIds: an undo writes new ones.
 */
final class View {

    private View() {
    }

    static List<String> of(Engine engine) {
        NodeStore store = engine.store();
        List<String> out = new ArrayList<>();
        for (OpId node : store.nodes()) {
            Cell<Boolean> deleted = store.deleted(node);
            if (deleted != null && deleted.current().value()) {
                continue;
            }
            Placement placement = store.placement(node);
            out.add("node " + node + " kind " + store.kind(node) + " parent "
                    + (placement == null ? "none" : placement.parent() + "/" + Bytes.hex(placement.positionBytes())));
            List<RegisterPath> texts = store.textPaths(node);
            store.registers(node).forEach((path, register) -> {
                if (register.isSet() && !hidden(store, node, path, texts)) {
                    out.add("  " + path + " = " + Bytes.hex(register.value()));
                }
            });
            TreeSet<RegisterPath> sequences = new TreeSet<>();
            for (RegisterPath path : store.elements(node).keySet()) {
                if (!hidden(store, node, path, texts)) {
                    sequences.add(path.parent());
                }
            }
            for (RegisterPath sequence : sequences) {
                StringBuilder line = new StringBuilder("  " + sequence + ":");
                for (OpId element : store.elementOrder(node, sequence)) {
                    Element e = store.element(node, sequence.element(element));
                    if (!e.isDeleted()) {
                        line.append(' ').append(element).append('@').append(Bytes.hex(e.position().current().value()));
                    }
                }
                out.add(line.toString());
            }
            for (RegisterPath path : store.setPaths(node)) {
                out.add("  " + path + " members " + String.join(" ", store.members(node, path).stream().map(Bytes::hex).toList()));
            }
            for (RegisterPath path : texts) {
                TextSequence text = store.text(node, path);
                List<String> runs = new ArrayList<>();
                List<Integer> lengths = new ArrayList<>();
                for (TextRun run : text.runs()) {
                    String values = String.join("", run.attributes().stream().map(a -> " " + Bytes.hex(a.value())).toList());
                    if (!runs.isEmpty() && runs.get(runs.size() - 1).equals(values)) {
                        lengths.set(lengths.size() - 1, lengths.get(lengths.size() - 1) + run.length());
                    } else {
                        runs.add(values);
                        lengths.add(run.length());
                    }
                }
                StringBuilder line = new StringBuilder("  " + path + " \"" + text.string() + "\" ");
                for (int i = 0; i < runs.size(); i++) {
                    line.append('[').append(lengths.get(i)).append(runs.get(i)).append(']');
                }
                out.add(line.toString());
                for (OpId c : text.liveChars()) {
                    if (text.codepoint(c) != 0x0A) {
                        continue;
                    }
                    RegisterPath prefix = path.element(c);
                    List<String> values = new ArrayList<>();
                    for (Map.Entry<RegisterPath, Register> entry : store.registers(node).entrySet()) {
                        List<RegisterPath.Segment> segments = entry.getKey().segments();
                        int length = prefix.segments().size();
                        if (segments.size() > length && segments.subList(0, length).equals(prefix.segments()) && entry.getValue().isSet()) {
                            values.add(String.join(".", segments.subList(length, segments.size()).stream().map(Object::toString).toList())
                                    + "=" + Bytes.hex(entry.getValue().value()));
                        }
                    }
                    out.add("  paragraph at " + text.offset(c) + ": " + String.join(" ", values));
                }
            }
        }
        return out;
    }

    // Registers and elements under a tombstoned element or any character are not shown directly.
    private static boolean hidden(NodeStore store, OpId node, RegisterPath path, List<RegisterPath> texts) {
        List<RegisterPath.Segment> segments = path.segments();
        for (int index = 1; index < segments.size(); index++) {
            if (!segments.get(index).isElement()) {
                continue;
            }
            RegisterPath prefix = RegisterPath.of(segments.subList(0, index + 1));
            Element element = store.element(node, prefix);
            if (texts.contains(prefix.parent()) || element != null && element.isDeleted() && !prefix.equals(path)) {
                return true;
            }
        }
        return false;
    }
}
