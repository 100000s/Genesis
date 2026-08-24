// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract GenesisValidatorRegistry {
    struct Validator { bytes32 identityCommitment; bytes32 hardwareCommitment; bytes32 geography; uint64 registeredAt; bool active; }
    address public owner;
    mapping(address => Validator) public validators;
    address[] public validatorList;
    event ValidatorRegistered(address indexed validator, bytes32 geography, bytes32 hardwareCommitment);
    event ValidatorStatusChanged(address indexed validator, bool active);
    modifier onlyOwner() { require(msg.sender == owner, "GenesisValidatorRegistry: owner only"); _; }
    constructor() { owner = msg.sender; }
    function register(bytes32 identityCommitment, bytes32 hardwareCommitment, bytes32 geography) external {
        require(!validators[msg.sender].active, "GenesisValidatorRegistry: already active");
        validators[msg.sender] = Validator(identityCommitment, hardwareCommitment, geography, uint64(block.timestamp), true);
        validatorList.push(msg.sender);
        emit ValidatorRegistered(msg.sender, geography, hardwareCommitment);
    }
    function setActive(address validator, bool active) external onlyOwner {
        require(validators[validator].registeredAt != 0, "GenesisValidatorRegistry: unknown validator");
        validators[validator].active = active;
        emit ValidatorStatusChanged(validator, active);
    }
    function count() external view returns (uint256) { return validatorList.length; }
}