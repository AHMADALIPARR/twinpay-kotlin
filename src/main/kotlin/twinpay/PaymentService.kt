package twinpay

import java.util.concurrent.atomic.AtomicLong

/**
 * Orchestrates the send → verify → post → anchor pipeline and the
 * redeem path. Redemption validates and builds the NACHA instruction
 * BEFORE the irreversible burn, so a bad routing number can never
 * strand tokens in a half-completed redemption.
 */
class PaymentService(
    private val registry: AgentRegistry,
    private val idempotency: Idempotency,
    private val ledger: Ledger,
    private val treasury: Treasury,
    private val worm: Worm,
    private val payments: Payments,
    private val plaid: PlaidClient,
    private val rtp: Rtp
) {
    private val nextId = AtomicLong(0)

    sealed interface SendResult {
        data class Ok(val paymentId: String, val wormIndex: Long, val wormHash: String) : SendResult
        data class Duplicate(val paymentId: String, val status: String) : SendResult
        data class Err(val reason: String) : SendResult
    }

    fun send(fromHandle: String, toHandle: String, amount: Long, memo: String, key: String, rail: String = "internal"): SendResult {
        val (fresh, existing) = idempotency.claim(key)
        if (!fresh) {
            val c = existing ?: Claim(null, "claimed")
            return if (c.paymentId != null) SendResult.Duplicate(c.paymentId, c.status)
            else SendResult.Err("key_in_flight")
        }
        val from = registry.lookup(fromHandle) ?: run {
            idempotency.fulfill(key, "", "failed")
            return SendResult.Err("unknown_sender")
        }
        val to = registry.lookup(toHandle) ?: run {
            idempotency.fulfill(key, "", "failed")
            return SendResult.Err("unknown_recipient")
        }
        if (from.id == to.id) {
            idempotency.fulfill(key, "", "failed")
            return SendResult.Err("self_transfer")
        }
        if (amount <= 0) {
            idempotency.fulfill(key, "", "failed")
            return SendResult.Err("invalid_amount")
        }

        val pid = "pay-${nextId.incrementAndGet()}"
        val payment = Payment(pid, Kind.TRANSFER, from.id, to.id, amount, memo, rail)
        payments.record(payment)

        return when (val r = ledger.postTransfer(pid, from.id, to.id, amount, memo)) {
            is Ledger.PostResult.Ok -> {
                val entry = EntryCodec.encode(pid, from.handle, to.handle, amount, 'T', r.seqs.first())
                val receipt = worm.commit(entry)
                payment.status = PayStatus.SETTLED
                payment.wormIndex = receipt.index
                payment.wormHash = receipt.hash
                idempotency.fulfill(key, pid, "settled")
                SendResult.Ok(pid, receipt.index, receipt.hash)
            }
            is Ledger.PostResult.AlreadyPosted -> SendResult.Err("already_processed")
            is Ledger.PostResult.Err -> {
                payment.status = PayStatus.FAILED
                idempotency.fulfill(key, pid, "failed")
                SendResult.Err(r.reason)
            }
        }
    }

    sealed interface ReverseResult {
        data class Ok(val reversalId: String, val wormIndex: Long, val wormHash: String) : ReverseResult
        data class Err(val reason: String) : ReverseResult
    }

    fun reverse(paymentId: String, reason: String, actor: String): ReverseResult {
        val original = payments.lookup(paymentId) ?: return ReverseResult.Err("unknown_payment")
        if (original.kind != Kind.TRANSFER) return ReverseResult.Err("not_reversible")
        if (original.reversedBy != null) return ReverseResult.Err("already_reversed")
        if (original.status != PayStatus.SETTLED) return ReverseResult.Err("not_settled")

        val rid = "rvsl-${nextId.incrementAndGet()}"
        val reversal = Payment(rid, Kind.REVERSAL, original.to, original.from, original.amount,
            reason, reversalOf = paymentId, actor = actor)
        payments.record(reversal)

        return when (val r = ledger.postReversal(rid, paymentId, original.to, original.from, original.amount, reason)) {
            is Ledger.PostResult.Ok -> {
                val entry = EntryCodec.encode(rid, original.to, original.from, -original.amount, 'R', r.seqs.first())
                val receipt = worm.commit(entry)
                reversal.status = PayStatus.SETTLED
                reversal.wormIndex = receipt.index
                reversal.wormHash = receipt.hash
                original.status = PayStatus.REVERSED
                original.reversedBy = rid
                ReverseResult.Ok(rid, receipt.index, receipt.hash)
            }
            is Ledger.PostResult.AlreadyPosted -> ReverseResult.Err("already_reversed")
            is Ledger.PostResult.Err -> {
                reversal.status = PayStatus.FAILED
                ReverseResult.Err(r.reason)
            }
        }
    }

    sealed interface RedeemResult {
        data class Ok(val paymentId: String, val wormIndex: Long, val wormHash: String,
                     val nachaLines: Int, val achPreview: String) : RedeemResult
        data class Err(val reason: String) : RedeemResult
    }

    /**
     * Token → fiat redemption. Steps, in order:
     *  1. Plaid fiat gate (read-only verification of a linked bank account).
     *  2. Validate routing (ABA checksum) and account, build the NACHA file.
     *  3. Burn the tokens and anchor the burn in WORM.
     * A validation failure burns nothing.
     */
    fun redeem(handle: String, tokenAmount: Long, routing: String, bankAccount: String, key: String): RedeemResult {
        val (fresh, existing) = idempotency.claim(key)
        if (!fresh) {
            val c = existing ?: Claim(null, "claimed")
            return if (c.paymentId != null) RedeemResult.Err("already_processed")
            else RedeemResult.Err("key_in_flight")
        }
        val agent = registry.lookup(handle) ?: return RedeemResult.Err("unknown_agent").also {
            idempotency.fulfill(key, "", "failed")
        }
        if (tokenAmount <= 0) return RedeemResult.Err("invalid_amount").also {
            idempotency.fulfill(key, "", "failed")
        }

        // 1. Plaid gate — read-only, fail closed.
        when (val g = plaid.fiatGate()) {
            is PlaidClient.GateResult.Err -> return RedeemResult.Err(g.reason).also {
                idempotency.fulfill(key, "", "failed")
            }
            is PlaidClient.GateResult.Ok -> Unit
        }

        // 2. Validate + build the instruction BEFORE any burn.
        if (!Ach.abaCheck(routing)) return RedeemResult.Err("invalid_routing").also {
            idempotency.fulfill(key, "", "failed")
        }
        if (bankAccount.isEmpty() || !bankAccount.all { it.isDigit() })
            return RedeemResult.Err("invalid_account").also { idempotency.fulfill(key, "", "failed") }

        val centsPerToken = Config.redemptionCentsPerToken
        val amountCents = (tokenAmount * centsPerToken) / Config.tokenScale
        if (amountCents <= 0) return RedeemResult.Err("amount_too_small").also {
            idempotency.fulfill(key, "", "failed")
        }
        val effDate = java.time.LocalDate.now()
            .format(java.time.format.DateTimeFormatter.ofPattern("yyMMdd"))
        val entry = Ach.Entry(routing, bankAccount, amountCents, agent.handle, "TWIN-$tokenAmount")
        val fileText = Ach.buildFile(listOf(entry), effDate).getOrElse {
            return RedeemResult.Err(it.message ?: "nacha_build_failed").also {
                idempotency.fulfill(key, "", "failed")
            }
        }

        // 3. Burn the tokens; anchor the burn.
        return when (val b = treasury.burn(agent.id, tokenAmount, "redemption:$routing")) {
            is Treasury.GiftResult.Ok -> {
                idempotency.fulfill(key, b.paymentId, "settled")
                RedeemResult.Ok(b.paymentId, b.wormIndex, b.wormHash,
                    fileText.lines().size, fileText.take(376))
            }
            is Treasury.GiftResult.Err -> {
                idempotency.fulfill(key, "", "failed")
                RedeemResult.Err(b.reason)
            }
        }
    }
}
