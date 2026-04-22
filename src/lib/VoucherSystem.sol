// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ECRecover } from "./ECRecover.sol";

/// @dev Self-call helpers used by public wrapper functions below. The host
///      contract MUST restrict these to `msg.sender == address(this)`.
interface IVoucherHost {
    function __libTransfer(address from, address to, uint256 rawAmount) external;
    function __libCollectFeeAsPCE(address from, address relayer, uint256 displayFee) external;
    function balanceOf(address account) external view returns (uint256);
    function displayBalanceToRawBalance(uint256 displayBalance) external view returns (uint256);
    function getMetaTransactionFee() external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

library VoucherSystem {
    // Error codes for canClaim function
    uint8 public constant ERROR_NONE = 0;
    uint8 public constant ERROR_ISSUANCE_NOT_FOUND = 1;
    uint8 public constant ERROR_ISSUANCE_NOT_ACTIVE = 2;
    uint8 public constant ERROR_NOT_STARTED = 3;
    uint8 public constant ERROR_ALREADY_ENDED = 4;
    uint8 public constant ERROR_CLAIM_LIMIT_REACHED = 5;
    uint8 public constant ERROR_INSUFFICIENT_FUNDS = 6;
    uint8 public constant ERROR_MAX_TOTAL_EXCEEDED = 7;
    uint8 public constant ERROR_INVALID_PROOF = 8;
    uint8 public constant ERROR_CODE_ALREADY_USED = 9;

    struct VoucherIssuance {
        string issuanceId;
        address owner;
        string name;
        uint256 amountPerClaim;
        uint256 countLimitPerUser;
        uint256 totalAmountLimit;
        uint256 startTime;
        uint256 endTime;
        bytes32 merkleRoot;
        bool isActive;
        string ipfsCid;  // Optional IPFS CID for additional metadata
    }

    struct VoucherStorage {
        mapping(string issuanceId => VoucherIssuance issuance) issuances;
        mapping(string issuanceId => mapping(address user => uint256 claimCount)) claimCountPerUser;
        mapping(string issuanceId => mapping(string issueCode => bool isUsed)) isCodeUsed;
        mapping(string issuanceId => uint256 remainingRawAmount) remainingRawAmount;
        mapping(string issuanceId => uint256 claimedRawAmount) claimedRawAmount;
        mapping(string issuanceId => uint256 claimedDisplayAmount) claimedDisplayAmount;
        mapping(string issuanceId => uint256 totalClaimCount) totalClaimCount;
        string[] issuanceIds;
    }

    event VoucherIssuanceRegistered(
        string issuanceId,
        address indexed owner,
        string name,
        uint256 amountPerClaim,
        uint256 countLimitPerUser,
        uint256 totalAmountLimit,
        uint256 initialFundsRawAmount,
        uint256 startTime,
        uint256 endTime,
        bytes32 merkleRoot,
        string ipfsCid
    );

    event VoucherClaimed(string indexed issuanceId, address indexed claimer, string code, uint256 amount);
    event VoucherFundsAdded(string indexed issuanceId, uint256 rawAmount);
    event VoucherFundsWithdrawn(string indexed issuanceId, uint256 rawAmount);
    event VoucherIssuanceTerminated(string indexed issuanceId);

    /// @dev Claim-with-authorization typehash. MUST match the host's typehash.
    bytes32 private constant CLAIM_WITH_AUTHORIZATION_TYPEHASH =
        0x0b6aae1d90e3a85a25061f4c51e754a9cce2a86cf2f51fb09be1001de8fb7c0a;

    /// @dev Matches the EIP3009 event signature so observers cannot distinguish
    ///      whether the host or this library emitted it.
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);


    function registerIssuance(
        VoucherStorage storage self,
        string memory issuanceId,
        string memory name,
        uint256 amountPerClaim,
        uint256 countLimitPerUser,
        uint256 totalAmountLimit,
        uint256 initialFundsRawAmount,
        uint256 startTime,
        uint256 endTime,
        bytes32 merkleRoot,
        address owner,
        string memory ipfsCid
    )
        public
    {
        // endTime == 0 means unlimited duration, otherwise endTime must be after startTime
        require(endTime == 0 || endTime > startTime, "End time should be after start time");
        require(bytes(self.issuances[issuanceId].issuanceId).length == 0, "Issuance ID already exists");

        VoucherIssuance storage issuance = self.issuances[issuanceId];
        issuance.issuanceId = issuanceId;
        issuance.owner = owner;
        issuance.name = name;
        issuance.amountPerClaim = amountPerClaim;
        issuance.countLimitPerUser = countLimitPerUser;
        issuance.totalAmountLimit = totalAmountLimit;
        issuance.startTime = startTime;
        issuance.endTime = endTime;
        issuance.merkleRoot = merkleRoot;
        issuance.isActive = true;
        issuance.ipfsCid = ipfsCid;

        self.remainingRawAmount[issuanceId] = initialFundsRawAmount;
        self.issuanceIds.push(issuanceId);

        emit VoucherIssuanceRegistered(
            issuanceId,
            owner,
            name,
            amountPerClaim,
            countLimitPerUser,
            totalAmountLimit,
            initialFundsRawAmount,
            startTime,
            endTime,
            merkleRoot,
            ipfsCid
        );
    }

