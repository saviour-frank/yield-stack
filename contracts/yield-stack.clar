;; Title: YieldStack Protocol
;; SUMMARY
;; YieldStack is a decentralized yield aggregation protocol built for Bitcoin DeFi
;; on the Stacks Layer 2 ecosystem. It enables efficient capital allocation across 
;; multiple yield-generating strategies while maintaining Bitcoin-grade security.
;; 
;; DESCRIPTION
;; This protocol allows users to deposit SIP-010 tokens into various 
;; Bitcoin-native yield strategies. The contract manages allocations, tracks 
;; user deposits, and distributes yield based on time-weighted contributions.
;; Features include protocol whitelisting, dynamic APY management, emergency 
;; shutdown mechanisms, and flexible yield distribution strategies.

;; CONSTANTS
(define-constant contract-owner tx-sender)

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-INVALID-AMOUNT (err u1001))
(define-constant ERR-INSUFFICIENT-BALANCE (err u1002))
(define-constant ERR-PROTOCOL-NOT-WHITELISTED (err u1003))
(define-constant ERR-STRATEGY-DISABLED (err u1004))
(define-constant ERR-MAX-DEPOSIT-REACHED (err u1005))
(define-constant ERR-MIN-DEPOSIT-NOT-MET (err u1006))
(define-constant ERR-INVALID-PROTOCOL-ID (err u1007))
(define-constant ERR-PROTOCOL-EXISTS (err u1008))
(define-constant ERR-INVALID-APY (err u1009))
(define-constant ERR-INVALID-NAME (err u1010))
(define-constant ERR-INVALID-TOKEN (err u1011))
(define-constant ERR-TOKEN-NOT-WHITELISTED (err u1012))
(define-constant ERR-REENTRANT (err u2000))
(define-constant ERR-MUTEX-LOCKED (err u2001))
(define-constant ERR-MUTEX-UNLOCKED (err u2002))

;; Protocol status constants
(define-constant PROTOCOL-ACTIVE true)
(define-constant PROTOCOL-INACTIVE false)

;; Protocol constraints
(define-constant MAX-PROTOCOL-ID u100)
(define-constant MAX-APY u10000) ;; 100% APY in basis points
(define-constant MIN-APY u0)

;; DATA VARIABLES
(define-data-var total-tvl uint u0)
(define-data-var platform-fee-rate uint u100) ;; 1% (base 10000)
(define-data-var min-deposit uint u100000) ;; Minimum deposit in sats
(define-data-var max-deposit uint u1000000000) ;; Maximum deposit in sats
(define-data-var emergency-shutdown bool false)
(define-data-var mutex uint u0)

;; DATA MAPS
(define-map user-deposits 
    { user: principal } 
    { amount: uint, last-deposit-block: uint })

(define-map tx-validated-tokens
    { token: principal }
    { validated: bool })

(define-map user-rewards 
    { user: principal } 
    { pending: uint, claimed: uint })

(define-map protocols 
    { protocol-id: uint } 
    { name: (string-ascii 64), active: bool, apy: uint })

(define-map strategy-allocations 
    { protocol-id: uint } 
    { allocation: uint }) ;; allocation in basis points (100 = 1%)

(define-map whitelisted-tokens 
    { token: principal } 
    { approved: bool })

;; TRAITS
(define-trait sip-010-trait
    (
        (transfer (uint principal principal (optional (buff 34))) (response bool uint))
        (get-balance (principal) (response uint uint))
        (get-decimals () (response uint uint))
        (get-name () (response (string-ascii 32) uint))
        (get-symbol () (response (string-ascii 32) uint))
        (get-total-supply () (response uint uint))
    )
)

;; AUTHORIZATION FUNCTIONS
(define-private (is-contract-owner)
    (is-eq tx-sender contract-owner)
)

;; Define the is-contract function to check if a principal is a contract
(define-private (is-contract (principal-to-check principal))
    (let ((principal-string (unwrap-panic (to-consensus-buff? principal-to-check))))
        ;; Check if the principal is a contract by looking at its form
        ;; Contracts have a specific format that includes a deployment transaction ID
        (is-some (index-of principal-string 0x2e)) ;; '.' character in hex indicates a contract principal
    )
)

