// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/** @notice Canonical validator registry with optional legacy stake/key support. */
contract GenesisValidatorRegistry is Ownable {
    struct Validator {
        bytes32 identityCommitment;
        bytes32 hardwareCommitment;
        bytes32 geography;
        uint64 registeredAt;
        bool active;
        uint256 stakedAmount;
        bytes consensusPubKey;
    }

    IERC20 public stakeToken;
    uint256 public minimumStake;
    mapping(address => Validator) public validators;
    address[] public validatorList;

    event ValidatorRegistered(address indexed validator, bytes32 geography, bytes32 hardwareCommitment);
    event StakedValidatorRegistered(address indexed validator, uint256 stakeAmount, bytes pubKey);
    event ValidatorStatusChanged(address indexed validator, bool active);
    event ValidatorDeregistered(address indexed validator, uint256 returnedStake);

    constructor() Ownable(msg.sender) {}

    function setStakeConfig(address token, uint256 minimum) external onlyOwner {
        require(token != address(0), "Invalid stake token");
        stakeToken = IERC20(token);
        minimumStake = minimum;
    }

    function register(bytes32 identityCommitment, bytes32 hardwareCommitment, bytes32 geography) external {
        require(!validators[msg.sender].active, "Validator already active");
        validators[msg.sender] = Validator(identityCommitment, hardwareCommitment, geography, uint64(block.timestamp), true, 0, "");
        validatorList.push(msg.sender);
        emit ValidatorRegistered(msg.sender, geography, hardwareCommitment);
    }

    function registerValidator(bytes calldata consensusPubKey, uint256 stakeAmount) external {
        require(address(stakeToken) != address(0), "Stake token not configured");
        require(!validators[msg.sender].active, "Validator already active");
        require(stakeAmount >= minimumStake, "Stake below minimum threshold");
        require(stakeToken.transferFrom(msg.sender, address(this), stakeAmount), "Stake transfer failed");
        validators[msg.sender] = Validator(bytes32(0), bytes32(0), bytes32(0), uint64(block.timestamp), true, stakeAmount, consensusPubKey);
        validatorList.push(msg.sender);
        emit StakedValidatorRegistered(msg.sender, stakeAmount, consensusPubKey);
    }

    function deregisterValidator() external {
        Validator storage validator = validators[msg.sender];
        require(validator.active, "Not an active validator");
        uint256 amount = validator.stakedAmount;
        validator.stakedAmount = 0;
        validator.active = false;
        _removeFromList(msg.sender);
        if (amount > 0) require(stakeToken.transfer(msg.sender, amount), "Unstake transfer failed");
        emit ValidatorDeregistered(msg.sender, amount);
    }

    function setActive(address validator, bool active) external onlyOwner {
        require(validators[validator].registeredAt != 0, "Unknown validator");
        validators[validator].active = active;
        emit ValidatorStatusChanged(validator, active);
    }

    function getActiveValidators() external view returns (address[] memory) { return validatorList; }
    function count() external view returns (uint256) { return validatorList.length; }

    function _removeFromList(address validator) internal {
        for (uint256 i = 0; i < validatorList.length; i++) {
            if (validatorList[i] == validator) {
                validatorList[i] = validatorList[validatorList.length - 1];
                validatorList.pop();
                return;
            }
        }
    }
}