    function claim(
        VoucherStorage storage self,
        string memory issuanceId,
        string memory code,
        bytes32[] calldata proof,
        address claimer,
        uint256 claimRawAmount
    )
        public
        returns (uint256)
    {
        VoucherIssuance memory issuance = self.issuances[issuanceId];
        require(bytes(issuance.issuanceId).length != 0, "Issuance not found");
        require(issuance.isActive, "Issuance is not active");

        // Check start time (0 means immediate start)
        require(issuance.startTime == 0 || issuance.startTime < block.timestamp, "Issuance not started");

        // Check end time (0 means unlimited duration)
        require(issuance.endTime == 0 || block.timestamp < issuance.endTime, "Issuance already ended");

        // Check claim count limit per user (0 means unlimited)
        require(issuance.countLimitPerUser == 0 || self.claimCountPerUser[issuanceId][claimer] < issuance.countLimitPerUser, "Claim count reached limitation");
        require(self.remainingRawAmount[issuanceId] >= claimRawAmount, "No more claimable amount");
        if (issuance.totalAmountLimit > 0) {
            require(self.claimedDisplayAmount[issuanceId] + issuance.amountPerClaim <= issuance.totalAmountLimit, "Total amount limit exceeded");
        }
        require(MerkleProof.verify(proof, issuance.merkleRoot, keccak256(abi.encodePacked(code))), "Invalid claim proof");
        require(!self.isCodeUsed[issuanceId][code], "Code already used");

        self.claimCountPerUser[issuanceId][claimer]++;
        self.remainingRawAmount[issuanceId] -= claimRawAmount;
        self.claimedRawAmount[issuanceId] += claimRawAmount;
        self.claimedDisplayAmount[issuanceId] += issuance.amountPerClaim;
        self.totalClaimCount[issuanceId]++;
        self.isCodeUsed[issuanceId][code] = true;

        emit VoucherClaimed(issuanceId, claimer, code, issuance.amountPerClaim);

        return claimRawAmount;
    }

    function addFunds(
        VoucherStorage storage self,
        string memory issuanceId,
        uint256 rawAmount,
        address sender
    )
        public
    {
        VoucherIssuance storage issuance = self.issuances[issuanceId];
        require(bytes(issuance.issuanceId).length != 0, "Issuance not found");
        require(issuance.owner == sender, "Only owner can add funds");
        require(issuance.isActive, "Issuance is not active");

        self.remainingRawAmount[issuanceId] += rawAmount;

        emit VoucherFundsAdded(issuanceId, rawAmount);
    }

    function withdrawFunds(
        VoucherStorage storage self,
        string memory issuanceId,
        uint256 rawAmount,
        address sender
    )
        public
        returns (uint256)
    {
        VoucherIssuance storage issuance = self.issuances[issuanceId];
        require(bytes(issuance.issuanceId).length != 0, "Issuance not found");
        require(issuance.owner == sender, "Only owner can withdraw funds");

        require(self.remainingRawAmount[issuanceId] >= rawAmount, "Insufficient remaining funds");

        self.remainingRawAmount[issuanceId] -= rawAmount;

        emit VoucherFundsWithdrawn(issuanceId, rawAmount);

        return rawAmount;
    }

    function terminateIssuance(
        VoucherStorage storage self,
        string memory issuanceId,
        address sender
    )
        public
        returns (uint256)
    {
        VoucherIssuance storage issuance = self.issuances[issuanceId];
        require(bytes(issuance.issuanceId).length != 0, "Issuance not found");
        require(issuance.owner == sender, "Only owner can terminate issuance");
        require(issuance.isActive, "Issuance is already terminated");

        issuance.isActive = false;

        uint256 remainingRawAmount = self.remainingRawAmount[issuanceId];
        self.remainingRawAmount[issuanceId] = 0;

        emit VoucherIssuanceTerminated(issuanceId);

        return remainingRawAmount;
    }

