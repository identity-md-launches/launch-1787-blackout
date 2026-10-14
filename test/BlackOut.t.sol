// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BlackOut} from "../src/BlackOut.sol";

/// @dev Test fixture only; not an application contract or production factory.
contract TokenFactoryFixture {
    function deploy(bytes32 salt) external returns (BlackOut) {
        return new BlackOut{salt: salt}();
    }

    function send(BlackOut token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @dev An ERC-20 transfer must not invoke recipient code.
contract RejectingRecipient {
    fallback() external {
        revert("recipient called");
    }
}

contract BlackOutTest is Test {
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

    function test_metadata() public view {
        assertEq(token.name(), "BlackOut");
        assertEq(token.symbol(), "BLACKOUT");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    function test_constructorMintsEntireSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_constructorEmitsExactlyOneMintEvent() public {
        vm.recordLogs();
        vm.prank(deployer);
        BlackOut fresh = new BlackOut();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(deployer))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_constructorUsesImmediateCreatorWithDifferentOrigin() public {
        vm.prank(deployer, alice);
        BlackOut fresh = new BlackOut();

        assertEq(fresh.balanceOf(deployer), SUPPLY);
        assertEq(fresh.balanceOf(alice), 0);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_factoryDeploymentAndExactLaunchTransfers() public {
        TokenFactoryFixture factory = new TokenFactoryFixture();
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("pool manager");
        address remainderRecipient = makeAddr("remainder recipient");
        vm.prank(deployer, alice);
        BlackOut launched = factory.deploy(keccak256("launch test"));

        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(deployer), 0);
        assertEq(launched.balanceOf(alice), 0);
        uint256 swarmShare = SUPPLY * 10 / 100;
        uint256 poolShare = SUPPLY * 88 / 100;
        uint256 remainder = SUPPLY * 2 / 100;

        assertTrue(factory.send(launched, distributor, swarmShare));
        assertTrue(factory.send(launched, poolManager, poolShare));
        assertTrue(factory.send(launched, remainderRecipient, remainder));
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), swarmShare);
        assertEq(launched.balanceOf(poolManager), poolShare);
        assertEq(launched.balanceOf(remainderRecipient), remainder);

        vm.prank(distributor);
        assertTrue(launched.transfer(alice, swarmShare));
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.balanceOf(alice), swarmShare);

        // Exercise exact token movements in both directions. This fixture does
        // not model Uniswap pricing, liquidity accounting, or swaps.
        vm.prank(poolManager);
        assertTrue(launched.transfer(bob, 100 ether));
        assertEq(launched.balanceOf(bob), 100 ether);
        vm.prank(bob);
        assertTrue(launched.transfer(poolManager, 100 ether));
        assertEq(launched.balanceOf(bob), 0);
        assertEq(launched.balanceOf(poolManager), poolShare);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_transferEmitsEventAndDeliversExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, alice, 25 ether);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 25 ether));

        assertEq(token.balanceOf(deployer), SUPPLY - 25 ether);
        assertEq(token.balanceOf(alice), 25 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromUnfundedAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferPreservesBalanceAndSupply() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferEntireBalanceThenRejectOverspend() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transfer(alice, 1);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1 ether);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 0);
    }

    function test_transferOverBalanceRevertsWithoutChangingState() public {
        _fundAlice(10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 11 ether)
        );
        vm.prank(alice);
        token.transfer(bob, 11 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferMaximumUintReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        vm.prank(deployer);
        token.transfer(alice, type(uint256).max);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferDoesNotCallRecipient() public {
        RejectingRecipient recipient = new RejectingRecipient();
        vm.prank(deployer);
        assertTrue(token.transfer(address(recipient), 1 ether));
        assertEq(token.balanceOf(address(recipient)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approveEmitsEventWithoutMovingTokens() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(deployer, spender, 20 ether);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 20 ether));

        assertEq(token.allowance(deployer, spender), 20 ether);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approveCanReplaceAndRevokeAllowance() public {
        vm.startPrank(deployer);
        assertTrue(token.approve(spender, 20 ether));
        assertTrue(token.approve(spender, 5 ether));
        assertEq(token.allowance(deployer, spender), 5 ether);
        assertTrue(token.approve(spender, 0));
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_unfundedAccountMayApprove() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, 1 ether));
        assertEq(token.allowance(alice, spender), 1 ether);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1 ether);
        assertEq(token.allowance(deployer, address(0)), 0);
    }

    function test_approvalIsScopedToCallerAndSpender() public {
        _fundAlice(10 ether);
        vm.prank(alice);
        assertTrue(token.approve(spender, 5 ether));
        vm.prank(bob);
        assertTrue(token.approve(spender, 10 ether));
        assertEq(token.allowance(alice, spender), 5 ether);
        assertEq(token.allowance(bob, spender), 10 ether);
        assertEq(token.allowance(alice, bob), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_transferFromEmitsEventAndSpendsFiniteAllowance() public {
        _fundAlice(10 ether);
        vm.prank(alice);
        token.approve(spender, 7 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 4 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 4 ether));

        assertEq(token.balanceOf(alice), 6 ether);
        assertEq(token.balanceOf(bob), 4 ether);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.allowance(alice, spender), 3 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromExhaustsAllowanceAndRejectsReuse() public {
        _fundAlice(10 ether);
        vm.prank(alice);
        token.approve(spender, 4 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 4 ether));
        assertEq(token.allowance(alice, spender), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 6 ether);
        assertEq(token.balanceOf(bob), 4 ether);
    }

    function test_transferFromPreservesUnlimitedAllowance() public {
        _fundAlice(10 ether);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(alice, bob, 3 ether));
        assertTrue(token.transferFrom(alice, bob, 7 ether));
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 10 ether);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromToSelfSpendsAllowanceWithoutChangingBalance() public {
        _fundAlice(10 ether);
        vm.prank(alice);
        token.approve(spender, 7 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, alice, 4 ether));
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.allowance(alice, spender), 3 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromWithoutAllowanceSucceeds() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromOverAllowanceRevertsWithoutChangingState() public {
        _fundAlice(10 ether);
        vm.prank(alice);
        token.approve(spender, 3 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 3 ether, 4 ether)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, 4 ether);

        assertEq(token.allowance(alice, spender), 3 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromOverBalanceRollsBackAllowance() public {
        _fundAlice(3 ether);
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 3 ether, 4 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 4 ether);

        assertEq(token.allowance(alice, spender), 10 ether);
        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromToZeroRollsBackAllowance() public {
        _fundAlice(10 ether);
        vm.prank(alice);
        token.approve(spender, 5 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(alice, address(0), 2 ether);

        assertEq(token.allowance(alice, spender), 5 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromZeroAddressReverts() public {
        // Zero amount reaches address validation without needing an approval
        // from the zero address. OZ checks the approver before the transfer.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), alice, 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_deployerCannotSpendHolderTokensWithoutApproval() public {
        _fundAlice(10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1 ether));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1 ether);
        assertEq(token.balanceOf(alice), 10 ether);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_noMintBurnOrAdministrativeEntryPoints() public {
        _fundAlice(10 ether);
        bytes[] memory calls = new bytes[](13);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", alice, SUPPLY);
        calls[1] = abi.encodeWithSignature("mint(uint256)", SUPPLY);
        calls[2] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[3] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether);
        calls[4] = abi.encodeWithSignature("pause()");
        calls[5] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[6] = abi.encodeWithSignature("freeze(address)", alice);
        calls[7] = abi.encodeWithSignature("seize(address)", alice);
        calls[8] = abi.encodeWithSignature("transferOwnership(address)", bob);
        calls[9] = abi.encodeWithSignature("initialize(address)", bob);
        calls[10] = abi.encodeWithSignature("upgradeTo(address)", bob);
        calls[11] = abi.encodeWithSignature("setMinter(address)", bob);
        calls[12] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        address[2] memory callers = [deployer, bob];

        for (uint256 i; i < callers.length; ++i) {
            for (uint256 j; j < calls.length; ++j) {
                vm.prank(callers[i]);
                (bool success,) = address(token).call(calls[j]);
                assertFalse(success, "unexpected privileged entry point");
                assertEq(token.totalSupply(), SUPPLY);
                assertEq(token.balanceOf(alice), 10 ether);
            }
        }
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(token).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(address(token).balance, 0);
        assertEq(alice.balance, 1 ether);
    }

    function test_runtimeHasNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
            } else {
                assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
            }
        }
    }

    function testFuzz_transferConservesSupply(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0) && recipient != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferOverBalanceIsAtomic(uint256 balance, uint256 excess) public {
        balance = bound(balance, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - balance);
        _fundAlice(balance);
        uint256 attempted = balance + excess;

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, attempted)
        );
        vm.prank(alice);
        token.transfer(bob, attempted);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(deployer), SUPPLY - balance);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_approveReplacesAllowance(uint256 first, uint256 second) public {
        vm.startPrank(alice);
        assertTrue(token.approve(spender, first));
        assertTrue(token.approve(spender, second));
        vm.stopPrank();
        assertEq(token.allowance(alice, spender), second);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromConservesSupplyAndSpendsAllowance(uint256 approved, uint256 amount) public {
        uint256 maximum = approved < SUPPLY ? approved : SUPPLY;
        amount = bound(amount, 0, maximum);
        vm.prank(deployer);
        token.approve(spender, approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, amount));

        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.allowance(deployer, spender), approved == type(uint256).max ? approved : approved - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromOverAllowanceIsAtomic(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY - 1);
        amount = bound(amount, approved + 1, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, approved);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        vm.prank(spender);
        token.transferFrom(deployer, alice, amount);
        assertEq(token.allowance(deployer, spender), approved);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _fundAlice(uint256 amount) private {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
    }
}
