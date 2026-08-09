You gave me this for GenesisSBT.sol, but I still need the GenesisAttestationManager contract: // SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;



import "@openzeppelin/contracts/access/Ownable.sol";



interface IGenesisSBT {

    function isVerified(address _account) external view returns (bool, uint16);

}



contract GenesisAttestationManager is Ownable {

    IGenesisSBT public immutable genesisSBT;



    enum AttestationType {

        ARBITRATOR_CREDENTIAL,

        WORK_EXPERIENCE,

        KNOWLEDGE_CERT,

        POLYGON_PRIVADO_ID,

        W3C_VERIFIABLE_CREDENTIAL

    }



    struct Attestation {

        AttestationType attType;

        bytes32 schemaId;      // Identifies the credential schema or skill domain

        bytes32 credentialHash;// Hash of off-chain metadata or ZK proof hash

        uint256 issueDate;

        uint256 expirationDate;

        address issuer;        // Authorized issuer or zero for self-proven ZK VCs

        bool isValid;

    }



    // Wallet address => Array of modular attestations

    mapping(address => Attestation[]) public userAttestations;

    

    // Schema or Issuer approval whitelist

    mapping(address => bool) public authorizedIssuers;



    event AttestationAdded(

        address indexed subject, 

        AttestationType indexed attType, 

        bytes32 schemaId, 

        address indexed issuer

    );

    event AttestationRevoked(address indexed subject, uint256 index);



    error MustHoldGenesisSBT();

    error UnauthorizedIssuer();

    error IndexOutOfBounds();



    modifier onlyGenesisCitizen() {

        (bool verified, ) = genesisSBT.isVerified(msg.sender);

        if (!verified) revert MustHoldGenesisSBT();

        _;

    }



    constructor(address _genesisSBT) Ownable(msg.sender) {

        genesisSBT = IGenesisSBT(_genesisSBT);

    }



    function setIssuerStatus(address issuer, bool status) external onlyOwner {

        authorizedIssuers[issuer] = status;

    }



    /**

     * @notice Add a modular attestation (Arbitration, Work, Privado ID, etc.)

     */

    function addAttestation(

        address subject,

        AttestationType attType,

        bytes32 schemaId,

        bytes32 credentialHash,

        uint256 expirationDate

    ) external {

        if (msg.sender != subject && !authorizedIssuers[msg.sender]) {

            revert UnauthorizedIssuer();

        }



        userAttestations[subject].push(Attestation({

            attType: attType,

            schemaId: schemaId,

            credentialHash: credentialHash,

            issueDate: block.timestamp,

            expirationDate: expirationDate,

            issuer: msg.sender,

            isValid: true

        }));



        emit AttestationAdded(subject, attType, schemaId, msg.sender);

    }



    /**

     * @notice Revoke or invalidate an attestation

     */

    function revokeAttestation(address subject, uint256 index) external {

        if (index >= userAttestations[subject].length) revert IndexOutOfBounds();

        Attestation storage att = userAttestations[subject][index];

        

        if (msg.sender != att.issuer && msg.sender != owner()) revert UnauthorizedIssuer();

        att.isValid = false;



        emit AttestationRevoked(subject, index);

    }



    /**

     * @notice Verify if a user holds an active attestation of a specific type

     */

    function hasValidAttestation(

        address subject, 

        AttestationType attType, 

        bytes32 schemaId

    ) external view returns (bool) {

        Attestation[] memory atts = userAttestations[subject];

        for (uint256 i = 0; i < atts.length; i++) {

            if (

                atts[i].attType == attType &&

                atts[i].schemaId == schemaId &&

                atts[i].isValid &&

                (atts[i].expirationDate == 0 || atts[i].expirationDate > block.timestamp)

            ) {

                return true;

            }

        }

        return false;

    }

}