    function getFundsInfo(
        VoucherStorage storage self,
        string memory issuanceId
    )
        internal
        view
        returns (
            uint256 remainingRawAmount,
            uint256 claimedRawAmount,
            uint256 claimedDisplayAmount,
            uint256 totalClaimCount
        )
    {
        VoucherIssuance memory issuance = self.issuances[issuanceId];
        require(bytes(issuance.issuanceId).length != 0, "Issuance not found");

        return (
            self.remainingRawAmount[issuanceId],
            self.claimedRawAmount[issuanceId],
            self.claimedDisplayAmount[issuanceId],
            self.totalClaimCount[issuanceId]
        );
    }

    function getRemainingRawAmount(
        VoucherStorage storage self,
        string memory issuanceId
    )
        internal
        view
        returns (uint256)
    {
        VoucherIssuance memory issuance = self.issuances[issuanceId];
        require(bytes(issuance.issuanceId).length != 0, "Issuance not found");

        return self.remainingRawAmount[issuanceId];
    }

    function getIssuance(
        VoucherStorage storage self,
        string memory issuanceId
    )
        internal
        view
        returns (VoucherIssuance memory)
    {
        return self.issuances[issuanceId];
    }

    function getIssuanceIds(VoucherStorage storage self) internal view returns (string[] memory) {
        return self.issuanceIds;
    }

    function canClaim(
        VoucherStorage storage self,
        string memory issuanceId,
        string memory code,
        bytes32[] calldata proof,
        address claimer,
        uint256 claimRawAmount
    )
        internal
        view
        returns (bool, uint8)
    {
        VoucherIssuance memory issuance = self.issuances[issuanceId];

        if (bytes(issuance.issuanceId).length == 0) {
            return (false, ERROR_ISSUANCE_NOT_FOUND);
        }

        if (!issuance.isActive) {
            return (false, ERROR_ISSUANCE_NOT_ACTIVE);
        }

        // Check start time (0 means immediate start)
        if (issuance.startTime != 0 && issuance.startTime >= block.timestamp) {
            return (false, ERROR_NOT_STARTED);
        }

        // Check end time (0 means unlimited duration)
        if (issuance.endTime != 0 && block.timestamp >= issuance.endTime) {
            return (false, ERROR_ALREADY_ENDED);
        }

        // Check claim count limit per user (0 means unlimited)
        if (issuance.countLimitPerUser != 0 && self.claimCountPerUser[issuanceId][claimer] >= issuance.countLimitPerUser) {
            return (false, ERROR_CLAIM_LIMIT_REACHED);
        }

        if (self.remainingRawAmount[issuanceId] < claimRawAmount) {
            return (false, ERROR_INSUFFICIENT_FUNDS);
        }

        if (issuance.totalAmountLimit > 0) {
            if (self.claimedDisplayAmount[issuanceId] + issuance.amountPerClaim > issuance.totalAmountLimit) {
                return (false, ERROR_MAX_TOTAL_EXCEEDED);
            }
        }

        if (!MerkleProof.verify(proof, issuance.merkleRoot, keccak256(abi.encodePacked(code)))) {
            return (false, ERROR_INVALID_PROOF);
        }

        if (self.isCodeUsed[issuanceId][code]) {
            return (false, ERROR_CODE_ALREADY_USED);
        }

        return (true, ERROR_NONE);
    }

    // ==================================================================
    //  High-level wrappers (called from PCECommunityToken, handle the
    //  display↔raw conversion and token movements via self-call hooks).
    //  Moving them out of PCECommunityToken keeps its bytecode below the
    //  EVM contract size limit.
    // ==================================================================

    function registerIssuanceWithLock(
        VoucherStorage storage self,
        string memory issuanceId,
        string memory name,
        uint256 amountPerClaim,
        uint256 countLimitPerUser,
        uint256 totalAmountLimit,
        uint256 initialFundsDisplayAmount,
        uint256 startTime,
        uint256 endTime,
        bytes32 merkleRoot,
        string memory ipfsCid
    )
        public
    {
        IVoucherHost host = IVoucherHost(address(this));
        address sender = msg.sender;
        require(!(host.balanceOf(sender) < initialFundsDisplayAmount), "Insufficient balance");
        uint256 initialFundsRawAmount = host.displayBalanceToRawBalance(initialFundsDisplayAmount);

        registerIssuance(
            self, issuanceId, name, amountPerClaim, countLimitPerUser, totalAmountLimit,
            initialFundsRawAmount, startTime, endTime, merkleRoot, sender, ipfsCid
        );

        host.__libTransfer(sender, address(this), initialFundsRawAmount);
    }

