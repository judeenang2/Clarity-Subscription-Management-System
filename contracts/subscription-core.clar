;; Subscription Core Management Contract
;; Handles subscription lifecycle, plans, and user management

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-PLAN (err u101))
(define-constant ERR-INSUFFICIENT-FUNDS (err u102))
(define-constant ERR-SUBSCRIPTION-NOT-FOUND (err u103))
(define-constant ERR-INVALID-INPUT (err u104))
(define-constant ERR-PLAN-NOT-FOUND (err u105))
(define-constant ERR-SUBSCRIPTION-ALREADY-EXISTS (err u106))
(define-constant ERR-SUBSCRIPTION-EXPIRED (err u107))
(define-constant ERR-INVALID-STATUS (err u108))
(define-constant ERR-UPGRADE-NOT-ALLOWED (err u109))
(define-constant ERR-DOWNGRADE-NOT-ALLOWED (err u110))
(define-constant ERR-CANCELLATION-NOT-ALLOWED (err u111))
(define-constant ERR-PLAN-LIMIT-EXCEEDED (err u112))

;; Data Variables
(define-data-var next-plan-id uint u1)
(define-data-var next-subscription-id uint u1)
(define-data-var contract-paused bool false)
(define-data-var max-plans-per-user uint u5)
(define-data-var grace-period-days uint u7)

;; Data Maps
(define-map subscription-plans
  { plan-id: uint }
  {
    name: (string-ascii 50),
    description: (string-ascii 200),
    price: uint,
    billing-cycle-days: uint,
    features: (list 10 (string-ascii 30)),
    max-users: uint,
    is-active: bool,
    created-at: uint,
    updated-at: uint
  }
)

(define-map user-subscriptions
  { subscription-id: uint }
  {
    user: principal,
    plan-id: uint,
    start-date: uint,
    next-billing-date: uint,
    status: (string-ascii 20),
    custom-features: (list 5 (string-ascii 30)),
    total-paid: uint,
    billing-failures: uint,
    last-updated: uint,
    auto-renew: bool
  }
)

(define-map user-subscription-count
  { user: principal }
  { count: uint }
)

(define-map subscription-usage
  { subscription-id: uint, period: uint }
  {
    usage-count: uint,
    last-activity: uint,
    feature-usage: (list 10 { feature: (string-ascii 30), count: uint }),
    overage-charges: uint
  }
)

(define-map plan-analytics
  { plan-id: uint, period: uint }
  {
    active-subscriptions: uint,
    new-subscriptions: uint,
    cancelled-subscriptions: uint,
    revenue-generated: uint,
    churn-rate: uint
  }
)

;; Read-only functions

(define-read-only (get-subscription-plan (plan-id uint))
  (map-get? subscription-plans { plan-id: plan-id })
)

(define-read-only (get-user-subscription (subscription-id uint))
  (map-get? user-subscriptions { subscription-id: subscription-id })
)

(define-read-only (get-user-subscription-count (user principal))
  (default-to { count: u0 } (map-get? user-subscription-count { user: user }))
)

(define-read-only (get-subscription-usage (subscription-id uint) (period uint))
  (map-get? subscription-usage { subscription-id: subscription-id, period: period })
)

(define-read-only (is-subscription-active (subscription-id uint))
  (match (get-user-subscription subscription-id)
    subscription
      (and
        (is-eq (get status subscription) "active")
        (>= (get next-billing-date subscription) block-height)
      )
    false
  )
)

(define-read-only (calculate-prorated-amount (subscription-id uint) (cancellation-date uint))
  (match (get-user-subscription subscription-id)
    subscription
      (match (get-subscription-plan (get plan-id subscription))
        plan
          (let (
            (days-used (/ (- cancellation-date (get start-date subscription)) u144)) ;; blocks per day
            (total-days (get billing-cycle-days plan))
            (days-remaining (- total-days days-used))
            (daily-rate (/ (get price plan) total-days))
          )
            (if (> days-remaining u0)
              (ok (* daily-rate days-remaining))
              (ok u0)
            )
          )
        ERR-PLAN-NOT-FOUND
      )
    ERR-SUBSCRIPTION-NOT-FOUND
  )
)

