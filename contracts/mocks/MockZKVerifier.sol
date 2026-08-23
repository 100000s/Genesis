// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../WorkerSplit.sol";

contract MockZKVerifier is IZKVerifier {
    bool public shouldPass = true;

    function setShouldPass(bool _shouldPass) external {
        shouldPass = _shouldPass;
    }

    function verifyProof(bytes calldata, uint256[] calldata) external view override returns (bool) {
        return shouldPass;
    }
}
