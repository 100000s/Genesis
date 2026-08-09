// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract GenesisRegistry {
    address public admin;

    struct Validator {
        address validatorAddress;
        string nodeType; // e.g., "HP-Validator", "Pi-Verifier", "Phone-Issuer"
        bool isActive;
        uint256 registeredAt;
    }

    mapping(address => Validator) public validators;
    address[] public validatorList;

    event ValidatorRegistered(address indexed validator, string nodeType, uint256 timestamp);
    event ValidatorStatusUpdated(address indexed validator, bool isActive);

    modifier onlyAdmin() {
        require(msg.sender == admin, "GenesisRegistry: Only admin can perform this action");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function registerValidator(address _validator, string memory _nodeType) external onlyAdmin {
        require(validators[_validator].validatorAddress == address(0), "Validator already registered");

        validators[_validator] = Validator({
            validatorAddress: _validator,
            nodeType: _nodeType,
            isActive: true,
            registeredAt: block.timestamp
        });

        validatorList.push(_validator);
        emit ValidatorRegistered(_validator, _nodeType, block.timestamp);
    }

    function setValidatorStatus(address _validator, bool _isActive) external onlyAdmin {
        require(validators[_validator].validatorAddress != address(0), "Validator not found");
        validators[_validator].isActive = _isActive;
        emit ValidatorStatusUpdated(_validator, _isActive);
    }

    function getValidatorCount() external view returns (uint256) {
        return validatorList.length;
    }
}