;; VALIDATION FUNCTIONS
(define-private (is-valid-protocol-id (protocol-id uint))
    (and 
        (> protocol-id u0)
        (<= protocol-id MAX-PROTOCOL-ID)
    )
)

(define-private (is-valid-apy (apy uint))
    (and 
        (>= apy MIN-APY)
        (<= apy MAX-APY)
    )
)

(define-private (is-valid-name (name (string-ascii 64)))
    (and 
        (not (is-eq name ""))
        (<= (len name) u64)
    )
)

(define-private (protocol-exists (protocol-id uint))
    (is-some (map-get? protocols { protocol-id: protocol-id }))
)

;; PROTOCOL MANAGEMENT FUNCTIONS
(define-public (add-protocol (protocol-id uint) (name (string-ascii 64)) (initial-apy uint))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (asserts! (is-valid-protocol-id protocol-id) ERR-INVALID-PROTOCOL-ID)
        (asserts! (not (protocol-exists protocol-id)) ERR-PROTOCOL-EXISTS)
        (asserts! (is-valid-name name) ERR-INVALID-NAME)
        (asserts! (is-valid-apy initial-apy) ERR-INVALID-APY)
        
        (map-set protocols { protocol-id: protocol-id }
            { 
                name: name,
                active: PROTOCOL-ACTIVE,
                apy: initial-apy
            }
        )
        (map-set strategy-allocations { protocol-id: protocol-id } { allocation: u0 })
        (ok true)
    )
)

(define-public (update-protocol-status (protocol-id uint) (active bool))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (asserts! (is-valid-protocol-id protocol-id) ERR-INVALID-PROTOCOL-ID)
        (asserts! (protocol-exists protocol-id) ERR-INVALID-PROTOCOL-ID)
        
        (let ((protocol (unwrap-panic (get-protocol protocol-id))))
            (map-set protocols { protocol-id: protocol-id }
                (merge protocol { active: active })
            )
        )
        (ok true)
    )
)

(define-public (update-protocol-apy (protocol-id uint) (new-apy uint))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (asserts! (is-valid-protocol-id protocol-id) ERR-INVALID-PROTOCOL-ID)
        (asserts! (protocol-exists protocol-id) ERR-INVALID-PROTOCOL-ID)
        (asserts! (is-valid-apy new-apy) ERR-INVALID-APY)
        
        (let ((protocol (unwrap-panic (get-protocol protocol-id))))
            (map-set protocols { protocol-id: protocol-id }
                (merge protocol { apy: new-apy })
            )
        )
        (ok true)
    )
)

;; TOKEN VALIDATION
(define-private (validate-token (token-trait <sip-010-trait>))
    (let 
        (
            (token-contract (contract-of token-trait))
            (token-info (map-get? whitelisted-tokens { token: token-contract }))
        )
        ;; First check if token is in whitelist
        (asserts! (is-some token-info) ERR-TOKEN-NOT-WHITELISTED)
        (asserts! (get approved (unwrap-panic token-info)) ERR-PROTOCOL-NOT-WHITELISTED)
        
        ;; Additional validation - verify the token implements SIP-010 correctly
        (asserts! (is-ok (contract-call? token-trait get-name)) ERR-INVALID-TOKEN)
        (asserts! (is-ok (contract-call? token-trait get-symbol)) ERR-INVALID-TOKEN)
        (asserts! (is-ok (contract-call? token-trait get-decimals)) ERR-INVALID-TOKEN)
        (asserts! (is-ok (contract-call? token-trait get-total-supply)) ERR-INVALID-TOKEN)
        
        ;; Additional check to ensure token contract is actually a contract
        (asserts! (is-contract token-contract) ERR-INVALID-TOKEN)
        
        ;; Store validated token in map for current tx
        (map-set tx-validated-tokens { token: token-contract } { validated: true })
        
        (ok token-contract)
    )
)


