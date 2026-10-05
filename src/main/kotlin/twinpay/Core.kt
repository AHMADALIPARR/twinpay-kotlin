// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Ahmad Parr

package twinpay

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Agent registry: Venmo-style @handles. */
class AgentRegistry {
    private val agents = ConcurrentHashMap<String, Agent>()
    private val nextId = AtomicLong(0)

    fun normalize(handle: String): String {
        val h = handle.trim().lowercase()
        return if (h.startsWith("@")) h else "@$h"
    }

    fun register(handle: String): Agent {
        val h = normalize(handle)
        return agents.computeIfAbsent(h) {
            Agent("agt-${nextId.incrementAndGet()}", h, System.currentTimeMillis())
        }
    }

    fun lookup(handle: String): Agent? = agents[normalize(handle)]

    fun count(): Long = nextId.get()
}

/** Idempotency key store. */
class Idempotency {
    private val claims = ConcurrentHashMap<String, Claim>()

    /** Returns true if this caller claimed the key (fresh), false if duplicate. */
    fun claim(key: String): Pair<Boolean, Claim?> {
        val fresh = Claim(null, "claimed")
        val existing = claims.putIfAbsent(key, fresh)
        return if (existing == null) true to fresh else false to existing
    }

    fun fulfill(key: String, paymentId: String, status: String) {
        claims[key] = Claim(paymentId, status)
    }

    fun read(key: String): Claim? = claims[key]
}

/** Integer-only double-entry ledger. All mutations serialized on one lock. */
class Ledger {
    sealed interface PostResult {
        data class Ok(val seqs: List<Long>) : PostResult
        data object AlreadyPosted : PostResult
        data class Err(val reason: String) : PostResult
    }

    private val lock = ReentrantLock()
    private var seq = 0L
    private val postings = mutableListOf<Posting>()
    private val byPayment = mutableMapOf<String, MutableList<Posting>>()

    private fun add(p: Posting) {
        postings += p
        byPayment.getOrPut(p.paymentId) { mutableListOf() } += p
    }

    private fun balanceLocked(account: String): Long =
        postings.filter { it.account == account }.sumOf { it.amount }

    /** Transfer: debit from, credit to. Returns Err(insufficient_funds) or AlreadyPosted. */
    fun postTransfer(paymentId: String, from: String, to: String, amount: Long, memo: String): PostResult =
        lock.withLock {
            if (byPayment.containsKey(paymentId)) return PostResult.AlreadyPosted
            if (amount <= 0) return PostResult.Err("invalid_amount")
            if (balanceLocked(from) < amount) return PostResult.Err("insufficient_funds")
            val s1 = ++seq; val s2 = ++seq
            add(Posting(s1, paymentId, from, -amount, LegKind.TRANSFER, memo))
            add(Posting(s2, paymentId, to, amount, LegKind.TRANSFER, memo))
            PostResult.Ok(listOf(s1, s2))
        }

    /** Issuance: credit to, offset to the treasury contra account. */
    fun postIssuance(paymentId: String, to: String, amount: Long, memo: String): PostResult =
        lock.withLock {
            if (byPayment.containsKey(paymentId)) return PostResult.AlreadyPosted
            if (amount <= 0) return PostResult.Err("invalid_amount")
            val s1 = ++seq; val s2 = ++seq
            add(Posting(s1, paymentId, "treasury:contra", -amount, LegKind.ISSUE, memo))
            add(Posting(s2, paymentId, to, amount, LegKind.ISSUE, memo))
            PostResult.Ok(listOf(s1, s2))
        }

    /** Burn: debit from, offset to the treasury contra account. */
    fun postBurn(paymentId: String, from: String, amount: Long, memo: String): PostResult =
        lock.withLock {
            if (byPayment.containsKey(paymentId)) return PostResult.AlreadyPosted
            if (amount <= 0) return PostResult.Err("invalid_amount")
            if (balanceLocked(from) < amount) return PostResult.Err("insufficient_funds")
            val s1 = ++seq; val s2 = ++seq
            add(Posting(s1, paymentId, from, -amount, LegKind.BURN, memo))
            add(Posting(s2, paymentId, "treasury:contra", amount, LegKind.BURN, memo))
            PostResult.Ok(listOf(s1, s2))
        }

