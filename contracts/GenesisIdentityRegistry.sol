// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IGenesisSBT {
    function isVerified(address _account) external view returns (bool verified, uint16 stateFips);
}

interface IGenesisAttestationManager {
    enum AttestationType {
        ARBITRATOR_CREDENTIAL,
        WORK_EXPERIENCE,
        KNOWLEDGE_CERT,
        POLYGON_PRIVADO_ID,
        W3C_VERIFIABLE_CREDENTIAL
    }

    function hasValidAttestation(
        address subject, 
        AttestationType attType, 
        bytes32 schemaId
    ) external view returns (bool);
}

/**
 * @title GenesisIdentityRegistry
 * @notice Central router connecting Genesis Identity (SBT) and Modular Credentials.
 */
contract GenesisIdentityRegistry is Ownable {
    IGenesisSBT public genesisSBT;
    IGenesisAttestationManager public attestationManager;

    event ModulePointersUpdated(address indexed sbt, address indexed attestationManager);

    constructor(address _genesisSBT, address _attestationManager) Ownable(msg.sender) {
        genesisSBT = IGenesisSBT(_genesisSBT);
        attestationManager = IGenesisAttestationManager(_attestationManager);
    }

    /**
     * @notice Admin function to update pointers if a module contract is upgraded.
     */
    function setModulePointers(address _genesisSBT, address _attestationManager) external onlyOwner {
        genesisSBT = IGenesisSBT(_genesisSBT);
        attestationManager = IGenesisAttestationManager(_attestationManager);
        emit ModulePointersUpdated(_genesisSBT, _attestationManager);
    }

    /**
     * @notice Composite check: Verifies citizen status, residence state, and specific credential in one call.
     */
    function verifyFullProfile(
        address account,
        IGenesisAttestationManager.AttestationType attType,
        bytes32 schemaId
    ) external view returns (bool isCitizen, uint16 stateFips, bool hasCredential) {
        (isCitizen, stateFips) = genesisSBT.isVerified(account);
        if (!isCitizen) {
            return (false, 0, false);
        }
        
        hasCredential = attestationManager.hasValidAttestation(account, attType, schemaId);
        return (isCitizen, stateFips, hasCredential);
    }
}
