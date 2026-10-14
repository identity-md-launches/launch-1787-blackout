# BlackOut (BLACKOUT)

BlackOut is a fixed-supply ERC-20. Its constructor mints **1,000,000,000 tokens
with 18 decimals** to the immediate deployer. The deployed contract exposes the
standard ERC-20 balance, allowance, approval and transfer interface.

## Contract and deployment parameters

| Parameter | Value |
| --- | --- |
| Source / Solidity identifier | `src/BlackOut.sol:BlackOut` |
| Name | `BlackOut` |
| Symbol | `BLACKOUT` |
| Decimals | `18` |
| Supply in whole tokens | `1000000000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None (`[]`) |
| Deployment transaction value | `0` |
| Initial recipient | Constructor `msg.sender` (the immediate creator) |
| Intended launch chain | Ethereum, chain ID `1` |
| Compiler / EVM target | Solidity `0.8.26` / Cancun |
| Optimizer | Enabled, 200 runs |
| Metadata hash | `none` |
| External contracts or linked libraries required | None |
| Initialization calls or application contracts | None |

`INITIAL_SUPPLY` is the public constant for the supply in smallest units. The
constructor makes one internal mint and emits one `Transfer` event from the zero
address. There is no runtime mint or burn entry point, owner, privileged role,
pause, blacklist, tax, rebase, upgrade mechanism or transfer limit.

The implementation inherits the vendored OpenZeppelin ERC-20 without overriding
its transfer or allowance behavior. Successful operations return `true`; invalid
operations revert with ERC-20 custom errors. Zero-value transfers and self
transfers are supported. Transfers to the zero address and approvals to the zero
spender revert. A finite allowance decreases on `transferFrom`; the maximum
`uint256` allowance stays unchanged. `approve` emits `Approval`, while spending an
allowance does not emit a separate `Approval` event in this implementation.

## Build and test

Run from the repository root with Foundry and Solidity 0.8.26 available:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x2bc6c643ac2daff24482bc292fc90bca3e02d038ccee68c06156efe28f32c4a9 forge test
forge fmt --check
```

All imported Solidity dependencies and their licenses are included as ordinary
files under `lib/`. No package installation, submodules, RPC, credentials or
network access is needed to build and test once the pinned compiler is installed.
Foundry FFI and filesystem permissions are disabled. Tests do not read or change
environment variables, use forks, or depend on execution order. The fuzz seed
above is passed to Foundry by the invoking shell, not read inside a test.

The tests cover:

- Exact metadata, supply, initial holder, and the single constructor mint event.
- Factory `CREATE2` deployment and allocation of the entire supply, followed by
  exact distributor claims and transfers to and from a pool address.
- Transfers, zero amounts, self transfers, full balances, contract recipients,
  approvals, replacement/revocation, finite and unlimited allowances.
- Insufficient balances/allowances, zero addresses, maximum amounts, unauthorized
  spending, and rollback of balances and allowances after failure.
- Rejection of mint, burn and administrative calls from both the deployer and an
  unrelated caller; holder transfers still succeed afterward.
- Five fuzz tests at 1,024 cases each, plus a stateful conservation invariant at
  256 runs of 64 calls across four holders. The invariant checks supply and all
  balances after arbitrary sequences of transfers, approvals and delegated
  transfers; unexpected reverts fail the run.
- Runtime size and absence of `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`.

The factory fixture tests token movements only. It does not implement or claim
to test Uniswap swap pricing or liquidity accounting. The supplied protected
checks reference separate launch infrastructure not present in this repository;
the independent launch verifier runs those integration checks.

## Deployment and operational responsibilities

The deployment artifact is `out/BlackOut.sol/BlackOut.json`. The launch operator
uses its creation bytecode with no constructor argument suffix and no ETH value.
To inspect the bytecode locally:

```sh
forge inspect src/BlackOut.sol:BlackOut bytecode
```

The IdentityMD factory must be the contract creator at launch: it receives all
`10^27` units, including when another account originates the transaction. A
different intermediate deployment helper would receive the tokens itself. The
constructor never uses `tx.origin` and does not make an external call.

Distribution belongs to the launch factory. The supplied launch terms allocate
10% to its distributor, 88% to pool seeding, and 2% to the requester's designated
remainder recipient. These are subsequent transfers, not constructor allocations
or token-level configuration. The token imposes no transfer fees or exemptions.
The launch process supplies and verifies its manifest, actual deployment
addresses, pool configuration and distribution; this project does not contain a
`launch.json` or broadcast transactions.

After deployment, the operator should verify the source and compiler settings,
name, symbol, decimals, supply, mint recipient and factory distribution receipts.
An independent security review remains a release responsibility. Local tests and
source review do not constitute an independent audit; Slither and Mythril were
not run for this deliverable.

### After launch

There are no owner settings, initialization steps, external service credentials
or maintenance transactions. Holders control their balances and the allowances
they grant. The deployer has the same rights as any other holder.

Integrators must use 18-decimal integer amounts and query `allowance` when needed.
Holders should approve only the required amount and revoke unused allowances.
For changing an existing allowance, setting it to zero and waiting for that
transaction before approving a new amount mitigates the standard ERC-20 approval
replacement race; already spent tokens cannot be recovered by revocation.

Transfers do not call recipient code or validate whether a contract can later
return tokens. Confirm recipients before sending: tokens sent to the token
contract or another inaccessible address have no administrative recovery path.
The token has no payable entry point or asset rescue function.

## Dependencies and references

See [lib/README.md](lib/README.md) for the exact dependency versions, upstream
commits, licenses and integrity checks. The interface follows
[ERC-20](https://eips.ethereum.org/EIPS/eip-20), using the vendored
[OpenZeppelin v5.4.0 implementation](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.4.0/contracts/token/ERC20/ERC20.sol).
