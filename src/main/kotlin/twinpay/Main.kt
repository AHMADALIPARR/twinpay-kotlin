// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Ahmad Parr

package twinpay

import java.io.File

/** Wires the whole application and starts the HTTP server. */
fun main() {
    val wormFile = File(Config.wormFile)
    val worm = Worm(wormFile)
    val registry = AgentRegistry()
    val idempotency = Idempotency()
    val ledger = Ledger()
    val payments = Payments()
    val treasury = Treasury(ledger, worm, payments)
    val plaid = PlaidClient()
    val rtp = Rtp()
    val service = PaymentService(registry, idempotency, ledger, treasury, worm, payments, plaid, rtp)

    println("twinpay-kotlin starting")
    println("  token: ${Config.tokenSymbol} (${Config.tokenScale} minor units)")
    println("  plaid mode: ${plaid.mode()} (read-only)")
    println("  worm file: ${wormFile.absolutePath} (${worm.count()} blocks)")

    val api = HttpApi(registry, service, ledger, treasury, payments, worm, rtp)
    api.start()

    Runtime.getRuntime().addShutdownHook(Thread {
        api.stop()
        worm.close()
        println("twinpay-kotlin stopped")
    })

    // Park the main thread; the server runs on its own pool.
    Thread.currentThread().join()
}
