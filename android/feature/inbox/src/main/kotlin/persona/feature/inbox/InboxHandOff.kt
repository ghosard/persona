package persona.feature.inbox

import android.content.res.Resources

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import persona.core.contracts.Session
import persona.core.contracts.contextBody
import persona.core.domain.sort.canSend
import java.time.Instant

/** What to ask for, as iOS and the old app offer it; an empty request means the first. */
fun handoffPresets(res: Resources): List<String> = listOf(R.string.inbox_handoff_preset_summary, R.string.inbox_handoff_preset_background,
    R.string.inbox_handoff_preset_handle).map(res::getString)

/** Where a mail is, so the agent can read and answer it with its own mail tools. */
data class HandOffMail(val accountId: String, val mailbox: String, val uid: Long)

/** What "Hand to AI" tells about an item: its title, its text (the hub's context, else who said what) and where it lives. */
data class HandOffItem(
    val lark: Boolean,
    val title: String,
    val context: String? = null,
    val sender: String? = null,
    val preview: String = "",
    val feedId: String? = null,
    val mail: HandOffMail? = null,
)

fun handOffItem(record: InboxRecord, context: String?): HandOffItem = HandOffItem(
    lark = record.isLark, title = record.item.title, context = context, sender = record.item.sender,
    preview = record.item.preview, feedId = record.feedId,
    mail = record.mail?.let { mail -> mail.uids.lastOrNull()?.let { HandOffMail(mail.accountId, mail.mailbox, it) } },
)

/**
 * The item as a `<persona-context>` tag the chat shows as a card, then the request (iOS `InboxHandOffSheet.message`):
 * attributes escaped, and the item's text can't close the tag early.
 */
fun handoffPrompt(res: Resources, item: HandOffItem, ask: String = ""): String =
    handoffContext(res, item) + "\n\n" + ask.trim().ifEmpty { handoffPresets(res)[0] }

/** The item alone as that tag: what "New Agent…" (#5933) sends ahead of the first message (iOS `InboxHandOffSheet.contextRef`). */
fun handoffContext(res: Resources, item: HandOffItem): String {
    val title = res.getString(if (item.lark) R.string.inbox_handoff_title_lark else R.string.inbox_handoff_title_mail, item.title)
    var text = item.context?.takeIf { it.isNotBlank() }
        ?: listOfNotNull(item.sender, item.preview).filter { it.isNotBlank() }.joinToString("：") // i18n-ignore: context for the agent
    item.feedId?.takeIf { it.isNotBlank() }?.let { text += "\n\n（飞书会话 feedId $it，可用飞书工具读更多上下文或回复）" } // i18n-ignore: tool hint for the agent
    item.mail?.let { text += "\n\n（邮件 account_id ${it.accountId}，mailbox ${it.mailbox}，uid ${it.uid}，可用 mail_read 读全文、mail_send 回复）" } // i18n-ignore: tool hint for the agent
    return contextTag(title, text)
}

/**
 * The ask typed in "Hand to AI" before "New Agent…" (#5933), by item: the sheet closes for the new agent page, and when
 * that page is left without starting, Hand to AI on the item starts from these words again. In memory only.
 */
internal object HandOffAsks {
    private val asks = java.util.concurrent.ConcurrentHashMap<String, String>()

    fun keep(itemId: String, ask: String) { if (ask.isBlank()) asks.remove(itemId) else asks[itemId] = ask }
    fun recall(itemId: String): String = asks[itemId].orEmpty()
    fun forget(itemId: String) { asks.remove(itemId) }
}

/**
 * "New Agent…" started an Agent with the item (#5933): the ask kept for a cancelled start goes, the item's source
 * remembers that Agent (never "New Agent…"), and the item is filed when [markDone], as for any Agent target. False when
 * filing it failed.
 */
internal suspend fun newAgentStarted(repository: InboxRepository, record: InboxRecord, markDone: Boolean, machineId: String, sessionId: String): Boolean {
    HandOffAsks.forget(record.item.id)
    InboxHandOffMemory.key(record.source, record.mutes)?.let { key ->
        try {
            repository.saveHandOffMemory(InboxHandOffMemory.remember(repository.handOffMemory.first(), key, InboxHandOffMemory.agent(machineId, sessionId)))
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    if (!markDone || record.item.isDone) return true
    return try { repository.setDone(record.item.id, true); true }
    catch (e: CancellationException) { throw e } catch (_: Exception) { false }
}

/** `<persona-context kind="context" title="…" url="">`, as iOS `ContextRef.xml` writes it. */
internal fun contextTag(title: String, text: String, url: String = ""): String {
    fun escape(value: String) = value.replace("&", "&amp;").replace("\"", "&quot;").replace("<", "&lt;").replace(">", "&gt;")
    return "<persona-context kind=\"context\" title=\"${escape(title)}\" url=\"${escape(url)}\">\n" +
        contextBody(text) + "\n</persona-context>"
}

/** An agent "Hand to AI" can send to: the most recently active live ones, never Persona itself (iOS: eight). */
data class HandOffTarget(val machineId: String, val sessionId: String, val title: String, val machine: String) {
    val key: String get() = "$machineId/$sessionId"
}

/**
 * Live, non-assistant sessions, newest first, at most [limit]. Sessions that cannot take a message (read-only ones
 * from other runtimes) drop out once sessions say so; until then being live is the test.
 */
fun handOffTargets(sessions: List<Session>, machines: Map<String, String> = emptyMap(), limit: Int = 8): List<HandOffTarget> =
    // Only agents that take messages: a read-only session (Codex history, an attached source without send) is left out.
    sessions.filter { !it.assistant && it.isLive && it.canSend }
        .sortedWith(compareByDescending<Session> { it.updated ?: Instant.EPOCH }.thenBy { it.key.path })
        .take(limit)
        .map { HandOffTarget(it.machineId, it.sessionId, it.displayTitle, machines[it.machineId]?.takeIf { name -> name.isNotBlank() } ?: it.machineId) }

/**
 * The operation ID of a hand-off: kept while the same text goes to the same place (a retry after an unclear failure
 * reuses it, so the outbox does not queue it twice), new for anything else.
 */
class HandOffAttempt {
    private var last: Pair<String, String>? = null

    fun operationId(text: String, target: HandOffTarget?): String {
        val key = (target?.key ?: "persona") + "\n" + text
        last?.takeIf { it.first == key }?.let { return it.second }
        return java.util.UUID.randomUUID().toString().also { last = key to it }
    }

    fun done() { last = null }
}
