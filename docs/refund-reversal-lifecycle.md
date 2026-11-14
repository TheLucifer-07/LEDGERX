# Refund and reversal lifecycle

Refunds are new postings linked to a posted capture; they never edit or delete the capture journal. A refund is permitted only while the sum of refund transactions that remain `posted` stays within the original capture amount.

```mermaid
flowchart TD
    Capture[Posted capture]
    Request[Refund request with idempotency key]
    Lock[Lock original capture row]
    Check[Sum refund rows whose transactions are still posted]
    Allowed{Active total plus request<br/>within capture amount?}
    Refund[Post refund transaction<br/>debit merchant / credit customer]
    History[Append refunds link and audit history]
    Followup{Optional later action}
    Refuse[Reject request<br/>caller transaction rolls back]
    ReverseRequest[Reverse refund request]
    Compensate[Post compensating journal<br/>update refund transaction to reversed]
    Keep[Keep refund row and both journals<br/>release refundable capacity]
    CaptureReverse[Full capture reversal request]
    HasPosted{Any linked refund<br/>still posted?}
    ReverseCapture[Post exact opposite of capture lines<br/>mark capture reversed]
    CaptureReject[Reject full reversal]

    Capture --> Request --> Lock --> Check --> Allowed
    Allowed -- no --> Refuse
    Allowed -- yes --> Refund --> History --> Followup
    Followup -- another partial refund --> Request
    Followup -- reverse this refund --> ReverseRequest --> Compensate --> Keep
    Followup -- try full capture reversal --> CaptureReverse
    Capture -->|no refund history| CaptureReverse
    Keep --> CaptureReverse
    CaptureReverse --> HasPosted
    HasPosted -- yes --> CaptureReject
    HasPosted -- no --> ReverseCapture
```

Each refund is a separate transaction and can be reversed independently. A reversed refund remains visible in history but no longer counts against the capture's refundable amount. A capture with any active posted refund cannot be fully reversed. A reversal of a reversal is rejected in V1.

## SQL and test references

- [Refund cap, original-transaction locking, and compensating journals](../database/migrations/0004_financial_operations.sql)
- [Active-refund semantics, reversal integrity checks, and refund history view](../database/migrations/0010_refund_reversal_and_projection_integrity.sql)
- [Refund, cap, reversal, and retry assertions](../tests/financial_operations.sql)
- [Concurrent refund cap scenario](../tests/concurrency/refund_a.sql) and [competing request](../tests/concurrency/refund_b.sql)
- [Test runner](../scripts/test-financial.sh) and [concurrency runner](../scripts/test-concurrency.sh)
