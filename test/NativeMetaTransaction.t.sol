// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { PCEToken } from "../src/PCEToken.sol";
import { PCECommunityToken } from "../src/PCECommunityToken.sol";
import { ExchangeAllowMethod } from "../src/lib/Enum.sol";
import { ContextMixin } from "../src/lib/polygon/ContextMixin.sol";

contract ContextMixinHarness is ContextMixin {
    function sender() external view returns (address) {
        return msgSender();
    }
}

contract NativeMetaTransactionTest is Test {
    PCEToken internal pce;
    PCECommunityToken internal community;
    address internal alice;
    uint256 internal aliceKey;
    address internal bob = address(0xB0B);
    address internal relayer = address(0xCAFE);
    address internal manager = address(0xBEEF);

    bytes32 internal constant META_TYPEHASH =
        keccak256("MetaTransaction(uint256 nonce,address from,bytes functionSignature)");

    function setUp() public {
        (alice, aliceKey) = makeAddrAndKey("alice");
        PCEToken implementation = PCEToken(deployCode("PCEToken.sol:PCEToken"));
        vm.prank(alice);
        pce = PCEToken(address(new ERC1967Proxy(address(implementation), abi.encodeCall(PCEToken.initialize, ()))));

        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new PCECommunityToken()), alice);
        vm.startPrank(alice);
        pce.setCommunityTokenAddress(address(beacon));
        pce.mint(alice, 1000 ether);
        pce.setMetaTransactionGas(200_000);
        pce.setMetaTransactionPriorityFee(50 gwei);
        _createCommunity(100 ether);
        vm.stopPrank();
        community = PCECommunityToken(pce.getTokens()[0]);
        // Legacy bridge manager field, intentionally retained in its original slot.
        vm.store(address(pce), bytes32(uint256(11)), bytes32(uint256(uint160(manager))));
    }

    function _createCommunity(uint256 depositAmount) internal {
        address[] memory targets = new address[](0);
        pce.createToken(
            "Community",
            "COM",
            depositAmount,
            1 ether,
            1,
            9800,
            1000,
            500,
            1000,
            100,
            ExchangeAllowMethod.All,
            ExchangeAllowMethod.All,
            targets,
            targets
        );
    }

    function _sign(bytes memory callData) internal view returns (bytes32 r, bytes32 s, uint8 v) {
        bytes32 structHash = keccak256(abi.encode(META_TYPEHASH, pce.getNonce(alice), alice, keccak256(callData)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", pce.getDomainSeperator(), structHash));
        (v, r, s) = vm.sign(aliceKey, digest);
    }

    function _execute(bytes memory callData) internal returns (bytes memory) {
        (bytes32 r, bytes32 s, uint8 v) = _sign(callData);
        vm.prank(relayer);
        return pce.executeMetaTransaction(alice, callData, r, s, v);
    }

    function _assertReserve() internal view {
        assertEq(pce.balanceOf(address(pce)), 100 ether);
        assertEq(pce.getDepositedPCETokens(address(community)), 100 ether);
    }

    function _legacyDomainState() internal {
        // Model an upgraded legacy proxy whose Polygon initializer was never run.
        vm.store(address(pce), bytes32(uint256(0)), bytes32(0));
        vm.store(address(pce), bytes32(uint256(1)), bytes32(0));
    }

    function _expectedDomain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract,bytes32 salt)"),
                keccak256(bytes(pce.name())),
                keccak256("1"),
                address(pce),
                bytes32(block.chainid)
            )
        );
    }

    function testFreshProxyDomainUsesProxyAndChain() public view {
        assertEq(pce.getDomainSeperator(), _expectedDomain());
    }

    function testMetaTransferUsesSignerAndPreservesReserve() public {
        bytes memory result = _execute(abi.encodeCall(PCEToken.transfer, (bob, 10 ether)));
        assertTrue(abi.decode(result, (bool)));
        assertEq(pce.balanceOf(alice), 890 ether);
        assertEq(pce.balanceOf(bob), 10 ether);
        assertEq(pce.balanceOf(relayer), 0);
        assertEq(pce.getNonce(alice), 1);
        _assertReserve();
    }

    function testMetaApproveUsesSigner() public {
        _execute(abi.encodeCall(PCEToken.approve, (bob, 20 ether)));
        assertEq(pce.allowance(alice, bob), 20 ether);
        assertEq(pce.allowance(address(pce), bob), 0);
        _assertReserve();
    }

    function testMetaTransferFromUsesSignerAsSpender() public {
        vm.prank(alice);
        pce.mint(bob, 20 ether);
        vm.prank(bob);
        pce.approve(alice, 20 ether);
        _execute(abi.encodeCall(PCEToken.transferFrom, (bob, relayer, 5 ether)));
        assertEq(pce.balanceOf(bob), 15 ether);
        assertEq(pce.balanceOf(relayer), 5 ether);
        assertEq(pce.allowance(bob, alice), 15 ether);
        _assertReserve();
    }

    function testMetaBurnUsesSigner() public {
        _execute(abi.encodeWithSignature("burn(uint256)", 10 ether));
        assertEq(pce.balanceOf(alice), 890 ether);
        assertEq(pce.totalSupply(), 990 ether);
        _assertReserve();
    }

    function testMetaWithdrawBurnsSignerAndEmitsBridgeTransfer() public {
        vm.expectEmit(true, true, false, true, address(pce));
        emit Transfer(alice, address(0), 10 ether);
        _execute(abi.encodeCall(PCEToken.withdraw, (10 ether)));
        assertEq(pce.balanceOf(alice), 890 ether);
        _assertReserve();
    }

    event Transfer(address indexed from, address indexed to, uint256 value);

    function testDirectTransferIgnoresTrailingAddress() public {
        vm.prank(alice);
        (bool ok,) = address(pce).call(abi.encodePacked(abi.encodeCall(PCEToken.transfer, (bob, 10 ether)), relayer));
        assertTrue(ok);
        assertEq(pce.balanceOf(alice), 890 ether);
        assertEq(pce.balanceOf(bob), 10 ether);
        _assertReserve();
    }

    function testDirectWithdrawUsesCaller() public {
        vm.prank(alice);
        pce.withdraw(10 ether);
        assertEq(pce.balanceOf(alice), 890 ether);
        _assertReserve();
    }

    function testBridgeDepositRequiresActualManager() public {
        vm.prank(manager);
        pce.deposit(bob, abi.encode(7 ether));
        assertEq(pce.balanceOf(bob), 7 ether);
        vm.prank(alice);
        vm.expectRevert("Only polygon chain manager can call this function");
        pce.deposit(bob, abi.encode(7 ether));
        _assertReserve();
    }

    function testMetaDepositCannotReplaceManagerAuthentication() public {
        bytes memory callData = abi.encodeCall(PCEToken.deposit, (bob, abi.encode(7 ether)));
        (bytes32 r, bytes32 s, uint8 v) = _sign(callData);
        vm.prank(relayer);
        vm.expectRevert("Function call not successful");
        pce.executeMetaTransaction(alice, callData, r, s, v);
        assertEq(pce.getNonce(alice), 0);
        assertEq(pce.balanceOf(bob), 0);
        _assertReserve();
    }

    function testMetaCreateTokenUsesSignerForDepositAndOwnership() public {
        address[] memory targets = new address[](0);
        _execute(
            abi.encodeCall(
                PCEToken.createToken,
                (
                    "Second",
                    "SEC",
                    20 ether,
                    1 ether,
                    1,
                    9800,
                    1000,
                    500,
                    1000,
                    100,
                    ExchangeAllowMethod.All,
                    ExchangeAllowMethod.All,
                    targets,
                    targets
                )
            )
        );
        PCECommunityToken created = PCECommunityToken(pce.getTokens()[1]);
        assertEq(created.owner(), alice);
        assertEq(created.balanceOf(alice), 20 ether);
        assertEq(pce.balanceOf(alice), 880 ether);
        assertEq(pce.balanceOf(address(pce)), 120 ether);
        assertEq(pce.getDepositedPCETokens(address(created)), 20 ether);
        assertEq(pce.getDepositedPCETokens(address(community)), 100 ether);
    }

    function testOwnerMetaCallUsesSignerNotRelayer() public {
        _execute(abi.encodeCall(PCEToken.setMetaTransactionGas, (123_456)));
        assertEq(pce.metaTransactionGas(), 123_456);
        _assertReserve();
    }

    function testMetaSwapToCommunityUsesSignerAndUpdatesDeposit() public {
        _execute(abi.encodeCall(PCEToken.swapToLocalToken, (address(community), 20 ether)));
        assertEq(pce.balanceOf(alice), 880 ether);
        assertEq(pce.balanceOf(address(pce)), 120 ether);
        assertEq(pce.getDepositedPCETokens(address(community)), 120 ether);
        assertEq(community.balanceOf(alice), 120 ether);
    }

    function testMetaIncreaseTokenValueUsesCommunityOwner() public {
        _execute(abi.encodeCall(PCEToken.increaseTokenValue, (address(community), 10 ether)));
        assertEq(pce.balanceOf(alice), 890 ether);
        assertEq(pce.balanceOf(address(pce)), 110 ether);
        assertEq(pce.getDepositedPCETokens(address(community)), 110 ether);
        assertEq(pce.getExchangeRate(address(community)), uint256(1 ether) * 100 / 110);
    }

    function testNonOwnerMetaCallRejected() public {
        vm.prank(alice);
        pce.transferOwnership(bob);
        bytes memory callData = abi.encodeCall(PCEToken.mint, (relayer, 10 ether));
        (bytes32 r, bytes32 s, uint8 v) = _sign(callData);
        vm.prank(relayer);
        vm.expectRevert("Function call not successful");
        pce.executeMetaTransaction(alice, callData, r, s, v);
        assertEq(pce.getNonce(alice), 0);
        _assertReserve();
    }

    function testInvalidSignatureLeavesStateUnchanged() public {
        bytes memory callData = abi.encodeCall(PCEToken.transfer, (bob, 10 ether));
        (bytes32 r, bytes32 s, uint8 v) = _sign(callData);
        vm.prank(relayer);
        vm.expectRevert("Signer and signature do not match");
        pce.executeMetaTransaction(bob, callData, r, s, v);
        assertEq(pce.getNonce(alice), 0);
        assertEq(pce.getNonce(bob), 0);
        assertEq(pce.balanceOf(alice), 900 ether);
        _assertReserve();
    }

    function testSignatureCannotBeReplayed() public {
        bytes memory callData = abi.encodeCall(PCEToken.transfer, (bob, 10 ether));
        (bytes32 r, bytes32 s, uint8 v) = _sign(callData);
        vm.prank(relayer);
        pce.executeMetaTransaction(alice, callData, r, s, v);
        vm.prank(relayer);
        vm.expectRevert("Signer and signature do not match");
        pce.executeMetaTransaction(alice, callData, r, s, v);
        assertEq(pce.getNonce(alice), 1);
        assertEq(pce.balanceOf(bob), 10 ether);
        _assertReserve();
    }

    function testInnerCallFailureRollsBackNonce() public {
        bytes memory callData = abi.encodeCall(PCEToken.transfer, (bob, 1001 ether));
        (bytes32 r, bytes32 s, uint8 v) = _sign(callData);
        vm.prank(relayer);
        vm.expectRevert("Function call not successful");
        pce.executeMetaTransaction(alice, callData, r, s, v);
        assertEq(pce.getNonce(alice), 0);
        assertEq(pce.balanceOf(alice), 900 ether);
        _assertReserve();
    }

    function testUninitializedDomainFailsClosed() public {
        _legacyDomainState();
        vm.prank(relayer);
        vm.expectRevert("NativeMetaTransaction: DOMAIN_NOT_INITIALIZED");
        pce.executeMetaTransaction(alice, bytes(""), bytes32(0), bytes32(0), 0);
        assertEq(pce.getNonce(alice), 0);
        _assertReserve();
    }

    function testLegacyDomainMigrationPreservesStateAndEnablesMetaCalls() public {
        _execute(abi.encodeCall(PCEToken.approve, (bob, 20 ether)));
        uint256 factor = pce.lastModifiedFactor();
        _legacyDomainState();
        vm.prank(alice);
        pce.initializeNativeMetaTransaction();
        assertEq(pce.getDomainSeperator(), _expectedDomain());
        assertEq(pce.owner(), alice);
        assertEq(pce.balanceOf(alice), 900 ether);
        assertEq(pce.allowance(alice, bob), 20 ether);
        assertEq(pce.getNonce(alice), 1);
        assertEq(pce.lastModifiedFactor(), factor);
        assertEq(pce.polygonChainManager(), manager);
        assertEq(pce.metaTransactionGas(), 200_000);
        assertEq(pce.metaTransactionPriorityFee(), 50 gwei);
        _assertReserve();
        _execute(abi.encodeCall(PCEToken.transfer, (bob, 1 ether)));
        assertEq(pce.getNonce(alice), 2);
        _assertReserve();
    }

    function testUpgradeAndLegacyDomainMigrationAreAtomic() public {
        _legacyDomainState();
        PCEToken replacement = PCEToken(deployCode("PCEToken.sol:PCEToken"));
        vm.prank(alice);
        pce.upgradeToAndCall(address(replacement), abi.encodeCall(PCEToken.initializeNativeMetaTransaction, ()));
        assertEq(pce.getDomainSeperator(), _expectedDomain());
        assertEq(pce.owner(), alice);
        _assertReserve();
        _execute(abi.encodeCall(PCEToken.transfer, (bob, 1 ether)));
        assertEq(pce.balanceOf(alice), 899 ether);
        _assertReserve();
    }

    function testRejectedMigrationRollsBackUpgrade() public {
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 previousImplementation = vm.load(address(pce), implementationSlot);
        bytes32 previousDomain = pce.getDomainSeperator();
        PCEToken replacement = PCEToken(deployCode("PCEToken.sol:PCEToken"));
        vm.prank(alice);
        vm.expectRevert("NativeMetaTransaction: DOMAIN_ALREADY_INITIALIZED");
        pce.upgradeToAndCall(address(replacement), abi.encodeCall(PCEToken.initializeNativeMetaTransaction, ()));
        assertEq(vm.load(address(pce), implementationSlot), previousImplementation);
        assertEq(pce.getDomainSeperator(), previousDomain);
        _assertReserve();
    }

    function testDomainMigrationRequiresOwner() public {
        _legacyDomainState();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob));
        pce.initializeNativeMetaTransaction();
        assertEq(pce.getDomainSeperator(), bytes32(0));
    }

    function testDomainMigrationRequiresProxy() public {
        PCEToken implementation = PCEToken(deployCode("PCEToken.sol:PCEToken"));
        vm.expectRevert(abi.encodeWithSignature("UUPSUnauthorizedCallContext()"));
        implementation.initializeNativeMetaTransaction();
    }

    function testDomainMigrationCannotOverwriteFreshDomain() public {
        bytes32 beforeDomain = pce.getDomainSeperator();
        vm.prank(alice);
        vm.expectRevert("NativeMetaTransaction: DOMAIN_ALREADY_INITIALIZED");
        pce.initializeNativeMetaTransaction();
        assertEq(pce.getDomainSeperator(), beforeDomain);
    }

    function testDomainMigrationCannotRunTwice() public {
        _legacyDomainState();
        vm.prank(alice);
        pce.initializeNativeMetaTransaction();
        vm.prank(alice);
        vm.expectRevert("NativeMetaTransaction: DOMAIN_ALREADY_INITIALIZED");
        pce.initializeNativeMetaTransaction();
    }

    function testContextRejectsShortSelfCall() public {
        ContextMixinHarness harness = new ContextMixinHarness();
        vm.prank(address(harness));
        vm.expectRevert(ContextMixin.InvalidMetaTransactionContext.selector);
        harness.sender();
    }
}
