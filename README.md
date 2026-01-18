# YieldStack Protocol

## Decentralized Yield Aggregation for Bitcoin DeFi on Stacks Layer 2

## Overview

**YieldStack** is a decentralized yield aggregation protocol purpose-built for the Bitcoin DeFi ecosystem using the **Stacks Layer 2**. It empowers users to allocate SIP-010 Bitcoin-native tokens across a curated set of yield-generating strategies, all while benefiting from Bitcoin-grade security and capital-efficient infrastructure.

YieldStack facilitates **dynamic APY management**, **protocol whitelisting**, **emergency controls**, and **non-custodial yield distribution**. It is built with reentrancy protection and extensibility in mind, making it a robust core primitive for DeFi builders.

## Key Features

* **Multi-Strategy Yield Allocation**
  Deposit SIP-010 tokens into various Bitcoin-native strategies and earn yield based on time-weighted contributions.

* **Bitcoin-Grade Security**
  Built on Stacks Layer 2, benefiting from Bitcoin finality and SIP-010 token standards.

* **Dynamic APY and Allocation Rebalancing**
  Automatically rebalances yield strategies and adjusts weighted APYs across whitelisted protocols.

* **Admin Controls & Safety Mechanisms**
  Includes emergency shutdown, platform fee adjustments, and strict input validation to protect users and the protocol.

* **Non-Custodial, Transparent Accounting**
  User funds are managed in a non-custodial way with transparent state tracking via on-chain maps and logs.

## Smart Contract Components

### Constants and Configuration

* `MAX-PROTOCOL-ID`, `MIN-APY`, `MAX-APY` for protocol validation
* Platform fee: default 1% (`u100`)
* Deposit limits: min `100,000 sats`, max `1 BTC`
* Emergency shutdown toggle

### Data Structures

* `user-deposits`: Tracks per-user token deposits and block heights
* `protocols`: Registry of supported protocols and their APYs
* `strategy-allocations`: Allocation weights per protocol (in basis points)
* `user-rewards`: Pending and claimed rewards per user
* `whitelisted-tokens`: Approved SIP-010 tokens
* `tx-validated-tokens`: Temporary map for transaction-level token validation

### Traits & Interfaces

Implements the `sip-010-trait` for fungible token compatibility:

```clojure
(define-trait sip-010-trait
  ((transfer ...) (get-balance ...) (get-decimals ...) ...))
```

## Main Functions

### Deposit

```clojure
(deposit (token-trait <sip-010-trait>) (amount uint))
```

* Validates token
* Checks deposit limits and emergency shutdown
* Updates user deposit state
* Transfers tokens using SIP-010 `transfer`

### Withdraw

```clojure
(withdraw (token-trait <sip-010-trait>) (amount uint))
```

* Reduces user balance
* Returns tokens to user
* Emits withdrawal event

### Claim Rewards

```clojure
(claim-rewards (token-trait <sip-010-trait>))
```

* Calculates time-weighted APY reward
* Transfers earned tokens to user
* Resets block timestamp for future reward calculations

### Protocol Management

* `add-protocol`, `update-protocol-status`, `update-protocol-apy`
* Admin-only functions for onboarding and managing protocol strategies

### Admin Tools

* `set-platform-fee`: Adjust protocol-level fee
* `set-emergency-shutdown`: Toggle all strategy actions
* `whitelist-token`: Approve SIP-010 token for use

## Security Considerations

* **Reentrancy Protected**: Uses a `mutex` to prevent reentrancy across deposit, withdrawal, and claim flows.
* **Strict Validation**: Validates token traits, APYs, names, and protocols before processing.
* **Failsafe Shutdown**: Admin can trigger `emergency-shutdown` to halt deposits, withdrawals, and claims.

## Reward Calculation Formula

```text
reward = (deposit_amount × weighted_apy × blocks_passed) / (10000 × 144 × 365)
```

* Uses block height to determine time elapsed
* Adjusts dynamically to protocol allocation weights

## Example Usage

```clojure
;; Deposit 500,000 sats into a validated SIP-010 token
(deposit .my-token-contract u500000)

;; Claim rewards for your deposits
(claim-rewards .my-token-contract)

;; Withdraw 200,000 sats
(withdraw .my-token-contract u200000)
```

## Requirements

* Compatible with any token implementing `SIP-010` fungible token standard.
* Interacts only with whitelisted protocols and tokens.
* Requires contract owner privileges to update system parameters.

## Contributors

Developed and maintained by the YieldStack community.
Open for collaboration—PRs, audits, and proposals are welcome.
