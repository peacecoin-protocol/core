// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

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
        internal
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
        require(
            issuance.countLimitPerUser == 0 || self.claimCountPerUser[issuanceId][claimer] < issuance.countLimitPerUser,
            "Claim count reached limitation"
        );
        require(
            self.remainingRawAmount[issuanceId] >= claimRawAmount,
            "No more claimable amount"
        );
        if (issuance.totalAmountLimit > 0) {
            require(
                self.claimedDisplayAmount[issuanceId] + issuance.amountPerClaim <= issuance.totalAmountLimit,
                "Total amount limit exceeded"
            );
        }
        require(
            MerkleProof.verify(proof, issuance.merkleRoot, keccak256(abi.encodePacked(code))),
            "Invalid claim proof"
        );
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
        internal
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
        internal
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
        internal
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
}
