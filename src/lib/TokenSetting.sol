// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ExchangeAllowMethod } from "./Enum.sol";

contract TokenSetting is OwnableUpgradeable {
    uint256 public decreaseIntervalDays;
    uint256 public lastDecreaseTime;
    uint16 public afterDecreaseBp;
    // Bp is 1/10000
    uint16 public maxIncreaseOfTotalSupplyBp;
    uint16 public maxIncreaseBp;
    uint16 public maxUsageBp;
    uint16 public changeBp;
    // totalSupply at UTC 0 today
    uint256 public midnightTotalSupply;
    uint256 public midnightTotalSupplyModifiedTime;
    uint256 public mintArigatoCreationToday;
    uint256 public mintArigatoCreationTodayForGuest;

    ExchangeAllowMethod public incomeExchangeAllowMethod;
    ExchangeAllowMethod public outgoExchangeAllowMethod;

    address[] public incomeTargetTokens;
    address[] public outgoTargetTokens;

    function getTokenSettings()
        public
        view
        returns (
            uint256 _decreaseIntervalDays,
            uint16 _afterDecreaseBp,
            uint16 _maxIncreaseOfTotalSupplyBp,
            uint16 _maxIncreaseBp,
            uint16 _maxUsageBp,
            uint16 _changeBp,
            ExchangeAllowMethod _incomeExchangeAllowMethod,
            ExchangeAllowMethod _outgoExchangeAllowMethod,
            address[] memory _incomeTargetTokens,
            address[] memory _outgoTargetTokens
        )
    {
        _decreaseIntervalDays = decreaseIntervalDays;
        _afterDecreaseBp = afterDecreaseBp;
        _maxIncreaseOfTotalSupplyBp = maxIncreaseOfTotalSupplyBp;
        _maxIncreaseBp = maxIncreaseBp;
        _maxUsageBp = maxUsageBp;
        _changeBp = changeBp;
        _incomeExchangeAllowMethod = incomeExchangeAllowMethod;
        _outgoExchangeAllowMethod = outgoExchangeAllowMethod;
        _incomeTargetTokens = incomeTargetTokens;
        _outgoTargetTokens = outgoTargetTokens;
    }

    function setTokenSettings(
        uint256 _decreaseIntervalDays,
        uint16 _afterDecreaseBp,
        uint16 _maxIncreaseOfTotalSupplyBp,
        uint16 _maxIncreaseBp,
        uint16 _maxUsageBp,
        uint16 _changeBp,
        ExchangeAllowMethod _incomeExchangeAllowMethod,
        ExchangeAllowMethod _outgoExchangeAllowMethod,
        address[] calldata _incomeTargetTokens,
        address[] calldata _outgoTargetTokens
    )
        public
        onlyOwner
    {
        decreaseIntervalDays = _decreaseIntervalDays;
        afterDecreaseBp = _afterDecreaseBp;
        maxIncreaseOfTotalSupplyBp = _maxIncreaseOfTotalSupplyBp;
        maxIncreaseBp = _maxIncreaseBp;
        maxUsageBp = _maxUsageBp;
        changeBp = _changeBp;
        incomeExchangeAllowMethod = _incomeExchangeAllowMethod;
        outgoExchangeAllowMethod = _outgoExchangeAllowMethod;
        incomeTargetTokens = _incomeTargetTokens;
        outgoTargetTokens = _outgoTargetTokens;
    }

    function getIncomeTargetTokens() public view returns (address[] memory) {
        return incomeTargetTokens;
    }

    function getOutgoTargetTokens() public view returns (address[] memory) {
        return outgoTargetTokens;
    }
}
