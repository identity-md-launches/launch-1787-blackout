// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BlackOut} from "../src/BlackOut.sol";

/// @dev Exercises arbitrary sequences of valid holder/spender actions among a
/// closed set of accounts. Invalid actions and atomic reverts have unit tests.
contract BlackOutHandler is Test {
    BlackOut private immutable token;
    address[4] private actors;

    constructor(BlackOut token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        amount = bound(amount, 0, fromBefore);

        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore);
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 balanceBefore = token.balanceOf(owner);
        amount = unlimited ? type(uint256).max : bound(amount, 0, token.totalSupply());

        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
        assertEq(token.balanceOf(owner), balanceBefore);
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = actors[spenderSeed % actors.length];
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowanceBefore = token.allowance(from, spender);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        amount = bound(amount, 0, allowanceBefore < fromBefore ? allowanceBefore : fromBefore);

        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        assertEq(
            token.allowance(from, spender),
            allowanceBefore == type(uint256).max ? allowanceBefore : allowanceBefore - amount
        );
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore);
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
    }
}

contract BlackOutInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    BlackOut private token;
    address[4] private actors;

    function setUp() public {
        actors = [makeAddr("holder 0"), makeAddr("holder 1"), makeAddr("holder 2"), makeAddr("holder 3")];
        vm.startPrank(actors[0]);
        token = new BlackOut();
        for (uint256 i = 1; i < actors.length; ++i) {
            assertTrue(token.transfer(actors[i], SUPPLY / actors.length));
        }
        vm.stopPrank();

        BlackOutHandler handler = new BlackOutHandler(token, actors);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = BlackOutHandler.transfer.selector;
        selectors[1] = BlackOutHandler.approve.selector;
        selectors[2] = BlackOutHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyAndHolderBalancesAreConserved() public view {
        uint256 accounted;
        for (uint256 i; i < actors.length; ++i) {
            accounted += token.balanceOf(actors[i]);
        }
        assertEq(accounted, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }
}
