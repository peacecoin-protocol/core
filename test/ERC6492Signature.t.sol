// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { PCEToken } from "../src/PCEToken.sol";
import { PCECommunityToken } from "../src/PCECommunityToken.sol";
import { ExchangeAllowMethod } from "../src/lib/Enum.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { MockERC1271Wallet } from "./BytesSignatureAuthorization.t.sol";
import { ERC6492FactoryCaller } from "../src/lib/ERC6492FactoryCaller.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @dev Counterfactual wallet factory: deploys a MockERC1271Wallet at a CREATE2 address.
contract MockWalletFactory {
    uint256 public deployCount;

    function deploy(address owner, bytes32 salt) external returns (address wallet) {
        deployCount++;
        wallet = address(new MockERC1271Wallet{ salt: salt }(owner));
    }

    function predict(address owner, bytes32 salt) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(type(MockERC1271Wallet).creationCode, abi.encode(owner)))
            )
        );
        return address(uint160(uint256(hash)));
    }
}

/// @dev Factory that deploys the wallet and, in the same call, calls the token with armed calldata
/// (the same authorization again, or another one).
contract ReentrantFactory {
    MockWalletFactory public immutable inner;
    bytes public replayCall;
    address public replayTarget;
    bool public replaySucceeded;
    bytes public replayReturnData;

    constructor(MockWalletFactory inner_) {
        inner = inner_;
    }

    function arm(address target, bytes calldata data) external {
        replayTarget = target;
        replayCall = data;
    }

    function deploy(address owner, bytes32 salt) external {
        inner.deploy(owner, salt);
        (replaySucceeded, replayReturnData) = replayTarget.call(replayCall);
    }
}

/// @dev Factory that records who called it before deploying the wallet.
contract RecordingFactory {
    MockWalletFactory public immutable inner;
    address public lastCaller;

    constructor(MockWalletFactory inner_) {
        inner = inner_;
    }

    function deploy(address owner, bytes32 salt) external {
        lastCaller = msg.sender;
        inner.deploy(owner, salt);
    }
}

contract RevertingFactory {
    function deploy() external pure {
        revert("no deploy");
    }
}

