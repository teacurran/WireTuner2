package com.villagecompute.wiretuner.api.comments;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.comments.CommentOps.CommentOp;
import com.villagecompute.wiretuner.api.comments.CommentOps.CreateThread;
import com.villagecompute.wiretuner.api.comments.CommentOps.ElementWrite;
import com.villagecompute.wiretuner.api.comments.CommentOps.Foreign;
import com.villagecompute.wiretuner.api.comments.CommentOps.Id;
import com.villagecompute.wiretuner.api.comments.CommentOps.NewComments;
import com.villagecompute.wiretuner.api.comments.CommentOps.NodeOp;
import com.villagecompute.wiretuner.api.comments.CommentOps.Reaction;
import com.villagecompute.wiretuner.api.comments.CommentOps.Resolve;
import com.villagecompute.wiretuner.api.comments.CommentOps.ThreadWrite;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

import io.grpc.StatusRuntimeException;

/**
 * The per-comment ownership rules of comments.adoc (Server, Commenter role) that the effective-role
 * check applies inside a change -- the one place it looks inside one:
 *
 * <ul>
 * <li>A commenter's change may only create threads under 0:12 and touch threads: anything else is
 * refused. Editors and owners may touch anything; their ops on threads follow the rules below.</li>
 * <li>Every {@code author_account_id} written is the caller; a new comment names its author.</li>
 * <li>A comment's text, mentions and other registers are its author's to change; deleting it is also
 * the owner's.</li>
 * <li>Reactions: anyone may add or remove their own ({@code <account>:<emoji>}), nobody another's.</li>
 * <li>{@code resolved}, the pin and the thread's other registers: its opener's, and any editor's.</li>
 * <li>Deleting a thread node: its opener's and the owner's; moving it: its opener's (within 0:12) and
 * any editor's.</li>
 * </ul>
 *
 * A refusal is {@code PERMISSION_DENIED / ROLE_INSUFFICIENT}. Threads and comments the change itself
 * creates count as the caller's for its later ops.
 */
public final class CommentRules {

    /** What the server knows of the threads and comments a change names. */
    public record Known(Map<Id, UUID> openers, Map<Id, UUID> authors) {
    }

    private CommentRules() {
    }

    /** Throws {@code ROLE_INSUFFICIENT} unless every op is allowed for the caller holding {@code role}. */
    public static void check(Role role, UUID caller, List<CommentOp> ops, Known known) {
        Map<Id, UUID> openers = new HashMap<>(known.openers());
        Map<Id, UUID> authors = new HashMap<>(known.authors());
        boolean editor = role.atLeast(Role.EDITOR);
        String me = caller.toString();
        for (CommentOp op : ops) {
            switch (op) {
                case Foreign foreign -> require(editor, role, "the commenter role may only change comments");
                case CreateThread create -> {
                    require(editor || create.parent().equals(CommentOps.COMMENTS_NODE), role,
                            "a thread must be created under the comments collection");
                    openers.put(create.thread(), caller);
                }
                case NodeOp node -> {
                    UUID opener = opener(openers, node.target(), editor, role);
                    boolean own = caller.equals(opener);
                    require(!openers.containsKey(node.target()) || (node.delete() ? role == Role.OWNER || own
                            : editor || own && CommentOps.COMMENTS_NODE.equals(node.parent())), role,
                            "only the thread's opener, an editor or the owner may do that to a thread");
                }
                case ThreadWrite write -> threadWrite(openers, write.target(), editor, role, caller);
                case Resolve resolve -> threadWrite(openers, resolve.target(), editor, role, caller);
                case ElementWrite write -> {
                    opener(openers, write.target(), editor, role);
                    if (openers.containsKey(write.target())) {
                        require(write.authors().stream().allMatch(me::equals) && (!write.authorRequired()
                                || !write.authors().isEmpty()), role, "a comment's author must be the caller");
                        require(caller.equals(authors.get(write.element())) || write.ownerMay() && role == Role.OWNER,
                                role, "only its author may change a comment");
                    }
                }
                case NewComments added -> {
                    opener(openers, added.target(), editor, role);
                    for (int i = 0; i < added.elements().size(); i++) {
                        String author = i < added.comments().size() ? added.comments().get(i).getAuthorAccountId() : "";
                        require(!openers.containsKey(added.target()) || me.equals(author), role,
                                "a new comment's author must be the caller");
                        authors.put(added.elements().get(i), caller);
                    }
                }
                case Reaction reaction -> {
                    opener(openers, reaction.target(), editor, role);
                    require(!openers.containsKey(reaction.target())
                            || reaction.members().stream().allMatch(member -> member.startsWith(me + ":")), role,
                            "a reaction may only be added or removed by its own account");
                }
                default -> {
                    // Typed and Mentioned accompany an ElementWrite of the same op, checked there.
                }
            }
        }
    }

    /** A thread write: the thread's opener or an editor. */
    private static void threadWrite(Map<Id, UUID> openers, Id target, boolean editor, Role role, UUID caller) {
        UUID opener = opener(openers, target, editor, role);
        require(editor || caller.equals(opener), role, "only the thread's opener or an editor may change it");
    }

    /**
     * The opener of the target thread, or null; refuses a commenter's op on a node that is not a known
     * thread (editors' ops on other nodes are not comments and pass).
     */
    private static UUID opener(Map<Id, UUID> openers, Id target, boolean editor, Role role) {
        require(editor || openers.containsKey(target), role, "the commenter role may only change comments");
        return openers.get(target);
    }

    private static void require(boolean allowed, Role role, String why) {
        if (!allowed) {
            throw refused(role, why);
        }
    }

    static StatusRuntimeException refused(Role role, String why) {
        return StatusExceptions.roleInsufficient("editor or the comment's author (" + why + ")", role.dbName());
    }
}