;; Administrative functions

(define-public (pause-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set contract-paused true)
    (ok true)
  )
)

(define-public (unpause-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set contract-paused false)
    (ok true)
  )
)

(define-public (set-max-plans-per-user (max-plans uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> max-plans u0) ERR-INVALID-INPUT)
    (asserts! (<= max-plans u10) ERR-INVALID-INPUT)
    (var-set max-plans-per-user max-plans)
    (ok max-plans)
  )
)

(define-public (set-grace-period (days uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (<= days u30) ERR-INVALID-INPUT)
    (var-set grace-period-days days)
    (ok days)
  )
)

;; Plan management functions

(define-public (create-subscription-plan
  (name (string-ascii 50))
  (description (string-ascii 200))
  (price uint)
  (billing-cycle-days uint)
  (features (list 10 (string-ascii 30)))
  (max-users uint)
)
  (let (
    (plan-id (var-get next-plan-id))
  )
    (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> (len name) u0) ERR-INVALID-INPUT)
    (asserts! (> price u0) ERR-INVALID-INPUT)
    (asserts! (> billing-cycle-days u0) ERR-INVALID-INPUT)
    (asserts! (> max-users u0) ERR-INVALID-INPUT)

    (map-set subscription-plans
      { plan-id: plan-id }
      {
        name: name,
        description: description,
        price: price,
        billing-cycle-days: billing-cycle-days,
        features: features,
        max-users: max-users,
        is-active: true,
        created-at: block-height,
        updated-at: block-height
      }
    )

    (var-set next-plan-id (+ plan-id u1))
    (ok plan-id)
  )
)

(define-public (update-subscription-plan
  (plan-id uint)
  (name (string-ascii 50))
  (description (string-ascii 200))
  (price uint)
  (features (list 10 (string-ascii 30)))
  (is-active bool)
)
  (match (get-subscription-plan plan-id)
    plan
      (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (asserts! (> (len name) u0) ERR-INVALID-INPUT)
        (asserts! (> price u0) ERR-INVALID-INPUT)

        (map-set subscription-plans
          { plan-id: plan-id }
          (merge plan {
            name: name,
            description: description,
            price: price,
            features: features,
            is-active: is-active,
            updated-at: block-height
          })
        )
        (ok true)
      )
    ERR-PLAN-NOT-FOUND
  )
)

(define-public (deactivate-plan (plan-id uint))
  (match (get-subscription-plan plan-id)
    plan
      (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (map-set subscription-plans
          { plan-id: plan-id }
          (merge plan { is-active: false, updated-at: block-height })
        )
        (ok true)
      )
    ERR-PLAN-NOT-FOUND
  )
)

;; Subscription management functions

(define-public (subscribe-to-plan (plan-id uint) (payment-amount uint))
  (match (get-subscription-plan plan-id)
    plan
      (let (
        (subscription-id (var-get next-subscription-id))
        (user-count (get count (get-user-subscription-count tx-sender)))
        (next-billing (+ block-height (* (get billing-cycle-days plan) u144)))
      )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (get is-active plan) ERR-INVALID-PLAN)
        (asserts! (>= payment-amount (get price plan)) ERR-INSUFFICIENT-FUNDS)
        (asserts! (< user-count (var-get max-plans-per-user)) ERR-PLAN-LIMIT-EXCEEDED)

        ;; Create subscription
        (map-set user-subscriptions
          { subscription-id: subscription-id }
          {
            user: tx-sender,
            plan-id: plan-id,
            start-date: block-height,
            next-billing-date: next-billing,
            status: "active",
            custom-features: (list),
            total-paid: payment-amount,
            billing-failures: u0,
            last-updated: block-height,
            auto-renew: true
          }
        )

        ;; Update user subscription count
        (map-set user-subscription-count
          { user: tx-sender }
          { count: (+ user-count u1) }
        )

        ;; Update plan analytics
        (update-plan-analytics plan-id "new-subscription" u1)

        (var-set next-subscription-id (+ subscription-id u1))
        (ok subscription-id)
      )
    ERR-PLAN-NOT-FOUND
  )
)