;; DEPOSIT AND WITHDRAWAL FUNCTIONS
(define-public (deposit (token-trait <sip-010-trait>) (amount uint))
    (begin
        ;; Use acquire-mutex to prevent reentrancy attacks
        (try! (acquire-mutex))
        
        (let
            ((result (let
                (
                    (user-principal tx-sender)
                    (current-deposit (default-to { amount: u0, last-deposit-block: u0 } 
                        (map-get? user-deposits { user: user-principal })))
                    ;; Validate token first and capture the result
                    (validated-token (try! (validate-token token-trait)))
                )
                ;; Checks
                (asserts! (not (var-get emergency-shutdown)) ERR-STRATEGY-DISABLED)
                (asserts! (> amount u0) ERR-INVALID-AMOUNT)
                (asserts! (>= amount (var-get min-deposit)) ERR-MIN-DEPOSIT-NOT-MET)
                (asserts! (<= (+ amount (get amount current-deposit)) (var-get max-deposit)) ERR-MAX-DEPOSIT-REACHED)
                
                ;; Effects - Update state before interactions
                (map-set user-deposits 
                    { user: user-principal }
                    { 
                        amount: (+ amount (get amount current-deposit)),
                        last-deposit-block: stacks-block-height
                    })
                
                (var-set total-tvl (+ (var-get total-tvl) amount))
                
                ;; Interactions - Transfer tokens last, using the validated token contract
                (try! (contract-call? token-trait transfer amount user-principal (as-contract tx-sender) none))
                
                ;; Rebalance protocols if needed
                (try! (rebalance-protocols))
                
                ;; Emit event for off-chain tracking
                (print { event: "deposit", user: user-principal, token: validated-token, amount: amount })
                
                (ok true)
            )))
            
            ;; Release mutex regardless of success or failure
            (var-set mutex u0)
            
            result
        )
    )
)

(define-public (withdraw (token-trait <sip-010-trait>) (amount uint))
    (begin
        ;; Use acquire-mutex to prevent reentrancy attacks
        (try! (acquire-mutex))
        
        (let
            ((result (let
                (
                    (user-principal tx-sender)
                    (current-deposit (default-to { amount: u0, last-deposit-block: u0 }
                        (map-get? user-deposits { user: user-principal })))
                    (validated-token (try! (validate-token token-trait)))
                )
                ;; Checks
                (asserts! (> amount u0) ERR-INVALID-AMOUNT)
                (asserts! (<= amount (get amount current-deposit)) ERR-INSUFFICIENT-BALANCE)
                (asserts! (not (var-get emergency-shutdown)) ERR-STRATEGY-DISABLED)
                
                ;; Effects - Update state before interactions
                (map-set user-deposits
                    { user: user-principal }
                    {
                        amount: (- (get amount current-deposit) amount),
                        last-deposit-block: (get last-deposit-block current-deposit)
                    })
                
                (var-set total-tvl (- (var-get total-tvl) amount))
                
                ;; Interactions - External calls come last with validated token
                (as-contract
                    (try! (contract-call? token-trait transfer amount tx-sender user-principal none)))
                
                ;; Emit event
                (print { event: "withdraw", user: user-principal, token: validated-token, amount: amount })
                
                (ok true)
            )))
            
            ;; Release mutex regardless of success or failure
            (var-set mutex u0)
            
            result
        )
    )
)

;; TOKEN TRANSFER FUNCTIONS
(define-private (safe-token-transfer (token-trait <sip-010-trait>) (amount uint) (sender principal) (recipient principal))
    (let ((validated-token (try! (validate-token token-trait))))
        ;; We've now validated the token contract, so proceed with transfer
        (contract-call? token-trait transfer amount sender recipient none)
    )
)


;; YIELD AND REWARDS FUNCTIONS
(define-private (calculate-rewards (user principal) (blocks uint))
    (let
        (
            (user-deposit (unwrap-panic (get-user-deposit user)))
            (weighted-apy (get-weighted-apy))
        )
        ;; APY calculation based on blocks passed
        (/ (* (get amount user-deposit) weighted-apy blocks) (* u10000 u144 u365))
    )
)

