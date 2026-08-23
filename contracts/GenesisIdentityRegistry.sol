// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IGenesisSBT {
    function isVerified(address _account) external view returns (bool, uint16);
}

interface IGenesisAttestationManager {
    enum AttestationType {
        ARBITRATOR_CREDENTIAL,
        WORK_EXPERIENCE,
        KNOWLEDGE_CERT,
        POLYGON_PRIVADO_ID,
        W3C_VERIFIABLE_CREDENTIAL,
        DRIVERS_LICENSE,
        PASSPORT
    }

    function hasValidAttestation(
        address subject,
        AttestationType attType,
        bytes32 schemaId
    ) external view returns (bool);
}

/**
 * @title GenesisIdentityRegistry
 * @dev Master Hub and Router for the Genesis Network.
 *      Enforces Driver's License for State budget and Passport for Federal budget claims.
 */
contract GenesisIdentityRegistry is Ownable {
    address public genesisSBT;
    address public attestationManager;

    // Configurable Schema IDs for state driver's licenses or federal passports
    bytes32 public driversLicenseSchemaId;
    bytes32 public passportSchemaId;

    struct ProfileStatus {
        bool isVerifiedCitizen;
        uint16 jurisdictionCode;
        bool hasValidDriversLicense;
        bool hasValidPassport;
        bool canClaimStateBudget;
        bool canClaimFederalBudget;
        bool isArbitrator;
    }

    event ModuleUpdated(string indexed moduleName, address indexed newAddress);
    event SchemaUpdated(string indexed schemaName, bytes32 indexed schemaId);

    error ZeroAddressProvided();

    constructor(
        address _genesisSBT, 
        address _attestationManager,
        bytes32 _driversLicenseSchemaId,
        bytes32 _passportSchemaId
    ) Ownable(msg.sender) {
        if (_genesisSBT == address(0) || _attestationManager == address(0)) revert ZeroAddressProvided();
        genesisSBT = _genesisSBT;
        attestationManager = _attestationManager;
        driversLicenseSchemaId = _driversLicenseSchemaId;
        passportSchemaId = _passportSchemaId;
    }

    // --- Admin Configuration ---

    function setGenesisSBT(address _genesisSBT) external onlyOwner {
        if (_genesisSBT == address(0)) revert ZeroAddressProvided();
        genesisSBT = _genesisSBT;
        emit ModuleUpdated("GenesisSBT", _genesisSBT);
    }

    function setAttestationManager(address _attestationManager) external onlyOwner {
        if (_attestationManager == address(0)) revert ZeroAddressProvided();
        attestationManager = _attestationManager;
        emit ModuleUpdated("AttestationManager", _attestationManager);
    }

    function setSchemas(bytes32 _driversLicenseSchemaId, bytes32 _passportSchemaId) external onlyOwner {
        driversLicenseSchemaId = _driversLicenseSchemaId;
        passportSchemaId = _passportSchemaId;
        emit SchemaUpdated("DriversLicense", _driversLicenseSchemaId);
        emit SchemaUpdated("Passport", _passportSchemaId);
    }

    // --- Verified Access Logic ---

    /**
     * @notice State token access requires both active Genesis SBT and a valid Driver's License attestation.
     */
    function canClaimStateBudget(address account) public view returns (bool) {
        (bool verified, ) = IGenesisSBT(genesisSBT).isVerified(account);
        if (!verified) return false;

        return IGenesisAttestationManager(attestationManager).hasValidAttestation(
            account,
            IGenesisAttestationManager.AttestationType.DRIVERS_LICENSE,
            driversLicenseSchemaId
        );
    }

    /**
     * @notice Federal token access requires both active Genesis SBT and a valid Passport attestation.
     */
    function canClaimFederalBudget(address account) public view returns (bool) {
        (bool verified, ) = IGenesisSBT(genesisSBT).isVerified(account);
        if (!verified) return false;

        return IGenesisAttestationManager(attestationManager).hasValidAttestation(
            account,
            IGenesisAttestationManager.AttestationType.PASSPORT,
            passportSchemaId
        );
    }

    // --- Master Query Interface ---

    /**
     * @notice Comprehensive account profile query for dApps, ATMs, and the Genesis App.
     */
    function getFullProfile(
        address account,
        bytes32 arbitratorSchemaId
    ) external view returns (ProfileStatus memory profile) {
        (bool verified, uint16 jCode) = IGenesisSBT(genesisSBT).isVerified(account);

        bool hasDL = IGenesisAttestationManager(attestationManager).hasValidAttestation(
            account,
            IGenesisAttestationManager.AttestationType.DRIVERS_LICENSE,
            driversLicenseSchemaId
        );

        bool hasPass = IGenesisAttestationManager(attestationManager).hasValidAttestation(
            account,
            IGenesisAttestationManager.AttestationType.PASSPORT,
            passportSchemaId
        );

        bool arbitrator = IGenesisAttestationManager(attestationManager).hasValidAttestation(
            account,
            IGenesisAttestationManager.AttestationType.ARBITRATOR_CREDENTIAL,
            arbitratorSchemaId
        );

        return ProfileStatus({
            isVerifiedCitizen: verified,
            jurisdictionCode: jCode,
            hasValidDriversLicense: hasDL,
            hasValidPassport: hasPass,
            canClaimStateBudget: verified && hasDL,
            canClaimFederalBudget: verified && hasPass,
            isArbitrator: arbitrator
        });
    }
}