contract ERC6492SignatureTest is Test {
    PCEToken internal pce;
    PCECommunityToken internal token;
    MockWalletFactory internal factory;

    uint256 internal constant OWNER_PK = 0x6492;
    address internal owner;
    bytes32 internal constant SALT = keccak256("wallet");
    address internal counterfactual;
    address internal constant RELAYER = address(0xF00D);
    address internal constant RECIPIENT = address(0xCAFE);
    uint256 internal constant NO_EXPIRY = type(uint256).max;
    bytes32 internal constant SUFFIX = 0x6492649264926492649264926492649264926492649264926492649264926492;

    function setUp() public {
        pce = PCEToken(deployCode("PCEToken.sol:PCEToken"));
        pce.initialize();
        UpgradeableBeacon beacon =
            new UpgradeableBeacon(deployCode("PCECommunityToken.sol:PCECommunityToken"), address(this));
        pce.setCommunityTokenAddress(address(beacon));
        vm.store(address(pce), bytes32(uint256(3)), bytes32(uint256(396_140_812_571_321_687_967_719_751_680)));
        vm.store(address(pce), bytes32(uint256(4)), bytes32(uint256(200_000)));
        vm.store(address(pce), bytes32(uint256(5)), bytes32(uint256(50_000_000_000)));
        pce.mint(address(this), 10_000 ether);
        pce.createToken(
            "Token",
            "TKN",
            1000 ether,
            1 ether,
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
        token = PCECommunityToken(pce.getTokens()[0]);

        owner = vm.addr(OWNER_PK);
        factory = new MockWalletFactory();
        counterfactual = factory.predict(owner, SALT);
        // A counterfactual account can receive tokens before it is deployed.
        token.transfer(counterfactual, 100 ether);
        pce.transfer(counterfactual, 100 ether);
        vm.warp(block.timestamp + 1 days);
    }

    function _domain(string memory name, address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                verifyingContract
            )
        );
    }

    function _sign(uint256 pk, bytes32 domain, bytes32 structHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _wrap(
        address factory_,
        bytes memory factoryCalldata,
        bytes memory signature
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(abi.encode(factory_, factoryCalldata, signature), SUFFIX);
    }

    function _deployCalldata() internal view returns (bytes memory) {
        return abi.encodeCall(MockWalletFactory.deploy, (owner, SALT));
    }

    function _transferSignature(
        address from,
        uint256 value,
        uint256 maxFee,
        bytes32 nonce,
        uint256 pk
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                token.TRANSFER_WITH_FEE_AUTHORIZATION_TYPEHASH(),
                from,
                RECIPIENT,
                value,
                maxFee,
                uint256(0),
                NO_EXPIRY,
                nonce
            )
        );
        return _sign(pk, _domain("PeaceBaseCoin", address(token)), structHash);
    }

    function _relay(address from, uint256 value, uint256 maxFee, bytes32 nonce, bytes memory signature) internal {
        vm.prank(RELAYER);
        token.transferWithAuthorization(from, RECIPIENT, value, maxFee, 0, NO_EXPIRY, nonce, signature);
    }

    function testUndeployedAccountIsDeployedAndAccepted() public {
        assertEq(counterfactual.code.length, 0);
        bytes32 nonce = keccak256("deploy");
        uint256 fee = token.getMetaTransactionFee();
        bytes memory sig = _wrap(
            address(factory), _deployCalldata(), _transferSignature(counterfactual, 5 ether, fee, nonce, OWNER_PK)
        );

        _relay(counterfactual, 5 ether, fee, nonce, sig);

        assertGt(counterfactual.code.length, 0);
        assertEq(factory.deployCount(), 1);
        assertEq(token.balanceOf(RECIPIENT), 5 ether);
        assertGt(pce.balanceOf(RELAYER), 0);
    }

    function testDeployedAccountSkipsFactory() public {
        factory.deploy(owner, SALT);
        bytes32 nonce = keccak256("deployed");
        uint256 fee = token.getMetaTransactionFee();
        // The wrapper names a factory that would revert; it must not be called.
        bytes memory sig = _wrap(
            address(new RevertingFactory()),
            abi.encodeCall(RevertingFactory.deploy, ()),
            _transferSignature(counterfactual, 5 ether, fee, nonce, OWNER_PK)
        );

        _relay(counterfactual, 5 ether, fee, nonce, sig);

        assertEq(factory.deployCount(), 1);
        assertEq(token.balanceOf(RECIPIENT), 5 ether);
    }

    function testWrongInnerSignatureIsRejectedAfterDeploy() public {
        bytes32 nonce = keccak256("wrong-inner");
        uint256 fee = token.getMetaTransactionFee();
        bytes memory sig =
            _wrap(address(factory), _deployCalldata(), _transferSignature(counterfactual, 5 ether, fee, nonce, 0xBAD));
        vm.expectRevert("Invalid signature");
        _relay(counterfactual, 5 ether, fee, nonce, sig);
    }

    function testRevertingFactoryRejectsEvenAValidEOASignature() public {
        uint256 eoaPk = 0xE0A;
        address eoa = vm.addr(eoaPk);
        token.transfer(eoa, 10 ether);
        bytes32 nonce = keccak256("failing-factory");
        uint256 fee = token.getMetaTransactionFee();
        bytes memory sig = _wrap(
            address(new RevertingFactory()),
            abi.encodeCall(RevertingFactory.deploy, ()),
            _transferSignature(eoa, 1 ether, fee, nonce, eoaPk)
        );
        vm.expectRevert("Invalid signature");
        _relay(eoa, 1 ether, fee, nonce, sig);
    }

    function testFactoryDeployingElsewhereIsRejected() public {
        // The factory succeeds but deploys a different address, so the signer still has no code.
        bytes32 nonce = keccak256("elsewhere");
        uint256 fee = token.getMetaTransactionFee();
        bytes memory sig = _wrap(
            address(factory),
            abi.encodeCall(MockWalletFactory.deploy, (owner, keccak256("other"))),
            _transferSignature(counterfactual, 1 ether, fee, nonce, OWNER_PK)
        );
        vm.expectRevert("Invalid signature");
        _relay(counterfactual, 1 ether, fee, nonce, sig);
    }

    function testReentrantFactoryCannotExecuteTheAuthorizationTwice() public {
        ReentrantFactory reentrant = new ReentrantFactory(factory);
        bytes32 nonce = keccak256("reentrant");
        uint256 fee = token.getMetaTransactionFee();
        bytes memory inner = _transferSignature(counterfactual, 5 ether, fee, nonce, OWNER_PK);
        // A third party re-wraps a genuine signature with its own factory, which replays the same
        // authorization from inside the factory call.
        bytes memory replaySig = _wrap(address(factory), _deployCalldata(), inner);
        reentrant.arm(
            address(token),
            abi.encodeWithSignature(
                "transferWithAuthorization(address,address,uint256,uint256,uint256,uint256,bytes32,bytes)",
                counterfactual,
                RECIPIENT,
                5 ether,
                fee,
                0,
                NO_EXPIRY,
                nonce,
                replaySig
            )
        );
        bytes memory sig = _wrap(address(reentrant), abi.encodeCall(ReentrantFactory.deploy, (owner, SALT)), inner);

        _relay(counterfactual, 5 ether, fee, nonce, sig);

        assertFalse(reentrant.replaySucceeded());
        assertEq(token.balanceOf(RECIPIENT), 5 ether);
    }

    /// @dev Relays an undeployed-account transfer whose factory, during deployment, calls `data` on the token.
    function _relayWithFactoryCallback(bytes memory data) internal returns (ReentrantFactory reentrant) {
        reentrant = new ReentrantFactory(factory);
        reentrant.arm(address(token), data);
        bytes32 nonce = keccak256("outer");
        uint256 fee = token.getMetaTransactionFee();
        bytes memory sig = _wrap(
            address(reentrant),
            abi.encodeCall(ReentrantFactory.deploy, (owner, SALT)),
            _transferSignature(counterfactual, 1 ether, fee, nonce, OWNER_PK)
        );
        _relay(counterfactual, 1 ether, fee, nonce, sig);
        assertEq(token.balanceOf(RECIPIENT), 1 ether);
    }

    function _assertGuardRejected(ReentrantFactory reentrant) internal view {
        assertFalse(reentrant.replaySucceeded());
        assertEq(
            reentrant.replayReturnData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
    }

    function testFactoryCannotRunAnotherBytesAuthorization() public {
        // A second, valid authorization with an unused nonce is rejected by the guard, not the nonce.
        uint256 eoaPk = 0xE0A;
        address eoa = vm.addr(eoaPk);
        token.transfer(eoa, 10 ether);
        bytes32 nonce2 = keccak256("second-bytes");
        uint256 fee = token.getMetaTransactionFee();
        ReentrantFactory reentrant = _relayWithFactoryCallback(
            abi.encodeWithSignature(
                "transferWithAuthorization(address,address,uint256,uint256,uint256,uint256,bytes32,bytes)",
                eoa,
                RECIPIENT,
                2 ether,
                fee,
                0,
                NO_EXPIRY,
                nonce2,
                _transferSignature(eoa, 2 ether, fee, nonce2, eoaPk)
            )
        );
        _assertGuardRejected(reentrant);
        assertFalse(token.authorizationState(eoa, nonce2));
    }

    function testFactoryCannotRunAnotherVRSAuthorization() public {
        uint256 eoaPk = 0xE0B;
        address eoa = vm.addr(eoaPk);
        token.transfer(eoa, 10 ether);
        bytes32 nonce2 = keccak256("second-vrs");
        bytes32 structHash = keccak256(
            abi.encode(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), eoa, RECIPIENT, 2 ether, 0, NO_EXPIRY, nonce2)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            eoaPk, keccak256(abi.encodePacked("\x19\x01", _domain("PeaceBaseCoin", address(token)), structHash))
        );
        ReentrantFactory reentrant = _relayWithFactoryCallback(
            abi.encodeWithSignature(
                "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)",
                eoa,
                RECIPIENT,
                2 ether,
                0,
                NO_EXPIRY,
                nonce2,
                v,
                r,
                s
            )
        );
        _assertGuardRejected(reentrant);
        assertFalse(token.authorizationState(eoa, nonce2));
    }

    function _swapToLocalHash(
        address from,
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
                pce.SWAP_TO_LOCAL_TOKEN_WITH_AUTHORIZATION_TYPEHASH(),
                from,
                address(token),
                value,
                uint256(0),
                maxFee,
                uint256(0),
                NO_EXPIRY,
                nonce
            )
        );
    }

    function testFactoryCannotRunAnotherPCETokenAuthorization() public {
        uint256 eoaPk = 0xE0C;
        address eoa = vm.addr(eoaPk);
        pce.transfer(eoa, 10 ether);
        uint256 fee = pce.getMetaTransactionFee();
        bytes32 nonce2 = keccak256("second-pce");
        ReentrantFactory reentrant = new ReentrantFactory(factory);
        reentrant.arm(
            address(pce),
            abi.encodeCall(
                PCEToken.swapToLocalTokenWithAuthorization,
                (
                    eoa,
                    address(token),
                    1 ether,
                    0,
                    fee,
                    0,
                    NO_EXPIRY,
                    nonce2,
                    _sign(eoaPk, _domain("PCE Token", address(pce)), _swapToLocalHash(eoa, 1 ether, fee, nonce2))
                )
            )
        );
        bytes32 nonce = keccak256("outer-pce");
        bytes memory sig = _wrap(
            address(reentrant),
            abi.encodeCall(ReentrantFactory.deploy, (owner, SALT)),
            _sign(OWNER_PK, _domain("PCE Token", address(pce)), _swapToLocalHash(counterfactual, 1 ether, fee, nonce))
        );

        vm.prank(RELAYER);
        pce.swapToLocalTokenWithAuthorization(counterfactual, address(token), 1 ether, 0, fee, 0, NO_EXPIRY, nonce, sig);

        _assertGuardRejected(reentrant);
        assertFalse(pce.authorizationState(eoa, nonce2));
        assertEq(token.balanceOf(eoa), 0);
    }

    function testFactoryIsNotCalledByTheToken() public {
        RecordingFactory recording = new RecordingFactory(factory);
        bytes32 nonce = keccak256("recording");
        uint256 fee = token.getMetaTransactionFee();
        bytes memory sig = _wrap(
            address(recording),
            abi.encodeCall(RecordingFactory.deploy, (owner, SALT)),
            _transferSignature(counterfactual, 1 ether, fee, nonce, OWNER_PK)
        );

        _relay(counterfactual, 1 ether, fee, nonce, sig);

        address caller = recording.lastCaller();
        assertTrue(caller != address(0));
        assertTrue(caller != address(token));
        assertTrue(caller != address(pce));
        assertTrue(caller != RELAYER);
        // The caller is a stateless helper created by the token and holds nothing.
        assertGt(caller.code.length, 0);
        assertEq(token.balanceOf(caller), 0);
        assertEq(pce.balanceOf(caller), 0);

        // Called directly, the helper cannot reach the token's self-only hook either.
        uint256 before = token.balanceOf(counterfactual);
        ERC6492FactoryCaller(caller).callFactory(
            address(token), abi.encodeCall(PCECommunityToken.__libTransfer, (counterfactual, address(0xA77AC), 1))
        );
        assertEq(token.balanceOf(counterfactual), before);
        assertEq(token.balanceOf(address(0xA77AC)), 0);
    }

    function testFactoryCannotActAsTheToken() public {
        // factory = the token itself, calldata = the self-only transfer hook.
        address victim = address(0xD0E);
        token.transfer(victim, 50 ether);
        uint256 victimRaw = token.displayBalanceToRawBalance(token.balanceOf(victim));
        bytes32 nonce = keccak256("self-call");
        uint256 fee = token.getMetaTransactionFee();
        bytes memory sig = _wrap(
            address(token),
            abi.encodeCall(PCECommunityToken.__libTransfer, (victim, address(0xA77AC), victimRaw)),
            _transferSignature(counterfactual, 1 ether, fee, nonce, OWNER_PK)
        );
        vm.expectRevert("Invalid signature");
        _relay(counterfactual, 1 ether, fee, nonce, sig);
        assertEq(token.balanceOf(address(0xA77AC)), 0);
    }

    function testFactoryCannotActAsACommunityTokenOnPCEToken() public {
        // factory = PCEToken, calldata = a community-token-only fee payout.
        bytes32 nonce = keccak256("pce-call");
        uint256 fee = token.getMetaTransactionFee();
        uint256 reserve = pce.getDepositedPCETokens(address(token));
        bytes memory sig = _wrap(
            address(pce),
            abi.encodeCall(PCEToken.swapFeeFromLocalToken, (address(token), address(0xA77AC), 100 ether)),
            _transferSignature(counterfactual, 1 ether, fee, nonce, OWNER_PK)
        );
        vm.expectRevert("Invalid signature");
        _relay(counterfactual, 1 ether, fee, nonce, sig);
        assertEq(pce.balanceOf(address(0xA77AC)), 0);
        assertEq(pce.getDepositedPCETokens(address(token)), reserve);
    }

    function testFactoryCallerIsReusedAcrossCalls() public {
        bytes32 nonce = keccak256("first");
        uint256 fee = token.getMetaTransactionFee();
        bytes memory sig = _wrap(
            address(factory), _deployCalldata(), _transferSignature(counterfactual, 1 ether, fee, nonce, OWNER_PK)
        );
        _relay(counterfactual, 1 ether, fee, nonce, sig);

        // A second undeployed account on the same token reuses the same caller contract.
        bytes32 salt2 = keccak256("wallet-2");
        address second = factory.predict(owner, salt2);
        token.transfer(second, 10 ether);
        bytes32 nonce2 = keccak256("second");
        bytes memory sig2 = _wrap(
            address(factory),
            abi.encodeCall(MockWalletFactory.deploy, (owner, salt2)),
            _transferSignature(second, 1 ether, fee, nonce2, OWNER_PK)
        );
        _relay(second, 1 ether, fee, nonce2, sig2);
        assertGt(second.code.length, 0);
        assertEq(token.balanceOf(RECIPIENT), 2 ether);
    }

    function testPCETokenSwapAcceptsERC6492() public {
        bytes32 nonce = keccak256("pce-6492");
        uint256 fee = pce.getMetaTransactionFee();
        bytes32 structHash = keccak256(
            abi.encode(
                pce.SWAP_TO_LOCAL_TOKEN_WITH_AUTHORIZATION_TYPEHASH(),
                counterfactual,
                address(token),
                uint256(1 ether),
                uint256(1 ether),
                fee,
                uint256(0),
                NO_EXPIRY,
                nonce
            )
        );
        bytes memory sig =
            _wrap(address(factory), _deployCalldata(), _sign(OWNER_PK, _domain("PCE Token", address(pce)), structHash));
        uint256 before = token.balanceOf(counterfactual);

        vm.prank(RELAYER);
        pce.swapToLocalTokenWithAuthorization(
            counterfactual, address(token), 1 ether, 1 ether, fee, 0, NO_EXPIRY, nonce, sig
        );

        assertGt(counterfactual.code.length, 0);
        assertEq(token.balanceOf(counterfactual) - before, 1 ether);
        assertEq(pce.balanceOf(RELAYER), fee);
    }
}