(define-public (claim-rewards (token-trait <sip-010-trait>))
    (begin
        ;; Use acquire-mutex to prevent reentrancy attacks
        (try! (acquire-mutex))
        
        (let
            ((result (let
                (
                    (user-principal tx-sender)
                    (validated-token (try! (validate-token token-trait)))
                    (user-deposit-opt (get-user-deposit user-principal))
                )
                ;; Check if user has deposits
                (asserts! (is-some user-deposit-opt) ERR-INSUFFICIENT-BALANCE)
                
                (let
                    (
                        (user-deposit (unwrap-panic user-deposit-opt))
                        (blocks-passed (- stacks-block-height (get last-deposit-block user-deposit)))
                        (rewards (calculate-rewards user-principal blocks-passed))
                        (current-rewards (default-to { pending: u0, claimed: u0 }
                                    (map-get? user-rewards { user: user-principal })))
                    )
                    ;; Checks
                    (asserts! (> rewards u0) ERR-INVALID-AMOUNT)
                    (asserts! (not (var-get emergency-shutdown)) ERR-STRATEGY-DISABLED)
                    
                    ;; Effects - Update state before interactions
                    (map-set user-rewards
                        { user: user-principal }
                        {
                            pending: u0,
                            claimed: (+ rewards (get claimed current-rewards))
                        })
                    
                    ;; Update last-deposit-block to reset rewards calculation
                    (map-set user-deposits
                        { user: user-principal }
                        {
                            amount: (get amount user-deposit),
                            last-deposit-block: stacks-block-height
                        })
                    
                    ;; Interactions - Transfer rewards with validated token
                    (as-contract
                        (try! (contract-call? token-trait transfer
                            rewards
                            tx-sender
                            user-principal
                            none)))
                    
                    ;; Emit event
                    (print { event: "claim-rewards", user: user-principal, token: validated-token, amount: rewards })
                    
                    (ok rewards)
                )
            )))
            
            ;; Release mutex regardless of success or failure
            (var-set mutex u0)
            
            result
        )
    )
)

;; PROTOCOL MANAGEMENT AND OPTIMIZATION
(define-private (rebalance-protocols)
    (let
        (
            (total-allocations (fold + (map get-protocol-allocation (get-protocol-list)) u0))
        )
        (asserts! (<= total-allocations u10000) ERR-INVALID-AMOUNT)
        (ok true)
    )
)

(define-private (get-weighted-apy)
    (fold + (map get-weighted-protocol-apy (get-protocol-list)) u0)
)

(define-private (get-weighted-protocol-apy (protocol-id uint))
    (let
        (
            (protocol (unwrap-panic (get-protocol protocol-id)))
            (allocation (get allocation (unwrap-panic 
                (map-get? strategy-allocations { protocol-id: protocol-id }))))
        )
        (if (get active protocol)
            (/ (* (get apy protocol) allocation) u10000)
            u0
        )
    )
)

;; GETTER FUNCTIONS
(define-read-only (get-protocol (protocol-id uint))
    (map-get? protocols { protocol-id: protocol-id })
)

(define-read-only (get-user-deposit (user principal))
    (map-get? user-deposits { user: user })
)

(define-read-only (get-total-tvl)
    (var-get total-tvl)
)

(define-read-only (is-whitelisted (token <sip-010-trait>))
    (default-to false (get approved (map-get? whitelisted-tokens { token: (contract-of token) })))
)

;; ADMIN FUNCTIONS
(define-public (set-platform-fee (new-fee uint))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (asserts! (<= new-fee u1000) ERR-INVALID-AMOUNT)
        (var-set platform-fee-rate new-fee)
        (ok true)
    )
)

(define-public (set-emergency-shutdown (shutdown bool))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        (var-set emergency-shutdown shutdown)
        (ok true)
    )
)

(define-public (whitelist-token (token principal))
    (begin
        (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
        
        ;; Minimal validation - in practice would need more checks to ensure
        ;; token implements SIP-010 trait properly
        (asserts! (is-contract token) ERR-INVALID-TOKEN)
        
        ;; Set token as approved
        (map-set whitelisted-tokens { token: token } { approved: true })
        
        ;; Emit event
        (print { event: "whitelist-token", token: token })
        
        (ok true)
    )
)

;; HELPER FUNCTIONS
(define-private (get-protocol-list)
    (list u1 u2 u3 u4 u5) ;; Supported protocol IDs
)

(define-private (get-protocol-allocation (protocol-id uint))
    (get allocation (default-to { allocation: u0 }
        (map-get? strategy-allocations { protocol-id: protocol-id })))
)

(define-private (acquire-mutex)
    (begin
        (asserts! (is-eq (var-get mutex) u0) ERR-MUTEX-LOCKED)
        (var-set mutex u1)
        (ok true)
    )
)

(define-private (release-mutex)
    (begin
        (asserts! (is-eq (var-get mutex) u1) ERR-MUTEX-UNLOCKED)
        (var-set mutex u0)
        (ok true)
    )
)