(define-public (upgrade-subscription (subscription-id uint) (new-plan-id uint) (payment-amount uint))
  (match (get-user-subscription subscription-id)
    subscription
      (match (get-subscription-plan new-plan-id)
        new-plan
          (match (get-subscription-plan (get plan-id subscription))
            current-plan
              (begin
                (asserts! (is-eq tx-sender (get user subscription)) ERR-NOT-AUTHORIZED)
                (asserts! (is-eq (get status subscription) "active") ERR-INVALID-STATUS)
                (asserts! (get is-active new-plan) ERR-INVALID-PLAN)
                (asserts! (> (get price new-plan) (get price current-plan)) ERR-UPGRADE-NOT-ALLOWED)
                (asserts! (>= payment-amount (get price new-plan)) ERR-INSUFFICIENT-FUNDS)

                ;; Calculate prorated refund for current plan
                (let (
                  (prorated-refund (unwrap! (calculate-prorated-amount subscription-id block-height) ERR-INVALID-INPUT))
                  (net-payment (- payment-amount prorated-refund))
                )
                  ;; Update subscription
                  (map-set user-subscriptions
                    { subscription-id: subscription-id }
                    (merge subscription {
                      plan-id: new-plan-id,
                      next-billing-date: (+ block-height (* (get billing-cycle-days new-plan) u144)),
                      total-paid: (+ (get total-paid subscription) net-payment),
                      last-updated: block-height
                    })
                  )

                  ;; Update analytics
                  (update-plan-analytics (get plan-id subscription) "cancelled-subscription" u1)
                  (update-plan-analytics new-plan-id "new-subscription" u1)

                  (ok true)
                )
              )
            ERR-PLAN-NOT-FOUND
          )
        ERR-PLAN-NOT-FOUND
      )
    ERR-SUBSCRIPTION-NOT-FOUND
  )
)

(define-public (downgrade-subscription (subscription-id uint) (new-plan-id uint))
  (match (get-user-subscription subscription-id)
    subscription
      (match (get-subscription-plan new-plan-id)
        new-plan
          (match (get-subscription-plan (get plan-id subscription))
            current-plan
              (begin
                (asserts! (is-eq tx-sender (get user subscription)) ERR-NOT-AUTHORIZED)
                (asserts! (is-eq (get status subscription) "active") ERR-INVALID-STATUS)
                (asserts! (get is-active new-plan) ERR-INVALID-PLAN)
                (asserts! (< (get price new-plan) (get price current-plan)) ERR-DOWNGRADE-NOT-ALLOWED)

                ;; Schedule downgrade for next billing cycle
                (map-set user-subscriptions
                  { subscription-id: subscription-id }
                  (merge subscription {
                    status: "pending-downgrade",
                    custom-features: (get custom-features subscription),
                    last-updated: block-height
                  })
                )

                (ok true)
              )
            ERR-PLAN-NOT-FOUND
          )
        ERR-PLAN-NOT-FOUND
      )
    ERR-SUBSCRIPTION-NOT-FOUND
  )
)

(define-public (cancel-subscription (subscription-id uint))
  (match (get-user-subscription subscription-id)
    subscription
      (begin
        (asserts! (is-eq tx-sender (get user subscription)) ERR-NOT-AUTHORIZED)
        (asserts! (or (is-eq (get status subscription) "active") (is-eq (get status subscription) "pending-downgrade")) ERR-CANCELLATION-NOT-ALLOWED)

        ;; Update subscription status
        (map-set user-subscriptions
          { subscription-id: subscription-id }
          (merge subscription {
            status: "cancelled",
            auto-renew: false,
            last-updated: block-height
          })
        )

        ;; Update user subscription count
        (let (
          (user-count (get count (get-user-subscription-count (get user subscription))))
        )
          (map-set user-subscription-count
            { user: (get user subscription) }
            { count: (if (> user-count u0) (- user-count u1) u0) }
          )
        )

        ;; Update plan analytics
        (update-plan-analytics (get plan-id subscription) "cancelled-subscription" u1)

        (ok true)
      )
    ERR-SUBSCRIPTION-NOT-FOUND
  )
)

