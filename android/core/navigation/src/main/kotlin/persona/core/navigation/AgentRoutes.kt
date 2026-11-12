package persona.core.navigation

import androidx.navigation3.runtime.NavKey
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The new agent page, optionally prefilled: [machineId] and [cwd] are picked when that machine is online (both can
 * still be changed), [prompt] is the first message to start from (the knowledge base's "Open Agent"). [context] is a
 * `<persona-context>` block sent ahead of the first message and shown over it (an Inbox item handed to a new Agent,
 * #5933); [tag] is what the page reports the started Agent under ([NewAgentStarts]).
 */
@Serializable @SerialName("persona.core.navigation.NewAgentRoute") data class NewAgentRoute(
    val machineId: String? = null,
    val cwd: String? = null,
    val prompt: String? = null,
    val context: String? = null,
    val tag: String? = null,
) : NavKey

/**
 * Tells a page that opened [NewAgentRoute] for something of its own which Agent it started (Inbox's "Hand to AI" ›
 * "New Agent…", #5933): it waits on a tag, opens the route with it, and the new agent page reports the session once the
 * hub has started it. Nothing is reported for a page left without starting. In memory only: after the process is gone
 * the start goes on without it.
 */
object NewAgentStarts {
    private val waiting = java.util.concurrent.ConcurrentHashMap<String, (machineId: String, sessionId: String) -> Unit>()

    fun await(tag: String, onStarted: (machineId: String, sessionId: String) -> Unit) { waiting[tag] = onStarted }

    /** The Agent started for [tag]: its waiter hears it once. */
    fun started(tag: String, machineId: String, sessionId: String) { waiting.remove(tag)?.invoke(machineId, sessionId) }
}
