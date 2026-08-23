// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../WorkerSplit.sol";

contract MockGenesisIssuance is IGenesisIssuance {
    mapping(address => uint256) public workerBalances;
    uint256 public totalWorkerTokensMinted;

    function mintWorkerReward(address recipient, uint256 amount) external override {
        workerBalances[recipient] += amount;
        totalWorkerTokensMinted += amount;
    }
}
