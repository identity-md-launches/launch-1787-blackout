// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BlackOut} from "../src/BlackOut.sol";

/// @dev Deploys from raw creation code the way the launch factory does: CREATE2 in assembly, with
/// the supply check made inside the same call, since the real launch is one transaction.
contract RawCreateFixture {
    function deployCreate2(bytes memory code, bytes32 salt, uint256 expectedSupply)
        external
        returns (address deployed)
    {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
        require(BlackOut(deployed).totalSupply() == expectedSupply, "supply mismatch");
        require(BlackOut(deployed).balanceOf(address(this)) == expectedSupply, "supply not held by creator");
    }

    /// @dev Returns the zero address if the constructor rejected the call rather than reverting,
    /// so the test can assert on the outcome.
    function tryDeployWithValue(bytes memory code, uint256 value) external payable returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(value, add(code, 32), mload(code))
        }
    }

    function predict(bytes memory code, bytes32 salt) external view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(code))))));
    }
}

/// @dev A contract that deploys the token from its own constructor: creation and first read in one
/// transaction, with the token's creator being a contract that has no code yet.
contract DeploysInConstructor {
    BlackOut public immutable token;
    uint256 public immutable heldAtConstruction;

    constructor() {
        token = new BlackOut();
        heldAtConstruction = token.balanceOf(address(this));
    }

    function forward(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract BlackOutEdgeTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    BlackOut private token;
    address private deployer;
    address private alice;
    address private bob;
    address private spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        vm.prank(deployer);
        token = new BlackOut();
    }

    // ------------------------------------------------------------- supply constant

    function test_supplyIsOneBillionWholeTokensScaledByDecimals() public view {
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000 * 10 ** uint256(token.decimals()));
        assertEq(token.INITIAL_SUPPLY(), 10 ** 27);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
        // Whole-token count recovers exactly: no rounding hidden in the constant.
        assertEq(token.totalSupply() / 10 ** uint256(token.decimals()), 1_000_000_000);
        assertEq(token.totalSupply() % 10 ** uint256(token.decimals()), 0);
    }

    function test_metadataReadableThroughStandardInterfaces() public view {
        IERC20Metadata meta = IERC20Metadata(address(token));
        assertEq(meta.name(), "BlackOut");
        assertEq(meta.symbol(), "BLACKOUT");
        assertEq(meta.decimals(), 18);
        assertEq(IERC20(address(token)).totalSupply(), SUPPLY);
        assertEq(bytes(meta.name()).length, 8);
        assertEq(bytes(meta.symbol()).length, 8);
    }

    // ------------------------------------------------------------ deployment paths

    function test_rawCreate2FromCreationCodeMintsToCreatorInOneCall() public {
        RawCreateFixture factory = new RawCreateFixture();
        bytes memory code = type(BlackOut).creationCode;
        bytes32 salt = bytes32(uint256(7));
        address predicted = factory.predict(code, salt);

        vm.prank(alice, bob);
        address deployed = factory.deployCreate2(code, salt, SUPPLY);

        assertEq(deployed, predicted, "CREATE2 address differs from prediction");
        BlackOut launched = BlackOut(deployed);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(alice), 0);
        assertEq(launched.balanceOf(bob), 0);
        assertEq(launched.balanceOf(address(this)), 0);
    }

    function test_sameSaltCannotRedeployAndNeverRemints() public {
        RawCreateFixture factory = new RawCreateFixture();
        bytes memory code = type(BlackOut).creationCode;
        bytes32 salt = bytes32(uint256(1));
        address first = factory.deployCreate2(code, salt, SUPPLY);

        // An address collision makes CREATE2 swallow all forwarded gas, so cap it.
        vm.expectRevert(bytes("constructor failed"));
        factory.deployCreate2{gas: 3_000_000}(code, salt, SUPPLY);
        assertEq(BlackOut(first).totalSupply(), SUPPLY);
        assertEq(BlackOut(first).balanceOf(address(factory)), SUPPLY);
    }

    function test_constructorIsNotPayable() public {
        RawCreateFixture factory = new RawCreateFixture();
        vm.deal(address(this), 1 ether);
        address deployed = factory.tryDeployWithValue{value: 1 wei}(type(BlackOut).creationCode, 1 wei);
        assertEq(deployed, address(0), "a non-payable constructor accepted ether");
        assertEq(address(factory).balance, 1 wei, "ether left the fixture despite the failed create");
    }

    function test_deploymentFromAnotherConstructorMintsToThatContract() public {
        vm.prank(deployer);
        DeploysInConstructor outer = new DeploysInConstructor();
        BlackOut inner = outer.token();

        assertEq(outer.heldAtConstruction(), SUPPLY, "supply not visible inside creating constructor");
        assertEq(inner.balanceOf(address(outer)), SUPPLY);
        assertEq(inner.balanceOf(deployer), 0, "transaction originator received tokens");
        assertEq(inner.totalSupply(), SUPPLY);
        assertTrue(outer.forward(alice, SUPPLY));
        assertEq(inner.balanceOf(alice), SUPPLY);
    }

    function test_twoDeploymentsAreIndependent() public {
        vm.prank(alice);
        BlackOut second = new BlackOut();

        assertTrue(address(second) != address(token));
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);

        vm.prank(alice);
        assertTrue(second.transfer(bob, 1 ether));
        assertEq(token.balanceOf(bob), 0, "transfer on one instance leaked into another");
        assertEq(token.totalSupply() + second.totalSupply(), 2 * SUPPLY);
    }

    function test_creationCodeHasNoForbiddenOpcodes() public pure {
        bytes memory code = type(BlackOut).creationCode;
        assertGt(code.length, 0);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
            } else {
                assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode in creation code");
            }
        }
    }

    // ------------------------------------------------------- surface and fallback

    function test_noFallbackNoReceiveNoOwner() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        (bool ok,) = address(token).call("");
        assertFalse(ok, "empty calldata accepted");
        (ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "plain ether accepted");
        (ok,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "token exposes owner()");
        (ok,) = address(token).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok, "token exposes renounceOwnership()");
        (ok,) = address(token).call(abi.encodeWithSignature("paused()"));
        assertFalse(ok, "token exposes paused()");
        (ok,) = address(token).call{value: 1}(abi.encodeWithSelector(IERC20.transfer.selector, bob, 0));
        assertFalse(ok, "transfer accepted ether");
        vm.stopPrank();
        assertEq(address(token).balance, 0);
        assertEq(alice.balance, 1 ether);
    }

    function testFuzz_unknownSelectorReverts(bytes4 selector, bytes memory payload) public {
        // Nudge known selectors off the ERC-20 surface rather than discarding the run.
        while (_isKnownSelector(selector)) {
            selector = bytes4(uint32(selector) + 1);
        }
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(token).call(abi.encodePacked(selector, payload));
        assertFalse(ok, "unknown selector did not revert");
        assertEq(ret.length, 0, "unknown selector returned data");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Every privileged signature the launch floor probes, tried from the deployer (the
    /// address a token would most plausibly trust) and a stranger, each with the holder as target.
    function test_floorPrivilegedSignaturesHaveNoEffect() public {
        _fund(alice, 10 ether);
        string[22] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        address[2] memory callers = [deployer, bob];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory asUint = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
                bytes memory asBool = abi.encodeWithSignature(signatures[i], alice, true);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(asUint);
                assertFalse(ok, signatures[i]);
                vm.prank(callers[c]);
                (ok,) = address(token).call(asBool);
                assertFalse(ok, signatures[i]);
                assertEq(token.totalSupply(), SUPPLY, signatures[i]);
                assertEq(token.balanceOf(alice), 10 ether, signatures[i]);
                assertEq(token.balanceOf(callers[c]), callers[c] == deployer ? SUPPLY - 10 ether : 0, signatures[i]);
            }
        }
        // The deployer cannot pull from the holder either, and the holder still moves freely.
        vm.prank(deployer);
        (bool pulled,) = address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, alice, deployer, 1));
        assertFalse(pulled);
        assertEq(token.balanceOf(alice), 10 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 5 ether));
        assertEq(token.balanceOf(bob), 5 ether);
    }

    // ------------------------------------------------------------ allowance edges

    function test_allowanceOneBelowMaxIsFiniteAndDecrements() public {
        _fund(alice, 10 ether);
        uint256 nearMax = type(uint256).max - 1;
        vm.prank(alice);
        token.approve(spender, nearMax);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 3 ether));
        assertEq(token.allowance(alice, spender), nearMax - 3 ether, "near-max allowance treated as unlimited");
        assertEq(token.balanceOf(bob), 3 ether);
    }

    function test_unlimitedAllowanceSurvivesZeroAndFullSpends() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertTrue(token.transferFrom(alice, bob, 10 ether));
        vm.stopPrank();
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 0);

        // Unlimited allowance does not conjure tokens the owner lacks.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), type(uint256).max);
    }

    function test_revokingUnlimitedAllowanceStopsSpendingImmediately() public {
        _fund(alice, 10 ether);
        vm.startPrank(alice);
        token.approve(spender, type(uint256).max);
        token.approve(spender, 0);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_transferFromEmitsOnlyTransferNotApproval() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        token.approve(spender, 7 ether);

        vm.recordLogs();
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 4 ether));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "transferFrom emitted more than one event");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(alice))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(abi.decode(logs[0].data, (uint256)), 4 ether);
        assertEq(token.allowance(alice, spender), 3 ether);
    }

    function test_spenderCannotForwardAllowanceToThirdParty() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        token.approve(spender, 10 ether);
        // The spender's own approval to bob does not let bob draw on alice.
        vm.prank(spender);
        token.approve(bob, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1 ether));
        vm.prank(bob);
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.allowance(alice, spender), 10 ether);
    }

    function test_approveToSelfSpendsOwnAllowance() public {
        _fund(alice, 10 ether);
        vm.startPrank(alice);
        token.approve(alice, 4 ether);
        assertTrue(token.transferFrom(alice, bob, 4 ether));
        vm.stopPrank();
        assertEq(token.allowance(alice, alice), 0);
        assertEq(token.balanceOf(bob), 4 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
    }

    // --------------------------------------------------------------- fuzz: transfers

    function testFuzz_transferToAnyNonZeroAddressDeliversExactly(uint160 recipientSeed, uint256 amount) public {
        address recipient = address(uint160(bound(recipientSeed, 1, type(uint160).max)));
        amount = bound(amount, 0, SUPPLY);
        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 deployerBefore = token.balanceOf(deployer);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, recipient, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(recipient, amount));

        if (recipient == deployer) {
            assertEq(token.balanceOf(deployer), deployerBefore);
        } else {
            assertEq(token.balanceOf(recipient), recipientBefore + amount);
            assertEq(token.balanceOf(deployer), deployerBefore - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_multiHopTransferConservesSupplyAndBalances(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, a));
        vm.prank(alice);
        assertTrue(token.transfer(bob, b));
        vm.prank(bob);
        assertTrue(token.transfer(spender, c));

        assertEq(token.balanceOf(deployer), SUPPLY - a);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b - c);
        assertEq(token.balanceOf(spender), c);
        assertEq(
            token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(spender), SUPPLY
        );

        // One more wei than anyone holds fails at every hop.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, spender, c, c + 1));
        vm.prank(spender);
        token.transfer(alice, c + 1);
    }

    function testFuzz_roundTripReturnsExactly(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        vm.prank(alice);
        assertTrue(token.transfer(deployer, amount));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_tokensSentToTokenContractAreInertButCounted(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), amount));
        assertEq(token.balanceOf(address(token)), amount);
        assertEq(token.totalSupply(), SUPPLY);
        // Nobody can pull them back out: the token has no allowance from itself.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, amount));
        vm.prank(deployer);
        token.transferFrom(address(token), deployer, amount);
        assertEq(token.balanceOf(address(token)), amount);
    }

    // ------------------------------------------------------------- fuzz: allowances

    function testFuzz_allowancesAreIndependentPerPair(uint160 ownerSeed, uint160 spenderSeed, uint256 amount) public {
        address owner = address(uint160(bound(ownerSeed, 1, type(uint160).max)));
        address other = address(uint160(bound(spenderSeed, 1, type(uint160).max)));
        if (other == owner) other = address(uint160(other) == type(uint160).max ? 1 : uint160(other) + 1);

        vm.prank(owner);
        assertTrue(token.approve(other, amount));
        assertEq(token.allowance(owner, other), amount);
        assertEq(token.allowance(other, owner), 0, "approval leaked in reverse direction");
        assertEq(token.allowance(owner, owner), 0, "approval leaked to self");
        assertEq(token.allowance(other, other), 0);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(other), 0);
    }

    function testFuzz_transferFromSpendsExactlyWhatMoves(uint256 approved, uint256 balance, uint256 amount) public {
        approved = bound(approved, 0, type(uint256).max - 1); // finite
        balance = bound(balance, 0, SUPPLY);
        uint256 cap = approved < balance ? approved : balance;
        amount = bound(amount, 0, cap);
        _fund(alice, balance);
        vm.prank(alice);
        token.approve(spender, approved);

        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.allowance(alice, spender), approved - amount);
        assertEq(token.balanceOf(alice), balance - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromBeyondBalanceWithinAllowanceIsAtomic(uint256 balance, uint256 excess) public {
        balance = bound(balance, 0, SUPPLY - 1);
        excess = bound(excess, 1, SUPPLY - balance);
        uint256 attempted = balance + excess;
        _fund(alice, balance);
        vm.prank(alice);
        token.approve(spender, attempted);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, attempted)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, attempted);
        assertEq(token.allowance(alice, spender), attempted, "allowance consumed by a failed transferFrom");
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), 0);
    }

    function testFuzz_unauthorizedSpenderCannotMoveAnyPositiveAmount(uint160 spenderSeed, uint256 amount) public {
        address stranger = address(uint160(bound(spenderSeed, 1, type(uint160).max)));
        amount = bound(amount, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        vm.prank(stranger);
        token.transferFrom(deployer, stranger, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(stranger), stranger == deployer ? SUPPLY : 0);
    }

    // ------------------------------------------------------------------ internals

    function _fund(address to, uint256 amount) private {
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
    }

    function _isKnownSelector(bytes4 selector) private pure returns (bool) {
        return selector == IERC20.totalSupply.selector || selector == IERC20.balanceOf.selector
            || selector == IERC20.transfer.selector || selector == IERC20.allowance.selector
            || selector == IERC20.approve.selector || selector == IERC20.transferFrom.selector
            || selector == IERC20Metadata.name.selector || selector == IERC20Metadata.symbol.selector
            || selector == IERC20Metadata.decimals.selector || selector == bytes4(keccak256("INITIAL_SUPPLY()"));
    }
}
