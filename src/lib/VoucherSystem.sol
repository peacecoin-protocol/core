// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

library VoucherSystem {
    uint8 internal constant ERROR_NONE = 0;
    uint8 internal constant ERROR_ISSUANCE_NOT_FOUND = 1;
    uint8 internal constant ERROR_ISSUANCE_NOT_ACTIVE = 2;
    uint8 internal constant ERROR_NOT_STARTED = 3;
    uint8 internal constant ERROR_ALREADY_ENDED = 4;
    uint8 internal constant ERROR_CLAIM_LIMIT_REACHED = 5;
    uint8 internal constant ERROR_INSUFFICIENT_FUNDS = 6;
    uint8 internal constant ERROR_MAX_TOTAL_EXCEEDED = 7;
    uint8 internal constant ERROR_INVALID_PROOF = 8;
    uint8 internal constant ERROR_CODE_ALREADY_USED = 9;

    error IssuanceNotFound();
    error IssuanceAlreadyExists();
    error IssuanceNotActive();
    error IssuanceNotStarted();
    error IssuanceAlreadyEnded();
    error ClaimLimitReached();
    error NoClaimableAmount();
    error TotalAmountLimitExceeded();
    error InvalidClaimProof();
    error CodeAlreadyUsed();
    error EndTimeBeforeStartTime();
    error OnlyIssuanceOwner();
    error InsufficientRemainingFunds();
    error IssuanceAlreadyTerminated();

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
        string ipfsCid;
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
        internal
    {
        // endTime == 0 means unlimited duration, otherwise endTime must be after startTime
        if (endTime != 0 && endTime <= startTime) revert EndTimeBeforeStartTime();
        if (bytes(self.issuances[issuanceId].issuanceId).length != 0) revert IssuanceAlreadyExists();

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
        internal
        returns (uint256)
    {
        VoucherIssuance memory issuance = self.issuances[issuanceId];
        if (bytes(issuance.issuanceId).length == 0) revert IssuanceNotFound();
        if (!issuance.isActive) revert IssuanceNotActive();
        if (issuance.startTime != 0 && issuance.startTime >= block.timestamp) revert IssuanceNotStarted();
        if (issuance.endTime != 0 && block.timestamp >= issuance.endTime) revert IssuanceAlreadyEnded();
        if (issuance.countLimitPerUser != 0 && self.claimCountPerUser[issuanceId][claimer] >= issuance.countLimitPerUser) {
            revert ClaimLimitReached();
        }
        if (self.remainingRawAmount[issuanceId] < claimRawAmount) revert NoClaimableAmount();
        if (issuance.totalAmountLimit > 0) {
            if (self.claimedDisplayAmount[issuanceId] + issuance.amountPerClaim > issuance.totalAmountLimit) {
                revert TotalAmountLimitExceeded();
            }
        }
        if (!MerkleProof.verify(proof, issuance.merkleRoot, keccak256(abi.encodePacked(code)))) {
            revert InvalidClaimProof();
        }
        if (self.isCodeUsed[issuanceId][code]) revert CodeAlreadyUsed();

        self.claimCountPerUser[issuanceId][claimer]++;
        self.claimedRawAmount[issuanceId] += claimRawAmount;
        self.claimedDisplayAmount[issuanceId] += issuance.amountPerClaim;
        self.totalClaimCount[issuanceId]++;
        unchecked {
            self.remainingRawAmount[issuanceId] -= claimRawAmount;
        }
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
        internal
    {
        VoucherIssuance storage issuance = self.issuances[issuanceId];
        if (bytes(issuance.issuanceId).length == 0) revert IssuanceNotFound();
        if (issuance.owner != sender) revert OnlyIssuanceOwner();
        if (!issuance.isActive) revert IssuanceNotActive();

        self.remainingRawAmount[issuanceId] += rawAmount;

        emit VoucherFundsAdded(issuanceId, rawAmount);
    }

    function withdrawFunds(
        VoucherStorage storage self,
        string memory issuanceId,
        uint256 rawAmount,
        address sender
    )
        internal
        returns (uint256)
    {
        VoucherIssuance storage issuance = self.issuances[issuanceId];
        if (bytes(issuance.issuanceId).length == 0) revert IssuanceNotFound();
        if (issuance.owner != sender) revert OnlyIssuanceOwner();
        if (self.remainingRawAmount[issuanceId] < rawAmount) revert InsufficientRemainingFunds();

        self.remainingRawAmount[issuanceId] -= rawAmount;

        emit VoucherFundsWithdrawn(issuanceId, rawAmount);

        return rawAmount;
    }

    function terminateIssuance(
        VoucherStorage storage self,
        string memory issuanceId,
        address sender
    )
        internal
        returns (uint256)
    {
        VoucherIssuance storage issuance = self.issuances[issuanceId];
        if (bytes(issuance.issuanceId).length == 0) revert IssuanceNotFound();
        if (issuance.owner != sender) revert OnlyIssuanceOwner();
        if (!issuance.isActive) revert IssuanceAlreadyTerminated();

        issuance.isActive = false;

        uint256 remainingRawAmount = self.remainingRawAmount[issuanceId];
        self.remainingRawAmount[issuanceId] = 0;

        emit VoucherIssuanceTerminated(issuanceId);

        return remainingRawAmount;
    }

}
