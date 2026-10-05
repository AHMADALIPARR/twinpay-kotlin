// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Ahmad Parr

package twinpay

import java.io.File

/** Self-contained test runner — no JUnit dependency. Run via `make test`. */
object TwinpayTest {
    private var passed = 0
    private var failed = 0

    private fun check(name: String, cond: Boolean) {
        if (cond) { passed++; println("ok - $name") }
        else { failed++; println("FAIL - $name") }
    }

    private fun freshService(plaidMode: String = "mock"): Components {
        val wormFile = File.createTempFile("worm-test", ".dat").also { it.delete() }
        val worm = Worm(wormFile)
        val registry = AgentRegistry()
        val idempotency = Idempotency()
        val ledger = Ledger()
        val payments = Payments()
        val treasury = Treasury(ledger, worm, payments)
        val plaid = PlaidClient(mode = plaidMode)
        val rtp = Rtp()
        val service = PaymentService(registry, idempotency, ledger, treasury, worm, payments, plaid, rtp)
        return Components(registry, idempotency, ledger, treasury, worm, payments, plaid, rtp, service, wormFile)
    }

    data class Components(
        val registry: AgentRegistry, val idempotency: Idempotency, val ledger: Ledger,
        val treasury: Treasury, val worm: Worm, val payments: Payments,
        val plaid: PlaidClient, val rtp: Rtp, val service: PaymentService, val wormFile: File
    )

    @JvmStatic
    fun main(args: Array<String>) {
        val c = freshService()
        val (registry, _, ledger, treasury, worm, payments, _, _, service) = c

        // 1. register + gift
        val alice = registry.register("@alice")
        val bob = registry.register("@bob")
        check("register handles", alice.handle == "@alice" && bob.handle == "@bob")
        val g = treasury.gift(alice.id, 10_000, "seed", "treasury", null)
        check("gift ok", g is Treasury.GiftResult.Ok)
        check("alice balance 10000", ledger.balance(alice.id) == 10_000L)
        check("supply 10000", treasury.supply() == 10_000L)

        // 2. transfer
        val s1 = service.send("@alice", "@bob", 2_500, "demo", "key-1")
        check("send ok", s1 is PaymentService.SendResult.Ok)
        val okId = (s1 as? PaymentService.SendResult.Ok)?.paymentId ?: ""
        check("balances after send",
            ledger.balance(alice.id) == 7_500L && ledger.balance(bob.id) == 2_500L)

        // 3. idempotent retry
        val s2 = service.send("@alice", "@bob", 2_500, "demo", "key-1")
        check("duplicate key -> already_processed",
            s2 is PaymentService.SendResult.Duplicate && s2.paymentId == okId)
        check("no double debit", ledger.balance(alice.id) == 7_500L)

        // 4. reversal
        val pid = okId
        val r1 = service.reverse(pid, "oops", "@alice")
        check("reverse ok", r1 is PaymentService.ReverseResult.Ok)
        check("balances restored",
            ledger.balance(alice.id) == 10_000L && ledger.balance(bob.id) == 0L)
        check("payment marked reversed",
            payments.lookup(pid)?.status == PayStatus.REVERSED)

        // 5. double reversal
        val r2 = service.reverse(pid, "again", "@alice")
        check("double reversal -> already_reversed",
            r2 is PaymentService.ReverseResult.Err &&
                r2.reason == "already_reversed")

        // 6. insufficient funds
        val s3 = service.send("@bob", "@alice", 1, "broke", "key-2")
        check("insufficient funds",
            s3 is PaymentService.SendResult.Err &&
                s3.reason == "insufficient_funds")

        // 7. unauthorized issuer
        val g2 = treasury.gift(bob.id, 100, "hack", "mallory", null)
        check("unauthorized issuer",
            g2 is Treasury.GiftResult.Err &&
                g2.reason == "unauthorized_issuer")

        // 8. conservation
        check("conservation ok", ledger.conservationCheck())

        // 9. worm chain
        check("worm verifies (${worm.count()} blocks)", worm.verify() == worm.count() && worm.count() > 0)

        // 10. redemption blocked without plaid in enforce mode
        val c2 = freshService(plaidMode = "enforce")
        c2.registry.register("@carol")
        c2.treasury.gift(c2.registry.lookup("@carol")!!.id, 5_000, "seed", "treasury", null)
        val rd = c2.service.redeem("@carol", 1_000, "021000021", "123456789", "rd-1")
        check("redeem blocked without plaid",
            rd is PaymentService.RedeemResult.Err &&
                rd.reason == "plaid_not_connected")
        check("no burn on failed redeem",
            c2.ledger.balance(c2.registry.lookup("@carol")!!.id) == 5_000L)

        // 11. NACHA builder: valid + invalid routing
        val good = Ach.buildFile(
            listOf(Ach.Entry("021000021", "123456789", 1000, "Carol", "TWIN-1000")), "261006")
        check("nacha valid routing builds", good.isSuccess &&
            good.getOrThrow().lines().filter { it.isNotEmpty() }.all { it.length == 94 })
        val badR = Ach.buildFile(
            listOf(Ach.Entry("123456789", "123456789", 1000, "Carol", "TWIN-1000")), "261006")
        check("nacha invalid routing rejected",
            badR.isFailure && badR.exceptionOrNull()?.message == "invalid_routing")

        // 12. redemption in mock mode builds instruction and burns (validates-before-burn order)
        val c3 = freshService(plaidMode = "mock")
        c3.registry.register("@dave")
        c3.treasury.gift(c3.registry.lookup("@dave")!!.id, 5_000, "seed", "treasury", null)
        val rdBad = c3.service.redeem("@dave", 1_000, "123456789", "123456789", "rd-2")
        check("bad routing burns nothing in mock mode",
            rdBad is PaymentService.RedeemResult.Err &&
                rdBad.reason == "invalid_routing" &&
                c3.ledger.balance(c3.registry.lookup("@dave")!!.id) == 5_000L)
        val rdOk = c3.service.redeem("@dave", 1_000, "021000021", "123456789", "rd-3")
        check("mock redeem ok with nacha preview",
            rdOk is PaymentService.RedeemResult.Ok &&
                rdOk.nachaLines > 0)
        check("burn applied after ok redeem",
            c3.ledger.balance(c3.registry.lookup("@dave")!!.id) == 4_000L &&
                c3.treasury.supply() == 4_000L)

        c.wormFile.delete(); c2.wormFile.delete(); c3.wormFile.delete()
        println("\n$passed passed, $failed failed")
        if (failed > 0) kotlin.system.exitProcess(1)
    }
}
