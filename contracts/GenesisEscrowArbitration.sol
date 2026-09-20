// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title GenesisValidatorSet
 * @dev Manages validator registration, staking requirements, and reward routing on the Genesis chain.
 */
contract GenesisValidatorSet is Ownable {

    IERC20 public immutable genesisToken;

    uint256 public minimumStake;
    
    struct Validator {
        uint256 stakedAmount;
        bool isActive;
        bytes consensusPubKey; // Public key used by state layer consensus engine
    }

    mapping(address => Validator) public validators;
    address[] public validatorList;

    event ValidatorRegistered(address indexed validator, uint256 stakeAmount, bytes pubKey);
    event ValidatorDeregistered(address indexed validator, uint256 returnedStake);
    event StakeIncreased(address indexed validator, uint256 newTotal);
    event RewardsDistributed(uint256 totalRewardPool);

    constructor(address _genesisToken, uint256 _minimumStake) Ownable(msg.sender) {
        require(_genesisToken != address(0), "Invalid token address");
        genesisToken = IERC20(_genesisToken);
        minimumStake = _minimumStake;
    }

    /**
     * @dev Register as a validator by staking GEN tokens and submitting consensus key.
     */
    function registerValidator(bytes calldata consensusPubKey, uint256 stakeAmount) external {
        require(!validators[msg.sender].isActive, "Already a validator");
        require(stakeAmount >= minimumStake, "Stake below minimum threshold");

        // Transfer stake from validator to contract
        require(genesisToken.transferFrom(msg.sender, address(this), stakeAmount), "Stake transfer failed");

        validators[msg.sender] = Validator({
            stakedAmount: stakeAmount,
            isActive: true,
            consensusPubKey: consensusPubKey
        });

        validatorList.push(msg.sender);

        emit ValidatorRegistered(msg.sender, stakeAmount, consensusPubKey);
    }

    /**
     * @dev Unstake tokens and deregister from active consensus set.
     */
    function deregisterValidator() external {
        Validator storage val = validators[msg.sender];
        require(val.isActive, "Not an active validator");

        uint256 amountToReturn = val.stakedAmount;
        val.stakedAmount = 0;
        val.isActive = false;

        _removeFromList(msg.sender);

        require(genesisToken.transfer(msg.sender, amountToReturn), "Unstake transfer failed");

        emit ValidatorDeregistered(msg.sender, amountToReturn);
    }

    /**
     * @dev Internal helper to remove validator address from array.
     */
    function _removeFromList(address val) internal {
        uint256 length = validatorList.length;
        for (uint256 i = 0; i < length; i++) {
            if (validatorList[i] == val) {
                validatorList[i] = validatorList[length - 1];
                validatorList.pop();
                break;
            }
        }
    }

    function getActiveValidators() external view returns (address[] memory) {
        return validatorList;
    }
}
