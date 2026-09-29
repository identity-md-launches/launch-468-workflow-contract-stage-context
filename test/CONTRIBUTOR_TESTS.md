# Additional adversarial tests

`WorkflowEdges.t.sol` checks stale price approvals, partial heartbeat rollback with a
one-wei resource shortfall, maximum grant inputs, out-of-range IDs, large reward
funding, and claim-frequency independence. Three boundary properties run 1,000 cases
each; the claim-timing comparison runs 256 cases.

`RewardModelInvariant.t.sol` runs 256 sequences of 128 calls across six actors.
Its eager per-city reward model uses the funding history and ghost levels, independently
of the implementation's lazy reward accumulator. Lifetime payouts plus outstanding
claims must match level-squared allocations within one minor unit, regardless of
claim frequency. At this sequence length, accumulated rounding error is far below one
minor unit; the tolerance permits crossing an integer boundary, not proportional loss.
Separate exact checks cover ownership, resource accounting, pool custody, supply,
authorization, pause state, and heartbeat history. Expected failures are exercised
inside the handler; any unexpected revert fails the campaign. A deterministic sequence
reaches level 20, and each randomized sequence ends by attempting every owner's claim.

Run without writing build artifacts outside the permitted scratch directory:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

The universal-transfer-tax requirement remains unmet and conflicts with the protected
exact-transfer check. The separately submitted `.imd-findings.json` contains the
reproduced failing proof. These tests extend the accepted suite and do not resolve that
source requirement. They need only the already-vendored dependencies and no RPC or
environment configuration.
