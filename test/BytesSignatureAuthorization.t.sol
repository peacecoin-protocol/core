// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { PCEToken } from "../src/PCEToken.sol";
import { PCECommunityToken } from "../src/PCECommunityToken.sol";
import { ExchangeAllowMethod } from "../src/lib/Enum.sol";
import { EIP3009 } from "../src/lib/EIP3009.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev ERC-1271 wallet controlled by one ECDSA key.
contract MockERC1271Wallet {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && recovered == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @dev Wallet that tries to write state while validating; under staticcall this must fail.
contract StatefulERC1271Wallet {
    uint256 public calls;

    function isValidSignature(bytes32, bytes calldata) external returns (bytes4) {
        calls++;
        return 0x1626ba7e;
    }
}

contract BytesSignatureAuthorizationTest is Test {
    PCEToken internal pce;
    PCECommunityToken internal tokenA;
    PCECommunityToken internal tokenB;

    uint256 internal constant EOA_PK = 0xE0A;
    uint256 internal constant WALLET_PK = 0x5AFE;
    address internal eoa;
    MockERC1271Wallet internal wallet;
    address internal constant RELAYER = address(0xF00D);
    address internal constant RECIPIENT = address(0xCAFE);
    uint256 internal constant NO_EXPIRY = type(uint256).max;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        pce = PCEToken(deployCode("PCEToken.sol:PCEToken"));
        pce.initialize();
        UpgradeableBeacon beacon =
            new UpgradeableBeacon(deployCode("PCECommunityToken.sol:PCECommunityToken"), address(this));
        pce.setCommunityTokenAddress(address(beacon));
        // Values a real deployment carries over from V1 (see PCE.t.sol).
        vm.store(address(pce), bytes32(uint256(3)), bytes32(uint256(396_140_812_571_321_687_967_719_751_680)));
        vm.store(address(pce), bytes32(uint256(4)), bytes32(uint256(200_000)));
        vm.store(address(pce), bytes32(uint256(5)), bytes32(uint256(50_000_000_000)));
        vm.store(address(pce), bytes32(uint256(6)), bytes32(uint256(3000)));
        vm.store(address(pce), bytes32(uint256(7)), bytes32(uint256(3000)));
        pce.mint(address(this), 10_000 ether);

        tokenA = _createToken("Token A", "TKA", 1 ether);
        tokenB = _createToken("Token B", "TKB", 2 ether);

        eoa = vm.addr(EOA_PK);
        wallet = new MockERC1271Wallet(vm.addr(WALLET_PK));

        tokenA.transfer(eoa, 100 ether);
        tokenA.transfer(address(wallet), 100 ether);
        pce.transfer(eoa, 100 ether);
        pce.transfer(address(wallet), 100 ether);
        // Settle midnight balances that drive the daily swap limits.
        vm.warp(block.timestamp + 1 days);
        tokenA.transfer(address(0xBEEF), 1 ether);
        vm.prank(eoa);
        tokenA.transfer(address(0xBEEF), 1 ether);
        vm.prank(address(wallet));
        tokenA.transfer(address(0xBEEF), 1 ether);
        vm.warp(block.timestamp + 1 days);
    }

    function _createToken(
        string memory name,
        string memory symbol,
        uint256 dilution
    )
        internal
        returns (PCECommunityToken)
    {
        pce.createToken(
            name,
            symbol,
            1000 ether,
            dilution,
            1,
            10_000,
            1000,
            500,
            1000,
            100,
            ExchangeAllowMethod.All,
            ExchangeAllowMethod.All,
            new address[](0),
            new address[](0)
        );
        address[] memory tokens = pce.getTokens();
        return PCECommunityToken(tokens[tokens.length - 1]);
    }

    // ---------------------------------------------------------------- helpers

    function _domain(string memory name, address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256("1"), block.chainid, verifyingContract)
        );
    }

    function _sign(uint256 pk, bytes32 domain, bytes32 structHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _transferHash(
        PCECommunityToken token,
        address from,
        address to,
        uint256 value,
        uint256 maxFee,
        bytes32 nonce
    )
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                token.TRANSFER_WITH_FEE_AUTHORIZATION_TYPEHASH(), from, to, value, maxFee, uint256(0), NO_EXPIRY, nonce
            )
        );
    }

    function _signTransfer(
        uint256 pk,
        PCECommunityToken token,
        address from,
        uint256 value,
        uint256 maxFee,
        bytes32 nonce
    )
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            pk, _domain("PeaceBaseCoin", address(token)), _transferHash(token, from, RECIPIENT, value, maxFee, nonce)
        );
    }

    function _relayTransfer(
        PCECommunityToken token,
        address from,
        uint256 value,
        uint256 maxFee,
        bytes32 nonce,
        bytes memory signature
    )
        internal
    {
        vm.prank(RELAYER);
        token.transferWithAuthorization(from, RECIPIENT, value, maxFee, 0, NO_EXPIRY, nonce, signature);
    }

    // ------------------------------------------------- transferWithAuthorization

    function testTransferWithEOASignature() public {
        bytes32 nonce = keccak256("eoa-transfer");
        uint256 fee = tokenA.getMetaTransactionFee();
        assertGt(fee, 0);
        bytes memory sig = _signTransfer(EOA_PK, tokenA, eoa, 5 ether, fee, nonce);

        vm.expectEmit(true, true, false, true, address(tokenA));
        emit EIP3009.AuthorizationExecuted(eoa, nonce, _transferHash(tokenA, eoa, RECIPIENT, 5 ether, fee, nonce));
        _relayTransfer(tokenA, eoa, 5 ether, fee, nonce, sig);

        assertEq(tokenA.balanceOf(RECIPIENT), 5 ether);
        assertGt(pce.balanceOf(RELAYER), 0);
        assertEq(tokenA.balanceOf(RELAYER), 0);
        assertTrue(tokenA.authorizationState(eoa, nonce));
    }

    function testTransferWithERC1271Signature() public {
        bytes32 nonce = keccak256("wallet-transfer");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _signTransfer(WALLET_PK, tokenA, address(wallet), 5 ether, fee, nonce);

        _relayTransfer(tokenA, address(wallet), 5 ether, fee, nonce, sig);

        assertEq(tokenA.balanceOf(RECIPIENT), 5 ether);
        assertGt(pce.balanceOf(RELAYER), 0);
        assertTrue(tokenA.authorizationState(address(wallet), nonce));
    }

    function testTransferRejectsSignatureFromOtherKey() public {
        bytes32 nonce = keccak256("wrong-key");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _signTransfer(EOA_PK, tokenA, address(wallet), 5 ether, fee, nonce);
        vm.expectRevert("Invalid signature");
        _relayTransfer(tokenA, address(wallet), 5 ether, fee, nonce, sig);
        assertFalse(tokenA.authorizationState(address(wallet), nonce));
    }

    function testTransferRejectsSignatureForAnotherAccount() public {
        // Two wallets controlled by the same key: a signature for one must not move the other.
        MockERC1271Wallet other = new MockERC1271Wallet(vm.addr(WALLET_PK));
        tokenA.transfer(address(other), 10 ether);
        bytes32 nonce = keccak256("other-account");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _signTransfer(WALLET_PK, tokenA, address(wallet), 5 ether, fee, nonce);
        vm.expectRevert("Invalid signature");
        _relayTransfer(tokenA, address(other), 5 ether, fee, nonce, sig);
    }

    function testTransferRejectsSignatureForAnotherToken() public {
        tokenB.transfer(address(wallet), 10 ether);
        bytes32 nonce = keccak256("other-token");
        uint256 fee = tokenB.getMetaTransactionFee();
        bytes memory sig = _sign(
            WALLET_PK,
            _domain("PeaceBaseCoin", address(tokenA)),
            _transferHash(tokenB, address(wallet), RECIPIENT, 1 ether, fee, nonce)
        );
        vm.expectRevert("Invalid signature");
        _relayTransfer(tokenB, address(wallet), 1 ether, fee, nonce, sig);
    }

    function testTransferRejectsSignatureForAnotherChain() public {
        bytes32 nonce = keccak256("other-chain");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _signTransfer(WALLET_PK, tokenA, address(wallet), 1 ether, fee, nonce);
        vm.chainId(block.chainid + 1);
        vm.expectRevert("Invalid signature");
        _relayTransfer(tokenA, address(wallet), 1 ether, fee, nonce, sig);
    }

    function testTransferRejectsTamperedAmount() public {
        bytes32 nonce = keccak256("tampered");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _signTransfer(WALLET_PK, tokenA, address(wallet), 1 ether, fee, nonce);
        vm.expectRevert("Invalid signature");
        _relayTransfer(tokenA, address(wallet), 2 ether, fee, nonce, sig);
    }

    function testTransferRejectsReplay() public {
        bytes32 nonce = keccak256("replay");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _signTransfer(WALLET_PK, tokenA, address(wallet), 1 ether, fee, nonce);
        _relayTransfer(tokenA, address(wallet), 1 ether, fee, nonce, sig);
        vm.expectRevert("Authorization used");
        _relayTransfer(tokenA, address(wallet), 1 ether, fee, nonce, sig);
    }

    function testNonceIsSharedWithVRSFunctions() public {
        bytes32 nonce = keccak256("shared-nonce");
        bytes32 legacyHash = keccak256(
            abi.encode(tokenA.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), eoa, RECIPIENT, 1 ether, 0, NO_EXPIRY, nonce)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            EOA_PK, keccak256(abi.encodePacked("\x19\x01", _domain("PeaceBaseCoin", address(tokenA)), legacyHash))
        );
        vm.prank(RELAYER);
        tokenA.transferWithAuthorization(eoa, RECIPIENT, 1 ether, 0, NO_EXPIRY, nonce, v, r, s);

        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _signTransfer(EOA_PK, tokenA, eoa, 1 ether, fee, nonce);
        vm.expectRevert("Authorization used");
        _relayTransfer(tokenA, eoa, 1 ether, fee, nonce, sig);
    }

    function testTransferRejectsExpiredAndNotYetValid() public {
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes32 nonce = keccak256("window");
        uint256 nowTs = block.timestamp;
        bytes32 domain = _domain("PeaceBaseCoin", address(tokenA));

        bytes32 lateHash = keccak256(
            abi.encode(
                tokenA.TRANSFER_WITH_FEE_AUTHORIZATION_TYPEHASH(), eoa, RECIPIENT, 1 ether, fee, nowTs, NO_EXPIRY, nonce
            )
        );
        bytes memory sig = _sign(EOA_PK, domain, lateHash);
        vm.prank(RELAYER);
        vm.expectRevert("Not yet valid");
        tokenA.transferWithAuthorization(eoa, RECIPIENT, 1 ether, fee, nowTs, NO_EXPIRY, nonce, sig);

        bytes32 expiredHash = keccak256(
            abi.encode(tokenA.TRANSFER_WITH_FEE_AUTHORIZATION_TYPEHASH(), eoa, RECIPIENT, 1 ether, fee, 0, nowTs, nonce)
        );
        sig = _sign(EOA_PK, domain, expiredHash);
        vm.prank(RELAYER);
        vm.expectRevert("Authorization expired");
        tokenA.transferWithAuthorization(eoa, RECIPIENT, 1 ether, fee, 0, nowTs, nonce, sig);
    }

    function testTransferRevertsWhenFeeExceedsMaxFee() public {
        bytes32 nonce = keccak256("max-fee");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _signTransfer(EOA_PK, tokenA, eoa, 1 ether, fee - 1, nonce);
        vm.expectRevert("Fee exceeds maxFee");
        _relayTransfer(tokenA, eoa, 1 ether, fee - 1, nonce, sig);
    }

    function testERC1271IsCheckedWithStaticcall() public {
        StatefulERC1271Wallet stateful = new StatefulERC1271Wallet();
        tokenA.transfer(address(stateful), 10 ether);
        bytes32 nonce = keccak256("stateful");
        uint256 fee = tokenA.getMetaTransactionFee();
        vm.expectRevert("Invalid signature");
        _relayTransfer(tokenA, address(stateful), 1 ether, fee, nonce, hex"01");
        assertEq(stateful.calls(), 0);
    }

    function testDelegatedEOAWithCodeStillAcceptsECDSA() public {
        // An EIP-7702 delegated EOA has code but its key still signs for it.
        vm.etch(eoa, address(new StatefulERC1271Wallet()).code);
        bytes32 nonce = keccak256("delegated");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _signTransfer(EOA_PK, tokenA, eoa, 1 ether, fee, nonce);
        _relayTransfer(tokenA, eoa, 1 ether, fee, nonce, sig);
        assertEq(tokenA.balanceOf(RECIPIENT), 1 ether);
    }

    function testRejectsZeroAuthorizer() public {
        vm.prank(RELAYER);
        vm.expectRevert("Invalid authorizer address");
        tokenA.transferWithAuthorization(address(0), RECIPIENT, 1 ether, 1 ether, 0, NO_EXPIRY, bytes32(0), hex"");
    }

    // ---------------------------------------- setInfinityApproveFlagWithAuthorization

    function testSetInfinityApproveFlagWithERC1271Signature() public {
        address spender = address(0x5BE7);
        bytes32 nonce = keccak256("infinity");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes32 structHash = keccak256(
            abi.encode(
                tokenA.SET_INFINITY_APPROVE_FLAG_WITH_FEE_AUTHORIZATION_TYPEHASH(),
                address(wallet),
                spender,
                true,
                fee,
                uint256(0),
                NO_EXPIRY,
                nonce
            )
        );
        bytes memory sig = _sign(WALLET_PK, _domain("PeaceBaseCoin", address(tokenA)), structHash);

        vm.expectEmit(true, true, false, true, address(tokenA));
        emit EIP3009.AuthorizationExecuted(address(wallet), nonce, structHash);
        vm.prank(RELAYER);
        tokenA.setInfinityApproveFlagWithAuthorization(address(wallet), spender, true, fee, 0, NO_EXPIRY, nonce, sig);

        assertTrue(tokenA.getInfinityApproveFlag(address(wallet), spender));
        assertGt(pce.balanceOf(RELAYER), 0);
    }

    function testSetInfinityApproveFlagRevertsWhenFeeExceedsMaxFee() public {
        address spender = address(0x5BE7);
        bytes32 nonce = keccak256("infinity-max-fee");
        bytes32 structHash = keccak256(
            abi.encode(
                tokenA.SET_INFINITY_APPROVE_FLAG_WITH_FEE_AUTHORIZATION_TYPEHASH(),
                eoa,
                spender,
                true,
                uint256(0),
                uint256(0),
                NO_EXPIRY,
                nonce
            )
        );
        bytes memory sig = _sign(EOA_PK, _domain("PeaceBaseCoin", address(tokenA)), structHash);
        vm.prank(RELAYER);
        vm.expectRevert("Fee exceeds maxFee");
        tokenA.setInfinityApproveFlagWithAuthorization(eoa, spender, true, 0, 0, NO_EXPIRY, nonce, sig);
    }

    // ------------------------------------------------- claimVoucherWithAuthorization

    function _registerVoucher(string memory id, string memory code) internal {
        tokenA.registerVoucherIssuance(
            id, "voucher", 10 ether, 1, 10 ether, 10 ether, 0, block.timestamp + 365 days, keccak256(bytes(code)), ""
        );
    }

    function _claimHash(
        address claimer,
        string memory id,
        string memory code,
        bytes32 nonce
    )
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                tokenA.CLAIM_WITH_AUTHORIZATION_TYPEHASH(),
                claimer,
                keccak256(bytes(id)),
                keccak256(bytes(code)),
                uint256(0),
                NO_EXPIRY,
                nonce
            )
        );
    }

    function testClaimVoucherWithERC1271Signature() public {
        _registerVoucher("V1", "CODE-1");
        bytes32 nonce = keccak256("claim");
        bytes32 structHash = _claimHash(address(wallet), "V1", "CODE-1", nonce);
        bytes memory sig = _sign(WALLET_PK, _domain("PeaceBaseCoin", address(tokenA)), structHash);
        uint256 before = tokenA.balanceOf(address(wallet));

        vm.expectEmit(true, true, false, true, address(tokenA));
        emit EIP3009.AuthorizationExecuted(address(wallet), nonce, structHash);
        vm.prank(RELAYER);
        tokenA.claimVoucherWithAuthorization(
            address(wallet), "V1", "CODE-1", new bytes32[](0), 0, NO_EXPIRY, nonce, sig
        );

        assertGt(tokenA.balanceOf(address(wallet)), before);
        assertGt(pce.balanceOf(RELAYER), 0);
    }

    function testClaimVoucherRejectsPermitDomainSignature() public {
        // The bytes version is signed under the "PeaceBaseCoin" domain, not DOMAIN_SEPARATOR().
        _registerVoucher("V2", "CODE-2");
        bytes32 nonce = keccak256("claim-permit-domain");
        bytes memory sig = _sign(EOA_PK, tokenA.DOMAIN_SEPARATOR(), _claimHash(eoa, "V2", "CODE-2", nonce));
        vm.prank(RELAYER);
        vm.expectRevert("Invalid signature");
        tokenA.claimVoucherWithAuthorization(eoa, "V2", "CODE-2", new bytes32[](0), 0, NO_EXPIRY, nonce, sig);
    }

    // ------------------------------------------------- swapTokensWithAuthorization

    function _swapTokensHash(
        address from,
        uint256 value,
        uint256 minOut,
        uint256 maxFee,
        bytes32 nonce
    )
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                tokenA.SWAP_TOKENS_WITH_AUTHORIZATION_TYPEHASH(),
                from,
                address(tokenB),
                value,
                minOut,
                maxFee,
                uint256(0),
                NO_EXPIRY,
                nonce
            )
        );
    }

    function testSwapTokensWithERC1271Signature() public {
        bytes32 nonce = keccak256("swap-tokens");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _sign(
            WALLET_PK,
            _domain("PeaceBaseCoin", address(tokenA)),
            _swapTokensHash(address(wallet), 10 ether, 20 ether, fee, nonce)
        );
        uint256 balanceA = tokenA.balanceOf(address(wallet));
        uint256 depositedA = pce.getDepositedPCETokens(address(tokenA));
        uint256 depositedB = pce.getDepositedPCETokens(address(tokenB));

        vm.prank(RELAYER);
        tokenA.swapTokensWithAuthorization(
            address(wallet), address(tokenB), 10 ether, 20 ether, fee, 0, NO_EXPIRY, nonce, sig
        );

        assertEq(tokenB.balanceOf(address(wallet)), 20 ether);
        assertGe(balanceA - tokenA.balanceOf(address(wallet)), 10 ether + fee);
        uint256 relayerPCE = pce.balanceOf(RELAYER);
        assertGt(relayerPCE, 0);
        // The swap moves 10 PCE of reserve to B; the fee is paid out of A's reserve.
        assertEq(pce.getDepositedPCETokens(address(tokenB)), depositedB + 10 ether);
        assertEq(pce.getDepositedPCETokens(address(tokenA)), depositedA - 10 ether - relayerPCE);
    }

    function testSwapTokensRevertsBelowMinAmountOut() public {
        bytes32 nonce = keccak256("swap-tokens-min");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _sign(
            WALLET_PK,
            _domain("PeaceBaseCoin", address(tokenA)),
            _swapTokensHash(address(wallet), 10 ether, 20 ether + 1, fee, nonce)
        );
        vm.prank(RELAYER);
        vm.expectRevert("Insufficient output amount");
        tokenA.swapTokensWithAuthorization(
            address(wallet), address(tokenB), 10 ether, 20 ether + 1, fee, 0, NO_EXPIRY, nonce, sig
        );
    }

    function testSwapTokensRevertsWhenFeeExceedsMaxFee() public {
        bytes32 nonce = keccak256("swap-tokens-fee");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _sign(
            WALLET_PK,
            _domain("PeaceBaseCoin", address(tokenA)),
            _swapTokensHash(address(wallet), 10 ether, 0, fee - 1, nonce)
        );
        vm.prank(RELAYER);
        vm.expectRevert("Fee exceeds maxFee");
        tokenA.swapTokensWithAuthorization(
            address(wallet), address(tokenB), 10 ether, 0, fee - 1, 0, NO_EXPIRY, nonce, sig
        );
    }

    // ------------------------------------------------- swapToPCEWithAuthorization

    function _swapToPCEHash(
        address from,
        uint256 value,
        uint256 minOut,
        uint256 maxFee,
        bytes32 nonce
    )
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                tokenA.SWAP_TO_PCE_WITH_AUTHORIZATION_TYPEHASH(),
                from,
                value,
                minOut,
                maxFee,
                uint256(0),
                NO_EXPIRY,
                nonce
            )
        );
    }

    function testSwapToPCEWithERC1271Signature() public {
        bytes32 nonce = keccak256("swap-to-pce");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _sign(
            WALLET_PK,
            _domain("PeaceBaseCoin", address(tokenA)),
            _swapToPCEHash(address(wallet), 10 ether, 10 ether, fee, nonce)
        );
        uint256 pceBefore = pce.balanceOf(address(wallet));
        uint256 limitBefore = tokenA.getRemainingSwapableToPCEBalanceForIndividual(address(wallet));

        vm.prank(RELAYER);
        tokenA.swapToPCEWithAuthorization(address(wallet), 10 ether, 10 ether, fee, 0, NO_EXPIRY, nonce, sig);

        assertEq(pce.balanceOf(address(wallet)) - pceBefore, 10 ether);
        assertGt(pce.balanceOf(RELAYER), 0);
        assertEq(tokenA.getRemainingSwapableToPCEBalanceForIndividual(address(wallet)), limitBefore - 10 ether);
    }

    function testSwapToPCERevertsBelowMinAmountOut() public {
        bytes32 nonce = keccak256("swap-to-pce-min");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _sign(
            WALLET_PK,
            _domain("PeaceBaseCoin", address(tokenA)),
            _swapToPCEHash(address(wallet), 10 ether, 10 ether + 1, fee, nonce)
        );
        vm.prank(RELAYER);
        vm.expectRevert("Insufficient output amount");
        tokenA.swapToPCEWithAuthorization(address(wallet), 10 ether, 10 ether + 1, fee, 0, NO_EXPIRY, nonce, sig);
    }

    function testSwapToPCEKeepsIndividualDailyLimit() public {
        uint256 remaining = tokenA.getRemainingSwapableToPCEBalanceForIndividual(address(wallet));
        bytes32 nonce = keccak256("swap-to-pce-limit");
        uint256 fee = tokenA.getMetaTransactionFee();
        bytes memory sig = _sign(
            WALLET_PK,
            _domain("PeaceBaseCoin", address(tokenA)),
            _swapToPCEHash(address(wallet), remaining + 1, 0, fee, nonce)
        );
        vm.prank(RELAYER);
        vm.expectRevert("Exceeds daily individual swap limit");
        tokenA.swapToPCEWithAuthorization(address(wallet), remaining + 1, 0, fee, 0, NO_EXPIRY, nonce, sig);
    }

    function testSwapFromLocalTokenForOnlyCallableByCommunityToken() public {
        vm.prank(RELAYER);
        vm.expectRevert("Caller must be a community token");
        pce.swapFromLocalTokenFor(address(wallet), 1 ether);
    }

    // ------------------------------------------- PCEToken.swapToLocalTokenWithAuthorization

    function _swapToLocalHash(
        address from,
        uint256 value,
        uint256 minOut,
        uint256 maxFee,
        bytes32 nonce
    )
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                pce.SWAP_TO_LOCAL_TOKEN_WITH_AUTHORIZATION_TYPEHASH(),
                from,
                address(tokenB),
                value,
                minOut,
                maxFee,
                uint256(0),
                NO_EXPIRY,
                nonce
            )
        );
    }

    function testSwapToLocalTokenWithERC1271Signature() public {
        bytes32 nonce = keccak256("swap-to-local");
        uint256 fee = pce.getMetaTransactionFee();
        assertGt(fee, 0);
        bytes32 structHash = _swapToLocalHash(address(wallet), 10 ether, 20 ether, fee, nonce);
        bytes memory sig = _sign(WALLET_PK, _domain("PCE Token", address(pce)), structHash);
        uint256 pceBefore = pce.balanceOf(address(wallet));
        uint256 depositedB = pce.getDepositedPCETokens(address(tokenB));

        vm.expectEmit(true, true, false, true, address(pce));
        emit PCEToken.AuthorizationExecuted(address(wallet), nonce, structHash);
        vm.prank(RELAYER);
        pce.swapToLocalTokenWithAuthorization(
            address(wallet), address(tokenB), 10 ether, 20 ether, fee, 0, NO_EXPIRY, nonce, sig
        );

        assertEq(tokenB.balanceOf(address(wallet)), 20 ether);
        assertEq(pceBefore - pce.balanceOf(address(wallet)), 10 ether + fee);
        assertEq(pce.balanceOf(RELAYER), fee);
        assertEq(pce.getDepositedPCETokens(address(tokenB)), depositedB + 10 ether);
        assertTrue(pce.authorizationState(address(wallet), nonce));
    }

    function testSwapToLocalTokenWithEOASignature() public {
        bytes32 nonce = keccak256("swap-to-local-eoa");
        uint256 fee = pce.getMetaTransactionFee();
        bytes memory sig =
            _sign(EOA_PK, _domain("PCE Token", address(pce)), _swapToLocalHash(eoa, 1 ether, 0, fee, nonce));
        vm.prank(RELAYER);
        pce.swapToLocalTokenWithAuthorization(eoa, address(tokenB), 1 ether, 0, fee, 0, NO_EXPIRY, nonce, sig);
        assertEq(tokenB.balanceOf(eoa), 2 ether);
    }

    function testSwapToLocalTokenRejectsNativeMetaDomain() public {
        bytes32 nonce = keccak256("swap-to-local-domain");
        uint256 fee = pce.getMetaTransactionFee();
        bytes memory sig = _sign(
            WALLET_PK, _domain("PeaceBaseCoin", address(pce)), _swapToLocalHash(address(wallet), 1 ether, 0, fee, nonce)
        );
        vm.prank(RELAYER);
        vm.expectRevert("Invalid signature");
        pce.swapToLocalTokenWithAuthorization(
            address(wallet), address(tokenB), 1 ether, 0, fee, 0, NO_EXPIRY, nonce, sig
        );
    }

    function testSwapToLocalTokenRevertsBelowMinAmountOut() public {
        bytes32 nonce = keccak256("swap-to-local-min");
        uint256 fee = pce.getMetaTransactionFee();
        bytes memory sig = _sign(
            WALLET_PK,
            _domain("PCE Token", address(pce)),
            _swapToLocalHash(address(wallet), 1 ether, 2 ether + 1, fee, nonce)
        );
        vm.prank(RELAYER);
        vm.expectRevert("Insufficient output amount");
        pce.swapToLocalTokenWithAuthorization(
            address(wallet), address(tokenB), 1 ether, 2 ether + 1, fee, 0, NO_EXPIRY, nonce, sig
        );
    }

    function testSwapToLocalTokenRevertsWhenFeeExceedsMaxFee() public {
        bytes32 nonce = keccak256("swap-to-local-fee");
        uint256 fee = pce.getMetaTransactionFee();
        bytes memory sig = _sign(
            WALLET_PK, _domain("PCE Token", address(pce)), _swapToLocalHash(address(wallet), 1 ether, 0, fee - 1, nonce)
        );
        vm.prank(RELAYER);
        vm.expectRevert("Fee exceeds maxFee");
        pce.swapToLocalTokenWithAuthorization(
            address(wallet), address(tokenB), 1 ether, 0, fee - 1, 0, NO_EXPIRY, nonce, sig
        );
    }

    function testSwapToLocalTokenRejectsReplay() public {
        bytes32 nonce = keccak256("swap-to-local-replay");
        uint256 fee = pce.getMetaTransactionFee();
        bytes memory sig = _sign(
            WALLET_PK, _domain("PCE Token", address(pce)), _swapToLocalHash(address(wallet), 1 ether, 0, fee, nonce)
        );
        vm.prank(RELAYER);
        pce.swapToLocalTokenWithAuthorization(
            address(wallet), address(tokenB), 1 ether, 0, fee, 0, NO_EXPIRY, nonce, sig
        );
        vm.prank(RELAYER);
        vm.expectRevert("Authorization used");
        pce.swapToLocalTokenWithAuthorization(
            address(wallet), address(tokenB), 1 ether, 0, fee, 0, NO_EXPIRY, nonce, sig
        );
    }

    // ------------------------------------- AuthorizationExecuted on the v, r, s functions

    function testVRSTransferEmitsAuthorizationExecuted() public {
        bytes32 nonce = keccak256("vrs-transfer");
        bytes32 structHash = keccak256(
            abi.encode(tokenA.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), eoa, RECIPIENT, 1 ether, 0, NO_EXPIRY, nonce)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            EOA_PK, keccak256(abi.encodePacked("\x19\x01", _domain("PeaceBaseCoin", address(tokenA)), structHash))
        );
        vm.expectEmit(true, true, false, true, address(tokenA));
        emit EIP3009.AuthorizationExecuted(eoa, nonce, structHash);
        vm.prank(RELAYER);
        tokenA.transferWithAuthorization(eoa, RECIPIENT, 1 ether, 0, NO_EXPIRY, nonce, v, r, s);
    }

    function testVRSTransferFromEmitsAuthorizationExecuted() public {
        vm.prank(eoa);
        tokenA.approve(eoa, 10 ether);
        bytes32 nonce = keccak256("vrs-transfer-from");
        bytes32 structHash = keccak256(
            abi.encode(
                tokenA.TRANSFER_FROM_WITH_AUTHORIZATION_TYPEHASH(), eoa, eoa, RECIPIENT, 1 ether, 0, NO_EXPIRY, nonce
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(EOA_PK, keccak256(abi.encodePacked("\x19\x01", tokenA.DOMAIN_SEPARATOR(), structHash)));
        vm.expectEmit(true, true, false, true, address(tokenA));
        emit EIP3009.AuthorizationExecuted(eoa, nonce, structHash);
        vm.prank(RELAYER);
        tokenA.transferFromWithAuthorization(eoa, eoa, RECIPIENT, 1 ether, 0, NO_EXPIRY, nonce, v, r, s);
    }

    function testVRSSetInfinityApproveFlagEmitsAuthorizationExecuted() public {
        bytes32 nonce = keccak256("vrs-infinity");
        bytes32 structHash = keccak256(
            abi.encode(
                tokenA.SET_INFINITY_APPROVE_FLAG_WITH_AUTHORIZATION_TYPEHASH(),
                eoa,
                address(0x5BE7),
                true,
                uint256(0),
                NO_EXPIRY,
                nonce
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(EOA_PK, keccak256(abi.encodePacked("\x19\x01", tokenA.DOMAIN_SEPARATOR(), structHash)));
        vm.expectEmit(true, true, false, true, address(tokenA));
        emit EIP3009.AuthorizationExecuted(eoa, nonce, structHash);
        vm.prank(RELAYER);
        tokenA.setInfinityApproveFlagWithAuthorization(eoa, address(0x5BE7), true, 0, NO_EXPIRY, nonce, v, r, s);
    }

    function testVRSClaimVoucherEmitsAuthorizationExecuted() public {
        _registerVoucher("V3", "CODE-3");
        bytes32 nonce = keccak256("vrs-claim");
        bytes32 structHash = _claimHash(eoa, "V3", "CODE-3", nonce);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(EOA_PK, keccak256(abi.encodePacked("\x19\x01", tokenA.DOMAIN_SEPARATOR(), structHash)));
        vm.expectEmit(true, true, false, true, address(tokenA));
        emit EIP3009.AuthorizationExecuted(eoa, nonce, structHash);
        vm.prank(RELAYER);
        tokenA.claimVoucherWithAuthorization(eoa, "V3", "CODE-3", new bytes32[](0), 0, NO_EXPIRY, nonce, v, r, s);
    }
}
