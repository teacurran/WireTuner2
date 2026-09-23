package gen

import (
	"fmt"
	"strconv"
	"strings"
)

func javaString(s string) string {
	if s == "" {
		return "null"
	}
	return strconv.Quote(s) // ASCII proto identifiers: Go and Java escapes agree
}

// JavaResourceName is the JSON table's resource name beside MergeTable.class.
const JavaResourceName = "merge-table.json"

// EmitJavaMergeTable renders MergeTable.java: the table as immutable maps and the version; the
// JSON document is the resource merge-table.json in the same package (Java string constants
// cap at 64 KiB, so it is not inlined).
func EmitJavaMergeTable(t *Table, javaPackage string) []byte {
	var b strings.Builder
	b.WriteString(generatedHeader)
	fmt.Fprintf(&b, `package %s;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.List;
import java.util.Map;

/**
 * The merge table (docs/spec/crdt-model.adoc, "Merge policies"): for every message reachable
 * from NodeProps, CommonProps and Node, the effective merge policy of each field.  {@link
 * #json()} is the serialized table the server sends in {@code Welcome.merge_table}.
 */
public final class MergeTable {
  /** How concurrent writes to a field are reconciled (wt.crdt.Merge without its prefix). */
  public enum Policy { ATOMIC, STRUCT, SEQUENCE, TEXT, SET, VARIANT }

  /** What a NodeRef reads as while its target is deleted or unknown (wt.crdt.RefFallback). */
  public enum RefFallback { UNSET, CACHED, PLACEHOLDER }

  /**
   * One row: the effective policy of one field.  {@code typeName}, {@code elementMessage} and
   * {@code oneof} are null when they do not apply.
   */
  public record FieldPolicy(
      int fieldNumber,
      String name,
      Policy policy,
      RefFallback onDangling,
      boolean localOnly,
      String type,
      boolean repeated,
      String typeName,
      String elementMessage,
      String oneof) {}

  /** The rows of one message, keyed by field number. */
  public record MessagePolicy(String name, Map<Integer, FieldPolicy> fields) {}

  /** A MERGE_VARIANT message: its kind discriminator and the message fields holding each case. */
  public record VariantPolicy(int kindField, List<Integer> caseFields) {}

  /** SHA-256 (hex) of the canonical JSON table without its version key. */
  public static final String VERSION = %s;

  /** The name of the JSON resource beside this class. */
  public static final String RESOURCE = %s;

`, javaPackage, strconv.Quote(t.Version()), strconv.Quote(JavaResourceName))

	b.WriteString("  /** The rows of every message, by fully qualified proto name. */\n")
	b.WriteString("  public static final Map<String, MessagePolicy> MESSAGES =\n      Map.ofEntries(\n")
	names := t.MessageNames()
	for i, name := range names {
		sep := ","
		if i == len(names)-1 {
			sep = ""
		}
		fmt.Fprintf(&b, "          Map.entry(%s, %s())%s\n", strconv.Quote(name), javaMethod(name), sep)
	}
	b.WriteString("      );\n\n")

	b.WriteString("  /** The MERGE_VARIANT messages, by fully qualified proto name. */\n")
	b.WriteString("  public static final Map<String, VariantPolicy> VARIANTS =\n      Map.ofEntries(\n")
	vnames := t.VariantNames()
	for i, name := range vnames {
		v := t.Variants[name]
		cases := make([]string, len(v.CaseFields))
		for j, c := range v.CaseFields {
			cases[j] = strconv.Itoa(int(c))
		}
		sep := ","
		if i == len(vnames)-1 {
			sep = ""
		}
		fmt.Fprintf(&b, "          Map.entry(%s, new VariantPolicy(%d, List.of(%s)))%s\n", strconv.Quote(name), v.KindField, strings.Join(cases, ", "), sep)
	}
	b.WriteString(`      );

  private MergeTable() {}

  /** The row for one field, or null when the message or field is not in the table. */
  public static FieldPolicy field(String message, int fieldNumber) {
    MessagePolicy m = MESSAGES.get(message);
    return m == null ? null : m.fields().get(fieldNumber);
  }

  /** The serialized table, UTF-8 JSON, exactly as {@code Welcome.merge_table} carries it. */
  public static byte[] json() {
    try (InputStream in = MergeTable.class.getResourceAsStream(RESOURCE)) {
      if (in == null) {
        throw new IllegalStateException(RESOURCE + " is not on the classpath beside MergeTable");
      }
      return in.readAllBytes();
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }
`)
	for _, name := range names {
		m := t.Messages[name]
		fmt.Fprintf(&b, "\n  private static MessagePolicy %s() {\n    return new MessagePolicy(\n        %s,\n        Map.ofEntries(\n", javaMethod(name), strconv.Quote(name))
		for i, f := range m.Fields {
			sep := ","
			if i == len(m.Fields)-1 {
				sep = ""
			}
			fmt.Fprintf(&b, "            Map.entry(%d, new FieldPolicy(%d, %s, Policy.%s, RefFallback.%s, %t, %s, %t, %s, %s, %s))%s\n",
				f.Number, f.Number, strconv.Quote(f.Name), f.Policy, f.OnDangling, f.LocalOnly, strconv.Quote(f.Type), f.Repeated,
				javaString(f.TypeName), javaString(f.ElementMessage), javaString(f.Oneof), sep)
		}
		b.WriteString("        ));\n  }\n")
	}
	b.WriteString("}\n")
	return []byte(b.String())
}

func javaMethod(fqn string) string {
	return "table_" + strings.ReplaceAll(fqn, ".", "_")
}
