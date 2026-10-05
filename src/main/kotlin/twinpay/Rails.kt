package twinpay

import java.util.concurrent.TimeUnit

/**
 * Read-only Plaid boundary. Plaid can verify bank accounts and balances;
 * it cannot move money. Enforce mode fails closed: with no linked
 * institution, onboarding and fiat redemption are refused.
 */
class PlaidClient(
    private val mode: String = Config.plaidMode,
    private val cmd: String = Config.plaidCmd,
    private val timeoutMs: Long = Config.plaidTimeoutMs
) {
    fun mode(): String = mode

    private fun run(vararg args: String): String? {
        return try {
            val pb = ProcessBuilder(cmd, *args)
            pb.redirectErrorStream(true)
            val proc = pb.start()
            val done = proc.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            if (!done) {
                proc.destroyForcibly()
                return null
            }
            if (proc.exitValue() != 0) return null
            proc.inputStream.bufferedReader().readText().trim().ifEmpty { null }
        } catch (_: Exception) {
            null
        }
    }

    /** Raw status JSON, or null when the CLI is unavailable. */
    fun statusRaw(): String? = run("status")

    /** True when at least one institution is linked. */
    fun linked(): Boolean {
        val raw = statusRaw() ?: return false
        return try {
            val v = Json.parse(raw)
            val inst = v.obj("institution")
            inst != null && inst != JVal.Null
        } catch (_: Exception) {
            false
        }
    }

    /** Read-only account list for verification; never used to move funds. */
    fun accounts(): List<Map<String, String>> {
        val raw = run("accounts") ?: return emptyList()
        return try {
            val v = Json.parse(raw)
            val arr = v.obj("accounts") as? JVal.Arr ?: return emptyList()
            arr.list.mapNotNull { a ->
                val o = a as? JVal.Obj ?: return@mapNotNull null
                mapOf(
                    "name" to ((o.map["name"] as? JVal.Str)?.s ?: ""),
                    "type" to ((o.map["type"] as? JVal.Str)?.s ?: ""),
                    "mask" to ((o.map["mask"] as? JVal.Str)?.s ?: "")
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    /**
     * Fiat boundary gate. Returns Ok when an institution is linked and at
     * least one account is visible; Err otherwise. Mock mode always passes.
     */
    sealed interface GateResult {
        data object Ok : GateResult
        data class Err(val reason: String) : GateResult
    }

    fun fiatGate(): GateResult = when (mode) {
        "mock" -> GateResult.Ok
        "permissive" -> {
            if (linked()) GateResult.Ok else GateResult.Err("plaid_not_connected_permissive")
        }
        else -> { // enforce
            if (!linked()) return GateResult.Err("plaid_not_connected")
            if (accounts().isEmpty()) return GateResult.Err("plaid_no_accounts")
            GateResult.Ok
        }
    }
}

/** RTP-style idempotent instruction outbox. */
class Rtp {
    private val outbox = java.util.concurrent.ConcurrentHashMap<String, JVal.Obj>()
    private val keyIndex = java.util.concurrent.ConcurrentHashMap<String, String>()
    private val nextId = java.util.concurrent.atomic.AtomicLong(0)

    data class CreditResult(val instructionId: String, val status: String) // status: queued|already_queued

    fun sendCredit(toAgent: String, amount: Long, memo: String, key: String?): CreditResult {
        if (key != null) {
            keyIndex[key]?.let { return CreditResult(it, "already_queued") }
        }
        val id = "rtp-${nextId.incrementAndGet()}"
        outbox[id] = jobj(
            "id" to JVal.Str(id),
            "to" to JVal.Str(toAgent),
            "amount" to JVal.Num(amount),
            "memo" to JVal.Str(memo),
            "status" to JVal.Str("queued")
        )
        if (key != null) keyIndex[key] = id
        return CreditResult(id, "queued")
    }

    fun outboxSize(): Int = outbox.size
}