(define-public (reactivate-subscription (subscription-id uint) (payment-amount uint))
  (match (get-user-subscription subscription-id)
    subscription
      (match (get-subscription-plan (get plan-id subscription))
        plan
          (begin
            (asserts! (is-eq tx-sender (get user subscription)) ERR-NOT-AUTHORIZED)
            (asserts! (is-eq (get status subscription) "cancelled") ERR-INVALID-STATUS)
            (asserts! (get is-active plan) ERR-INVALID-PLAN)
            (asserts! (>= payment-amount (get price plan)) ERR-INSUFFICIENT-FUNDS)

            ;; Reactivate subscription
            (map-set user-subscriptions
              { subscription-id: subscription-id }
              (merge subscription {
                status: "active",
                next-billing-date: (+ block-height (* (get billing-cycle-days plan) u144)),
                total-paid: (+ (get total-paid subscription) payment-amount),
                auto-renew: true,
                last-updated: block-height
              })
            )

            ;; Update user subscription count
            (let (
              (user-count (get count (get-user-subscription-count (get user subscription))))
            )
              (map-set user-subscription-count
                { user: (get user subscription) }
                { count: (+ user-count u1) }
              )
            )

            ;; Update plan analytics
            (update-plan-analytics (get plan-id subscription) "new-subscription" u1)

            (ok true)
          )
        ERR-PLAN-NOT-FOUND
      )
    ERR-SUBSCRIPTION-NOT-FOUND
  )
)

;; Usage tracking

(define-public (track-subscription-usage (subscription-id uint) (feature (string-ascii 30)) (usage-count uint))
  (let (
    (current-period (/ block-height u4320)) ;; Monthly periods
  )
    (match (get-user-subscription subscription-id)
      subscription
        (begin
          (asserts! (is-eq tx-sender (get user subscription)) ERR-NOT-AUTHORIZED)
          (asserts! (is-subscription-active subscription-id) ERR-SUBSCRIPTION-EXPIRED)

          (match (get-subscription-usage subscription-id current-period)
            existing-usage
              (map-set subscription-usage
                { subscription-id: subscription-id, period: current-period }
                (merge existing-usage {
                  usage-count: (+ (get usage-count existing-usage) usage-count),
                  last-activity: block-height,
                  feature-usage: (update-feature-usage (get feature-usage existing-usage) feature usage-count)
                })
              )
            ;; Create new usage record
            (map-set subscription-usage
              { subscription-id: subscription-id, period: current-period }
              {
                usage-count: usage-count,
                last-activity: block-height,
                feature-usage: (list { feature: feature, count: usage-count }),
                overage-charges: u0
              }
            )
          )
          (ok true)
        )
      ERR-SUBSCRIPTION-NOT-FOUND
    )
  )
)

;; Helper functions

(define-private (update-plan-analytics (plan-id uint) (metric (string-ascii 30)) (value uint))
  (let (
    (current-period (/ block-height u4320))
  )
    (match (map-get? plan-analytics { plan-id: plan-id, period: current-period })
      existing
        (map-set plan-analytics
          { plan-id: plan-id, period: current-period }
          (if (is-eq metric "new-subscription")
            (merge existing { new-subscriptions: (+ (get new-subscriptions existing) value) })
            (if (is-eq metric "cancelled-subscription")
              (merge existing { cancelled-subscriptions: (+ (get cancelled-subscriptions existing) value) })
              existing
            )
          )
        )
      (map-set plan-analytics
        { plan-id: plan-id, period: current-period }
        {
          active-subscriptions: u0,
          new-subscriptions: (if (is-eq metric "new-subscription") value u0),
          cancelled-subscriptions: (if (is-eq metric "cancelled-subscription") value u0),
          revenue-generated: u0,
          churn-rate: u0
        }
      )
    )
  )
)

(define-private (update-feature-usage
  (current-usage (list 10 { feature: (string-ascii 30), count: uint }))
  (feature (string-ascii 30))
  (usage-count uint)
)
  ;; Simplified implementation - in practice would need more complex list manipulation
  (unwrap-panic (as-max-len? (append current-usage { feature: feature, count: usage-count }) u10))
)
