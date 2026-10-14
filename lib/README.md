# Vendored dependencies

All dependency code is stored as ordinary files, with no submodules or install
step. Upstream files are unmodified; formatting excludes this directory.

| Dependency | Version | Commit | Included files | License |
| --- | --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/c64a1edb67b6e3f4a15cca8909c9482ad33a02b0) | v5.4.0 | `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0` | ERC20, IERC20, IERC20Metadata, Context, IERC6093 error interfaces, LICENSE | MIT |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | v1.9.7 | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | Solidity `src/`, LICENSE-MIT, LICENSE-APACHE | MIT or Apache-2.0 |

The OpenZeppelin subset is the complete import closure needed by BlackOut.
forge-std is used only by the tests. The token's creation and runtime bytecode
need no external library linking.

[DEPENDENCIES.json](DEPENDENCIES.json) records the source URLs, immutable commits
and downloaded archive hashes. [SHA256SUMS](SHA256SUMS) covers every vendored
source/license file and the dependency record. Check them from the project root:

```sh
sha256sum --check lib/SHA256SUMS
```