    function claimAndTransfer(
        VoucherStorage storage self,
        string memory issuanceId,
        string memory code,
        bytes32[] calldata proof
    )
        public
    {
        IVoucherHost host = IVoucherHost(address(this));
        VoucherIssuance memory issuance = self.issuances[issuanceId];
        uint256 rawClaimAmount = host.displayBalanceToRawBalance(issuance.amountPerClaim);

        address claimer = msg.sender;
        claim(self, issuanceId, code, proof, claimer, rawClaimAmount);
        host.__libTransfer(address(this), claimer, rawClaimAmount);
    }

    function claimWithAuthorizationAndTransfer(
        VoucherStorage storage self,
        mapping(address => mapping(bytes32 => bool)) storage authStates,
        address claimer,
        string memory issuanceId,
        string memory code,
        bytes32[] calldata proof,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address relayer
    )
        public
    {
        IVoucherHost host = IVoucherHost(address(this));

        require(!(block.timestamp <= validAfter), "Not yet valid");
        require(!(block.timestamp >= validBefore), "Authorization expired");
        require(!(authStates[claimer][nonce]), "Authorization used");

        bytes32 digest;
        {
            bytes memory data = abi.encode(
                CLAIM_WITH_AUTHORIZATION_TYPEHASH,
                claimer, keccak256(bytes(issuanceId)), keccak256(bytes(code)),
                validAfter, validBefore, nonce
            );
            digest = keccak256(abi.encodePacked("\x19\x01", host.DOMAIN_SEPARATOR(), keccak256(data)));
        }
        require(!(ECRecover.recover(digest, v, r, s) != claimer), "Invalid signature");
        authStates[claimer][nonce] = true;
        emit AuthorizationUsed(claimer, nonce);

        // Surface the `Issuance not found` error consistently with claim() instead
        // of reverting later via a zero-amount fee check on a non-existent entry.
        require(bytes(self.issuances[issuanceId].issuanceId).length != 0, "Issuance not found");

        uint256 displayFee = host.getMetaTransactionFee();
        uint256 rawFee = host.displayBalanceToRawBalance(displayFee);
        uint256 rawClaimAmount = host.displayBalanceToRawBalance(self.issuances[issuanceId].amountPerClaim);
        require(!(rawClaimAmount <= rawFee), "Claim amount must be greater than fee");

        claim(self, issuanceId, code, proof, claimer, rawClaimAmount);

        host.__libTransfer(address(this), claimer, rawClaimAmount - rawFee);
        // When `displayFee` rounds down to `rawFee == 0` (e.g. extreme
        // rebase factor), we didn't actually withhold anything from the
        // claimer, so skip the PCE swap to avoid paying the relayer out of
        // the PCE reserve without a matching CT burn.
        if (rawFee > 0) {
            host.__libCollectFeeAsPCE(address(this), relayer, displayFee);
        }
    }

    function addFundsWithTransfer(
        VoucherStorage storage self,
        string memory issuanceId,
        uint256 displayAmount
    )
        public
    {
        IVoucherHost host = IVoucherHost(address(this));
        address sender = msg.sender;
        require(!(host.balanceOf(sender) < displayAmount), "Insufficient balance");
        uint256 rawAmount = host.displayBalanceToRawBalance(displayAmount);

        addFunds(self, issuanceId, rawAmount, sender);
        host.__libTransfer(sender, address(this), rawAmount);
    }

    function withdrawFundsWithTransfer(
        VoucherStorage storage self,
        string memory issuanceId,
        uint256 displayAmount
    )
        public
    {
        IVoucherHost host = IVoucherHost(address(this));
        uint256 rawAmount = host.displayBalanceToRawBalance(displayAmount);
        address sender = msg.sender;

        uint256 withdrawnRawAmount = withdrawFunds(self, issuanceId, rawAmount, sender);
        host.__libTransfer(address(this), sender, withdrawnRawAmount);
    }

    function terminateWithRefund(
        VoucherStorage storage self,
        string memory issuanceId
    )
        public
    {
        IVoucherHost host = IVoucherHost(address(this));
        address sender = msg.sender;

        uint256 remainingRawAmount = terminateIssuance(self, issuanceId, sender);
        if (remainingRawAmount > 0) {
            host.__libTransfer(address(this), sender, remainingRawAmount);
        }
    }
}
