// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PCECommunityToken} from "../src/PCECommunityToken.sol";
import {PCEToken} from "../src/PCEToken.sol";
import {ExchangeAllowMethod} from "../src/lib/Enum.sol";

contract MinimalBeacon {
    address public implementation;
    address public owner;

    constructor(address initialImplementation) {
        implementation = initialImplementation;
        owner = msg.sender;
    }

    function upgradeTo(address newImplementation) public {
        require(msg.sender == owner, "Ownable: caller is not the owner");
        implementation = newImplementation;
    }
}

contract InterCommunitySwapTest is Test {
    PCEToken public pceToken;
    PCECommunityToken public tokenA;
    PCECommunityToken public tokenB;
    MinimalBeacon public beacon;

    address public owner;
    address public user1;
    address public user2;

    uint256 constant INITIAL_DEPOSIT_A = 1000 ether;
    uint256 constant INITIAL_DEPOSIT_B = 500 ether;

    event DepositTransferredOnInterCommunitySwap(
        address indexed fromToken, address indexed toToken, uint256 fromDisplayAmount, uint256 movedPceAmount
    );

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        vm.startPrank(owner);

        PCECommunityToken communityImpl = new PCECommunityToken();
        beacon = new MinimalBeacon(address(communityImpl));

        pceToken = new PCEToken();
        pceToken.initialize();

        // V1-storage simulation matching PCE.t.sol setUp
        vm.store(address(pceToken), bytes32(uint256(3)), bytes32(uint256(396140812571321687967719751680)));
        vm.store(address(pceToken), bytes32(uint256(4)), bytes32(uint256(200000)));
        vm.store(address(pceToken), bytes32(uint256(5)), bytes32(uint256(50000000000)));
        vm.store(address(pceToken), bytes32(uint256(6)), bytes32(uint256(300)));
        vm.store(address(pceToken), bytes32(uint256(7)), bytes32(uint256(300)));

        pceToken.setCommunityTokenAddress(address(beacon));
        pceToken.mint(owner, 100000 ether);

        address[] memory empty = new address[](0);

        pceToken.createToken(
            "Community A", "CA",
            INITIAL_DEPOSIT_A,
            1 ether,
            1, 9800, 1000, 500, 1000, 100,
            ExchangeAllowMethod.All, ExchangeAllowMethod.All,
            empty, empty
        );
        pceToken.createToken(
            "Community B", "CB",
            INITIAL_DEPOSIT_B,
            1 ether,
            1, 9800, 1000, 500, 1000, 100,
            ExchangeAllowMethod.All, ExchangeAllowMethod.All,
            empty, empty
        );

        vm.stopPrank();

        address[] memory tokens_ = pceToken.getTokens();
        tokenA = PCECommunityToken(tokens_[0]);
        tokenB = PCECommunityToken(tokens_[1]);
    }

    function _expectedMovedPce(uint256 displayAmount) internal view returns (uint256) {
        uint256 a = (displayAmount * pceToken.INITIAL_FACTOR()) / pceToken.getExchangeRate(address(tokenA));
        return (a * pceToken.lastModifiedFactor()) / tokenA.getCurrentFactor();
    }

    function testInterCommunitySwapMovesDeposit() public {
        vm.startPrank(owner);

        uint256 depositABefore = pceToken.getDepositedPCETokens(address(tokenA));
        uint256 depositBBefore = pceToken.getDepositedPCETokens(address(tokenB));
        assertEq(depositABefore, INITIAL_DEPOSIT_A);
        assertEq(depositBBefore, INITIAL_DEPOSIT_B);

        uint256 swapAmount = 30 ether;
        uint256 expectedMoved = _expectedMovedPce(swapAmount);

        tokenA.swapTokens(address(tokenB), swapAmount);

        assertEq(pceToken.getDepositedPCETokens(address(tokenA)), depositABefore - expectedMoved);
        assertEq(pceToken.getDepositedPCETokens(address(tokenB)), depositBBefore + expectedMoved);

        vm.stopPrank();
    }

    function testTotalDepositInvariantUnderInterCommunitySwap() public {
        vm.startPrank(owner);

        uint256 totalBefore =
            pceToken.getDepositedPCETokens(address(tokenA)) + pceToken.getDepositedPCETokens(address(tokenB));

        tokenA.swapTokens(address(tokenB), 50 ether);
        tokenB.swapTokens(address(tokenA), 10 ether);
        tokenA.swapTokens(address(tokenB), 7 ether);

        uint256 totalAfter =
            pceToken.getDepositedPCETokens(address(tokenA)) + pceToken.getDepositedPCETokens(address(tokenB));

        assertEq(totalAfter, totalBefore, "Total per-community deposit must be invariant under inter-community swaps");

        vm.stopPrank();
    }

    function testDirectAndIndirectPathsProduceSameDeposits() public {
        // Pre-stage time so both paths see the same decay state. swapFromLocalToken needs
        // a midnight balance, which requires a warp + transfer + warp before the snapshot.
        vm.startPrank(owner);
        vm.warp(block.timestamp + 1 days);
        tokenA.transfer(user1, 1 wei);
        vm.warp(block.timestamp + 1 days);
        vm.stopPrank();

        uint256 swapAmount = 25 ether;
        uint256 snapshotId = vm.snapshotState();

        // Direct path
        vm.startPrank(owner);
        tokenA.swapTokens(address(tokenB), swapAmount);
        uint256 directDepositA = pceToken.getDepositedPCETokens(address(tokenA));
        uint256 directDepositB = pceToken.getDepositedPCETokens(address(tokenB));
        vm.stopPrank();

        vm.revertToState(snapshotId);

        // Indirect path: A -> PCE -> B (must use the actual PCE returned by swapFromLocalToken)
        vm.startPrank(owner);
        uint256 pceBalanceBefore = pceToken.balanceOf(owner);
        pceToken.swapFromLocalToken(address(tokenA), swapAmount);
        uint256 pceReceived = pceToken.balanceOf(owner) - pceBalanceBefore;
        pceToken.swapToLocalToken(address(tokenB), pceReceived);
        uint256 indirectDepositA = pceToken.getDepositedPCETokens(address(tokenA));
        uint256 indirectDepositB = pceToken.getDepositedPCETokens(address(tokenB));
        vm.stopPrank();

        assertEq(directDepositA, indirectDepositA, "A deposit must match between direct and indirect paths");
        assertEq(directDepositB, indirectDepositB, "B deposit must match between direct and indirect paths");
    }

    function testRevertsWhenSourceDepositInsufficient() public {
        // Force an under-collateralized A by directly editing the deposit slot, then attempt
        // an inter-community swap whose PCE-equivalent exceeds A's recorded deposit.
        vm.startPrank(owner);

        // Drop A's recorded deposit to 1 ether while leaving owner's tokenA balance intact.
        // localTokens is a mapping; LocalToken struct lays out (isExists, exchangeRate, depositedPCEToken).
        // Compute slot for localTokens[address(tokenA)].depositedPCEToken (struct field offset 2 within mapping value).
        bytes32 mappingSlot = bytes32(uint256(10)); // slot of `localTokens` per forge inspect storageLayout
        bytes32 baseSlot = keccak256(abi.encode(address(tokenA), mappingSlot));
        bytes32 depositedSlot = bytes32(uint256(baseSlot) + 2);
        vm.store(address(pceToken), depositedSlot, bytes32(uint256(1 ether)));
        assertEq(pceToken.getDepositedPCETokens(address(tokenA)), 1 ether);

        // Owner holds 1000 ether of tokenA from createToken; try to swap 100 ether (PCE-equiv ≈ 100e18).
        vm.expectRevert("Insufficient deposited PCE token reserve at source community");
        tokenA.swapTokens(address(tokenB), 100 ether);

        vm.stopPrank();
    }

    function testExecuteCallableOnlyByFromToken() public {
        vm.expectRevert("Caller must be the from-side community token");
        vm.prank(user1);
        pceToken.executeInterCommunitySwap(address(tokenA), address(tokenB), user1, 1 ether, 1 ether);
    }

    function testExecuteRejectsSameToken() public {
        vm.expectRevert("Same-token swap");
        vm.prank(address(tokenA));
        pceToken.executeInterCommunitySwap(address(tokenA), address(tokenA), user1, 1 ether, 1 ether);
    }

    function testExecuteRejectsUnregisteredFrom() public {
        address fakeToken = address(0xdead);
        vm.expectRevert("From token not registered");
        vm.prank(fakeToken);
        pceToken.executeInterCommunitySwap(fakeToken, address(tokenB), user1, 1 ether, 1 ether);
    }

    function testExecuteRejectsUnregisteredTo() public {
        address fakeToken = address(0xdead);
        vm.expectRevert("To token not registered");
        vm.prank(address(tokenA));
        pceToken.executeInterCommunitySwap(address(tokenA), fakeToken, user1, 1 ether, 1 ether);
    }
}
