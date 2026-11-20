// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { PCEMainnetToken } from "../src/PCEMainnetToken.sol";
import { PIP23Distribution } from "./fixtures/PIP23Distribution.sol";

contract PCEMainnetTokenTest is Test {
    address internal constant TIMELOCK = 0x208983f723245C765b4F9E57FAaB2633c9DDaC6B;
    uint256 internal constant EXPECTED_SUPPLY = 222_156_723_489_999_990_835_174_897;
    bytes32 internal constant STORAGE_SLOT = 0x3629129d1ffd87df7c2b731c970b9f725273df030c447616868b5704115a1a00;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    PCEMainnetToken internal implementation;
    PCEMainnetToken internal token;

    function setUp() public {
        vm.chainId(1);
        implementation = PCEMainnetToken(deployCode("PCEMainnetToken.sol:PCEMainnetToken"));
        token = PCEMainnetToken(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(PCEMainnetToken.initialize, (TIMELOCK))))
        );
    }

    function _single(address recipient, uint256 amount) internal pure returns (address[] memory r, uint256[] memory a) {
        r = new address[](1);
        a = new uint256[](1);
        r[0] = recipient;
        a[0] = amount;
    }

    function _mint(address recipient, uint256 amount) internal {
        (address[] memory r, uint256[] memory a) = _single(recipient, amount);
        vm.prank(TIMELOCK);
        token.distribute(r, a);
    }

    function testInitializationAndClock() public {
        assertEq(token.name(), "PEACE COIN");
        assertEq(token.symbol(), "PCE");
        assertEq(token.decimals(), 18);
        assertEq(token.owner(), TIMELOCK);
        assertEq(token.totalSupply(), 0);
        assertFalse(token.distributionClosed());
        vm.roll(25_904_711);
        assertEq(token.clock(), block.number);
        assertEq(token.CLOCK_MODE(), "mode=blocknumber&from=default");
        assertEq(address(uint160(uint256(vm.load(address(token), IMPLEMENTATION_SLOT)))), address(implementation));
        assertEq(vm.load(address(token), bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)), bytes32(0));
    }

    function testERC7201Slot() public {
        bytes32 slot =
            keccak256(abi.encode(uint256(keccak256("peacecoin.storage.PCEToken")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(slot, STORAGE_SLOT);
        assertEq(vm.load(address(token), slot), bytes32(0));
        vm.prank(TIMELOCK);
        token.closeDistribution();
        assertEq(vm.load(address(token), slot), bytes32(uint256(1)));
    }

    function testCannotInitializeTwiceOrImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize(alice);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(TIMELOCK);
    }

    function testZeroOwnerRejected() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(address(implementation), abi.encodeCall(PCEMainnetToken.initialize, (address(0))));
    }

    function testFullDistributionAndEvents() public {
        (address[] memory recipients, uint256[] memory amounts) = PIP23Distribution.table();
        vm.prank(recipients[0]);
        token.delegate(recipients[0]);
        vm.recordLogs();
        vm.prank(TIMELOCK);
        token.distribute(recipients, amounts);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 distributed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(token) && logs[i].topics[0] == keccak256("Distributed(address,uint256)")) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), recipients[distributed]);
                assertEq(abi.decode(logs[i].data, (uint256)), amounts[distributed]);
                ++distributed;
            }
        }
        assertEq(distributed, 138);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        for (uint256 i; i < recipients.length; ++i) {
            assertEq(token.balanceOf(recipients[i]), amounts[i]);
            assertEq(token.getVotes(recipients[i]), i == 0 ? amounts[i] : 0);
            for (uint256 j; j < i; ++j) {
                assertNotEq(recipients[i], recipients[j]);
            }
        }
        assertEq(
            token.balanceOf(address(bytes20(hex"64804de3708478390bd7def274deee66070ec34b"))),
            53_286_622_890_000_000_000_000_000
        );
        assertEq(
            token.balanceOf(address(bytes20(hex"659ae334442e2a5425e0b811b144bc507b05a6ee"))),
            1_013_629_267_634_484_359_053_979
        );
        assertEq(token.balanceOf(address(bytes20(hex"9052d3da7eebdf4f2b77d1c87fea31c6f789e964"))), 1_000_000 ether);
        assertEq(token.balanceOf(0xeB5e0632eD3C635E0fa07420A328b49a7D0E6e6d), 0);
        assertEq(token.balanceOf(address(bytes20(hex"56a62dd43f135bad525df9179b0ef4fad5639ca1"))), 0);
        assertEq(token.balanceOf(address(bytes20(hex"3ce03c46a5de51e7ea690eec54c0eaf0d8028323"))), 0);
        assertFalse(token.distributionClosed());
    }

    function testFuzzOnlyOwner(address caller) public {
        vm.assume(caller != TIMELOCK);
        (address[] memory r, uint256[] memory a) = _single(alice, 1 ether);
        bytes memory err = abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller);
        vm.startPrank(caller);
        vm.expectRevert(err);
        token.distribute(r, a);
        vm.expectRevert(err);
        token.closeDistribution();
        vm.expectRevert(err);
        token.upgradeToAndCall(address(implementation), "");
        vm.stopPrank();
    }

    function testInvalidInputs() public {
        vm.startPrank(TIMELOCK);
        vm.expectRevert(PCEMainnetToken.EmptyDistribution.selector);
        token.distribute(new address[](0), new uint256[](0));
        vm.expectRevert(PCEMainnetToken.LengthMismatch.selector);
        token.distribute(new address[](1), new uint256[](0));
        (address[] memory r, uint256[] memory a) = _single(address(0), 1);
        vm.expectRevert(PCEMainnetToken.ZeroRecipient.selector);
        token.distribute(r, a);
        r[0] = alice;
        a[0] = 0;
        vm.expectRevert(PCEMainnetToken.ZeroAmount.selector);
        token.distribute(r, a);
        vm.stopPrank();
    }

    function testInvalidLaterRecipientRollsBackWholeBatch() public {
        address[] memory r = new address[](2);
        uint256[] memory a = new uint256[](2);
        r[0] = alice;
        a[0] = a[1] = 1 ether;
        vm.prank(TIMELOCK);
        vm.expectRevert(PCEMainnetToken.ZeroRecipient.selector);
        token.distribute(r, a);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function testDuplicateRecipientsAndRepeatedDistributionAllowed() public {
        address[] memory r = new address[](2);
        uint256[] memory a = new uint256[](2);
        r[0] = r[1] = alice;
        a[0] = a[1] = 1 ether;
        vm.prank(TIMELOCK);
        token.distribute(r, a);
        _mint(alice, 1 ether);
        assertEq(token.balanceOf(alice), 3 ether);
    }

    function testCloseDistributionAndEvent() public {
        _mint(alice, 10 ether);
        vm.expectEmit(false, false, false, true, address(token));
        emit PCEMainnetToken.DistributionClosed(10 ether);
        vm.prank(TIMELOCK);
        token.closeDistribution();
        assertTrue(token.distributionClosed());
        vm.startPrank(TIMELOCK);
        vm.expectRevert(PCEMainnetToken.DistributionIsClosed.selector);
        token.closeDistribution();
        (address[] memory r, uint256[] memory a) = _single(alice, 1);
        vm.expectRevert(PCEMainnetToken.DistributionIsClosed.selector);
        token.distribute(r, a);
        vm.stopPrank();
    }

    function testRenounceOwnershipAlwaysDisabled() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(PCEMainnetToken.RenounceOwnershipDisabled.selector);
        token.renounceOwnership();
        vm.prank(alice);
        vm.expectRevert(PCEMainnetToken.RenounceOwnershipDisabled.selector);
        token.renounceOwnership();
        assertEq(token.owner(), TIMELOCK);
    }

    function testDelegationTransfersAndHistoricalCheckpoints() public {
        vm.roll(100);
        vm.prank(alice);
        token.delegate(alice);
        _mint(alice, 10 ether);
        _mint(bob, 5 ether);
        assertEq(token.getVotes(alice), 10 ether);
        assertEq(token.getVotes(bob), 0);
        vm.roll(101);
        vm.prank(alice);
        token.transfer(bob, 2 ether);
        vm.prank(bob);
        token.delegate(bob);
        assertEq(token.getVotes(alice), 8 ether);
        assertEq(token.getVotes(bob), 7 ether);
        assertEq(token.getPastVotes(alice, 100), 10 ether);
        assertEq(token.getPastVotes(bob, 100), 0);
        assertEq(token.getPastTotalSupply(100), 15 ether);
    }

    function _permitSignature(uint256 deadline) internal view returns (address signer, uint8 v, bytes32 r, bytes32 s) {
        uint256 key = 0xA11CE;
        signer = vm.addr(key);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PEACE COIN"),
                keccak256("1"),
                uint256(1),
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), domain);
        bytes32 data = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                bob,
                25 ether,
                uint256(0),
                deadline
            )
        );
        (v, r, s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, data)));
    }

    function testPermitAndReplayProtection() public {
        uint256 deadline = block.timestamp + 1 days;
        (address signer, uint8 v, bytes32 r, bytes32 s) = _permitSignature(deadline);
        token.permit(signer, bob, 25 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, bob), 25 ether);
        assertEq(token.nonces(signer), 1);
        vm.expectRevert();
        token.permit(signer, bob, 25 ether, deadline, v, r, s);
    }

    function testExpiredPermitRejected() public {
        uint256 deadline = block.timestamp - 1;
        (address signer, uint8 v, bytes32 r, bytes32 s) = _permitSignature(deadline);
        vm.expectRevert();
        token.permit(signer, bob, 25 ether, deadline, v, r, s);
        assertEq(token.nonces(signer), 0);
    }

    function testOwnerUpgradePreservesState() public {
        _mint(alice, 10 ether);
        vm.startPrank(alice);
        token.delegate(alice);
        token.approve(bob, 3 ether);
        vm.stopPrank();
        vm.prank(TIMELOCK);
        token.closeDistribution();
        address next = deployCode("PCEMainnetToken.sol:PCEMainnetToken");
        vm.prank(TIMELOCK);
        token.upgradeToAndCall(next, "");
        assertEq(address(uint160(uint256(vm.load(address(token), IMPLEMENTATION_SLOT)))), next);
        assertEq(token.owner(), TIMELOCK);
        assertEq(token.totalSupply(), 10 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.allowance(alice, bob), 3 ether);
        assertEq(token.getVotes(alice), 10 ether);
        assertTrue(token.distributionClosed());
        (address[] memory r, uint256[] memory a) = _single(alice, 1);
        vm.prank(TIMELOCK);
        vm.expectRevert(PCEMainnetToken.DistributionIsClosed.selector);
        token.distribute(r, a);
    }
}