    /**
     * Reversal of an earlier transfer payment: re-debit the recipient,
     * re-credit the sender. Offset against the ORIGINAL transfer legs,
     * so already-reversed can be detected by the payment record guard.
     */
    fun postReversal(paymentId: String, originalPaymentId: String, from: String, to: String, amount: Long, memo: String): PostResult =
        lock.withLock {
            if (byPayment.containsKey(paymentId)) return PostResult.AlreadyPosted
            if (amount <= 0) return PostResult.Err("invalid_amount")
            if (balanceLocked(from) < amount) return PostResult.Err("insufficient_funds")
            val s1 = ++seq; val s2 = ++seq
            add(Posting(s1, paymentId, from, -amount, LegKind.REVERSAL, memo))
            add(Posting(s2, paymentId, to, amount, LegKind.REVERSAL, memo))
            PostResult.Ok(listOf(s1, s2))
        }

    fun balance(account: String): Long = lock.withLock { balanceLocked(account) }

    fun legs(paymentId: String): List<Posting> = lock.withLock {
        byPayment[paymentId]?.toList() ?: emptyList()
    }

    fun journalFor(account: String, limit: Int): List<Posting> = lock.withLock {
        postings.filter { it.account == account }.takeLast(limit).reversed()
    }

    /** Every payment's legs must net to zero. */
    fun conservationCheck(): Boolean = lock.withLock {
        byPayment.values.all { legs -> legs.sumOf { it.amount } == 0L }
    }
}

/** Treasury: authorized gift (issuance) and burn; tracks supply. */
class Treasury(
    private val ledger: Ledger,
    private val worm: Worm,
    private val journal: Payments
) {
    private val supply = AtomicLong(0)
    private val nextId = AtomicLong(0)

    sealed interface GiftResult {
        data class Ok(val paymentId: String, val wormIndex: Long, val wormHash: String) : GiftResult
        data class Err(val reason: String) : GiftResult
    }

    fun gift(agentId: String, amount: Long, reason: String, issuer: String, key: String?): GiftResult {
        if (issuer !in Config.treasuryIssuers) return GiftResult.Err("unauthorized_issuer")
        if (amount <= 0) return GiftResult.Err("invalid_amount")
        val pid = "gift-${nextId.incrementAndGet()}"
        val payment = Payment(pid, Kind.GIFT, "treasury", agentId, amount, reason, actor = issuer)
        journal.record(payment)
        return when (val r = ledger.postIssuance(pid, agentId, amount, reason)) {
            is Ledger.PostResult.Ok -> {
                supply.addAndGet(amount)
                val entry = EntryCodec.encode(pid, "TREASURY", agentId, amount, 'I', r.seqs.first())
                val receipt = worm.commit(entry)
                payment.status = PayStatus.SETTLED
                payment.wormIndex = receipt.index
                payment.wormHash = receipt.hash
                GiftResult.Ok(pid, receipt.index, receipt.hash)
            }
            is Ledger.PostResult.AlreadyPosted -> GiftResult.Err("already_processed")
            is Ledger.PostResult.Err -> {
                payment.status = PayStatus.FAILED
                GiftResult.Err(r.reason)
            }
        }
    }

    fun burn(agentId: String, amount: Long, reason: String): GiftResult {
        if (amount <= 0) return GiftResult.Err("invalid_amount")
        val pid = "burn-${nextId.incrementAndGet()}"
        val payment = Payment(pid, Kind.BURN, agentId, "treasury", amount, reason)
        journal.record(payment)
        return when (val r = ledger.postBurn(pid, agentId, amount, reason)) {
            is Ledger.PostResult.Ok -> {
                supply.addAndGet(-amount)
                val entry = EntryCodec.encode(pid, agentId, "TREASURY", -amount, 'B', r.seqs.first())
                val receipt = worm.commit(entry)
                payment.status = PayStatus.SETTLED
                payment.wormIndex = receipt.index
                payment.wormHash = receipt.hash
                GiftResult.Ok(pid, receipt.index, receipt.hash)
            }
            is Ledger.PostResult.AlreadyPosted -> GiftResult.Err("already_processed")
            is Ledger.PostResult.Err -> {
                payment.status = PayStatus.FAILED
                GiftResult.Err(r.reason)
            }
        }
    }

    fun supply(): Long = supply.get()
}

/** Payment journal: every payment record by id. */
class Payments {
    private val payments = ConcurrentHashMap<String, Payment>()
    private val byAccount = ConcurrentHashMap<String, MutableList<String>>()

    fun record(p: Payment) {
        payments[p.id] = p
        byAccount.getOrPut(p.from) { mutableListOf() }.add(p.id)
        if (p.to != p.from) byAccount.getOrPut(p.to) { mutableListOf() }.add(p.id)
    }

    fun lookup(id: String): Payment? = payments[id]

    fun forAccount(account: String, limit: Int): List<Payment> =
        byAccount[account]?.takeLast(limit)?.reversed()?.mapNotNull { payments[it] } ?: emptyList()
}
