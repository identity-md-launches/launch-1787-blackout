// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BlackOut} from "../src/BlackOut.sol";

/// @dev Drives the token with an open set of holders: four seeded actors plus any address the
/// fuzzer sends tokens to, which then becomes a holder able to act. Ghost variables record what
/// the token should hold (net flow per holder, allowance per pair), and the failure paths are
/// driven in random order with the exact revert asserted and state checked unchanged afterwards.
/// `fail_on_revert` is on, so every call here either succeeds or hits an `expectRevert`.
contract BlackOutGhostHandler is Test {
    BlackOut public immutable token;
    uint256 private immutable supply;

    address[] public holders;
    mapping(address => bool) public isHolder;

    // Ghost accounting. Balance of a holder must equal seeded + in - out.
    mapping(address => uint256) public ghostSeeded;
    mapping(address => uint256) public ghostIn;
    mapping(address => uint256) public ghostOut;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    // Every (owner, spender) pair whose allowance the handler ever set, so the invariant can
    // compare each one against the ghost without walking every holder pair.
    address[] public pairOwners;
    address[] public pairSpenders;
    mapping(address => mapping(address => bool)) private pairSeen;
    uint256 public ghostMoved;
    uint256 public ghostSuccessfulCalls;
    uint256 public ghostRejectedCalls;

    constructor(BlackOut token_, address[4] memory seeded, uint256 seededAmount) {
        token = token_;
        supply = token_.totalSupply();
        for (uint256 i; i < seeded.length; ++i) {
            _track(seeded[i]);
            ghostSeeded[seeded[i]] = seededAmount;
        }
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function pairCount() external view returns (uint256) {
        return pairOwners.length;
    }

    // ---------------------------------------------------------------- happy paths

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        _transfer(from, to, amount);
    }

    /// @dev A transfer to any non-zero address, including ones that have never held the token:
    /// precompiles, the token itself, this handler. The recipient joins the holder set.
    function transferToStranger(uint256 fromSeed, uint160 strangerSeed, uint256 amount) external {
        address from = _holder(fromSeed);
        address to = address(uint160(bound(strangerSeed, 1, type(uint160).max)));
        _track(to);
        _transfer(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = _holder(ownerSeed);
        address spender = _holder(spenderSeed);
        amount = unlimited ? type(uint256).max : bound(amount, 0, supply);
        uint256 ownerBalance = token.balanceOf(owner);
        uint256 spenderBalance = token.balanceOf(spender);

        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        _setGhostAllowance(owner, spender, amount);
        ++ghostSuccessfulCalls;

        assertEq(token.allowance(owner, spender), amount, "allowance not stored");
        assertEq(token.balanceOf(owner), ownerBalance, "approve moved owner tokens");
        assertEq(token.balanceOf(spender), spenderBalance, "approve moved spender tokens");
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _holder(spenderSeed);
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 allowanceBefore = token.allowance(from, spender);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 spenderBefore = token.balanceOf(spender);
        amount = bound(amount, 0, allowanceBefore < fromBefore ? allowanceBefore : fromBefore);

        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount), "transferFrom returned false");
        ghostOut[from] += amount;
        ghostIn[to] += amount;
        ghostMoved += amount;
        if (allowanceBefore != type(uint256).max) {
            _setGhostAllowance(from, spender, allowanceBefore - amount);
        }
        ++ghostSuccessfulCalls;

        assertEq(token.allowance(from, spender), ghostAllowance[from][spender], "allowance after spend");
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self transferFrom changed balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender not debited");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient not credited");
        }
        if (spender != from && spender != to) {
            assertEq(token.balanceOf(spender), spenderBefore, "spender balance changed");
        }
    }

    // -------------------------------------------------------------- failure paths

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 attempted = balance + excess;

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, attempted)
        );
        vm.prank(from);
        token.transfer(to, attempted);
        ++ghostRejectedCalls;

        assertEq(token.balanceOf(from), balance, "failed transfer debited sender");
        assertEq(token.balanceOf(to), toBefore, "failed transfer credited recipient");
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _holder(fromSeed);
        uint256 balance = token.balanceOf(from);
        amount = bound(amount, 0, balance);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        ++ghostRejectedCalls;

        assertEq(token.balanceOf(from), balance, "transfer to zero debited sender");
        assertEq(token.balanceOf(address(0)), 0, "zero address received tokens");
    }

    function transferFromOverAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address spender = _holder(spenderSeed);
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 allowanceBefore = token.allowance(from, spender);
        if (allowanceBefore == type(uint256).max) {
            // Unlimited cannot be exceeded; turn the call into a bounded, legal one instead
            // of silently skipping so the fuzzer still does work here.
            vm.prank(from);
            assertTrue(token.approve(spender, 0), "approve returned false");
            _setGhostAllowance(from, spender, 0);
            allowanceBefore = 0;
        }
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        excess = bound(excess, 1, type(uint256).max - allowanceBefore);
        uint256 attempted = allowanceBefore + excess;

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowanceBefore, attempted
            )
        );
        vm.prank(spender);
        token.transferFrom(from, to, attempted);
        ++ghostRejectedCalls;

        assertEq(token.allowance(from, spender), allowanceBefore, "failed transferFrom changed allowance");
        assertEq(token.balanceOf(from), fromBefore, "failed transferFrom debited owner");
        assertEq(token.balanceOf(to), toBefore, "failed transferFrom credited recipient");
    }

    /// @dev Allowance covers the amount but the owner's balance does not: the allowance must be
    /// rolled back with the balances, since OZ spends it before moving tokens.
    function transferFromOverBalanceWithinAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed) external {
        address spender = _holder(spenderSeed);
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 attempted = balance + 1;

        vm.prank(from);
        assertTrue(token.approve(spender, attempted), "approve returned false");
        _setGhostAllowance(from, spender, attempted);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, attempted)
        );
        vm.prank(spender);
        token.transferFrom(from, to, attempted);
        ++ghostRejectedCalls;

        assertEq(token.allowance(from, spender), attempted, "allowance not rolled back");
        assertEq(token.balanceOf(from), balance, "owner debited on failed transferFrom");
        assertEq(token.balanceOf(to), toBefore, "recipient credited on failed transferFrom");
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _holder(ownerSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        ++ghostRejectedCalls;
        assertEq(token.allowance(owner, address(0)), 0, "zero spender gained allowance");
    }

    /// @dev Any holder, including the deployer, trying a privileged entry point: the token has
    /// none, so every such call must fail and leave supply and balances alone.
    function privilegedCall(uint256 callerSeed, uint256 targetSeed, uint8 which) external {
        address caller = _holder(callerSeed);
        address target = _holder(targetSeed);
        uint256 targetBalance = token.balanceOf(target);
        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setTransfersEnabled(bool)"
        ];
        bytes memory data = abi.encodeWithSignature(signatures[which % signatures.length], target, supply);

        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "privileged entry point exists");
        ++ghostRejectedCalls;

        assertEq(token.totalSupply(), supply, "privileged call changed supply");
        assertEq(token.balanceOf(target), targetBalance, "privileged call moved a balance");
    }

    // ------------------------------------------------------------------ internals

    function _transfer(address from, address to, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        amount = bound(amount, 0, fromBefore);

        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        ghostOut[from] += amount;
        ghostIn[to] += amount;
        ghostMoved += amount;
        ++ghostSuccessfulCalls;

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self transfer changed balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender not debited");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient not credited");
        }
    }

    function _setGhostAllowance(address owner, address spender, uint256 amount) private {
        ghostAllowance[owner][spender] = amount;
        if (!pairSeen[owner][spender]) {
            pairSeen[owner][spender] = true;
            pairOwners.push(owner);
            pairSpenders.push(spender);
        }
    }

    function _holder(uint256 seed) private view returns (address) {
        return holders[seed % holders.length];
    }

    function _track(address account) private {
        if (!isHolder[account]) {
            isHolder[account] = true;
            holders.push(account);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract BlackOutGhostInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    BlackOut private token;
    BlackOutGhostHandler private handler;
    address[4] private seeded;

    function setUp() public {
        seeded = [makeAddr("deployer"), makeAddr("holder a"), makeAddr("holder b"), makeAddr("holder c")];
        vm.startPrank(seeded[0]);
        token = new BlackOut();
        for (uint256 i = 1; i < seeded.length; ++i) {
            assertTrue(token.transfer(seeded[i], SUPPLY / seeded.length));
        }
        vm.stopPrank();

        handler = new BlackOutGhostHandler(token, seeded, SUPPLY / seeded.length);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = BlackOutGhostHandler.transfer.selector;
        selectors[1] = BlackOutGhostHandler.transferToStranger.selector;
        selectors[2] = BlackOutGhostHandler.approve.selector;
        selectors[3] = BlackOutGhostHandler.transferFrom.selector;
        selectors[4] = BlackOutGhostHandler.transferOverBalance.selector;
        selectors[5] = BlackOutGhostHandler.transferToZero.selector;
        selectors[6] = BlackOutGhostHandler.transferFromOverAllowance.selector;
        selectors[7] = BlackOutGhostHandler.transferFromOverBalanceWithinAllowance.selector;
        selectors[8] = BlackOutGhostHandler.approveZeroSpender.selector;
        selectors[9] = BlackOutGhostHandler.privilegedCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Fixed supply: never grows, never shrinks, and the constant agrees with the brief.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(SUPPLY, 10 ** 27);
    }

    /// @dev Everything minted is held by someone the handler has seen; nothing leaks or appears.
    function invariant_sumOfHolderBalancesEqualsSupply() public view {
        uint256 count = handler.holderCount();
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, token.totalSupply());
    }

    /// @dev Internal accounting equals external reality: each holder's balance is exactly what was
    /// seeded plus what flowed in minus what flowed out, so no transfer taxed, rounded or duplicated.
    function invariant_balancesMatchGhostNetFlow() public view {
        uint256 count = handler.holderCount();
        uint256 totalIn;
        uint256 totalOut;
        for (uint256 i; i < count; ++i) {
            address holder = handler.holders(i);
            uint256 expected = handler.ghostSeeded(holder) + handler.ghostIn(holder) - handler.ghostOut(holder);
            assertEq(token.balanceOf(holder), expected, "balance diverged from ghost flow");
            assertLe(token.balanceOf(holder), SUPPLY, "a balance exceeds the supply");
            totalIn += handler.ghostIn(holder);
            totalOut += handler.ghostOut(holder);
        }
        assertEq(totalIn, totalOut, "inflow and outflow disagree");
        assertEq(totalIn, handler.ghostMoved(), "moved total disagrees with flows");
    }

    /// @dev Allowances are exactly what was approved minus what was spent, unlimited stays unlimited,
    /// and failed spends never touched them.
    function invariant_allowancesMatchGhost() public view {
        uint256 pairs = handler.pairCount();
        for (uint256 i; i < pairs; ++i) {
            address owner = handler.pairOwners(i);
            address spender = handler.pairSpenders(i);
            assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender));
        }
        uint256 count = handler.holderCount();
        for (uint256 i; i < count; ++i) {
            address holder = handler.holders(i);
            assertEq(token.allowance(holder, address(0)), 0);
            assertEq(token.allowance(address(0), holder), 0);
        }
    }

    function invariant_zeroAddressNeverHoldsAndTokenHoldsNoEther() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(address(token).balance, 0);
    }

    function invariant_metadataIsImmutable() public view {
        assertEq(token.name(), "BlackOut");
        assertEq(token.symbol(), "BLACKOUT");
        assertEq(token.decimals(), 18);
    }
}
