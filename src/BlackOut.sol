// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title BlackOut
/// @notice Fixed-supply ERC-20: one billion BLACKOUT, with 18 decimals.
/// @dev The immediate creator receives the entire supply. For the IdentityMD
/// launch this is the factory, which handles all subsequent distribution.
contract BlackOut is ERC20 {
    /// @notice The entire supply, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Mints the supply once to the deployer; requires no parameters.
    constructor() ERC20("BlackOut", "BLACKOUT") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
