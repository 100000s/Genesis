// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IZkVerifier {
    function verifyProof(bytes calldata proof, bytes32 credentialType, bytes32 nullifier) external view returns (bool);
}

/// @notice GenesisIdentityRegistry: Soulbound identity and credential management
/// with zero-knowledge proof verification and nullifier replay protection.
contract GenesisIdentityRegistry {
    enum Credential {
        Fingerprint,  // 0: Biometric fingerprint enrollment
        Citizenship,  // 1: Federal passport/citizenship verification
        Residence,    // 2: State driver's license/residence verification
        Arbitrator,   // 3: Arbitration eligibility
        Competence,   // 4: Worker competence attestation
        Hardware,     // 5: Hardware attestation
        Worker,       // 6: Worker registration
        Governance    // 7: Governance participation
    }

    struct Identity {
        bool active;
        uint16 jurisdiction;               // State ID (1-50) or 0 for federal
        bytes32 fingerprintCommitment;     // Hash of enrolled fingerprint
        uint64 issuedAt;
    }

    struct Attestation {
        bool valid;
        bytes32 metadataHash;
        uint64 issuedAt;
    }

    address public owner;
    IZkVerifier public verifier;

    mapping(address => Identity) public identities;
    mapping(address => mapping(Credential => Attestation)) public credentials;
    mapping(bytes32 => bool) public nullifierUsed; // Replay protection

    event IdentityRegistered(address indexed user, uint16 jurisdiction, bytes32 fingerprint);
    event CredentialIssued(address indexed user, Credential indexed kind, bytes32 metadataHash);
    event CredentialRevoked(address indexed user, Credential indexed kind);
    event FingerprintUpdated(address indexed user, bytes32 newCommitment);

    modifier onlyOwner() {
        require(msg.sender == owner, "Identity: owner only");
        _;
    }

    constructor(address verifierAddress) {
        owner = msg.sender;
        require(verifierAddress != address(0), "Identity: zero verifier");
        verifier = IZkVerifier(verifierAddress);
    }

    /// @notice Register identity with fingerprint commitment (via ZK proof)
    function registerIdentity(
        uint16 jurisdiction,
        bytes32 fingerprint,
        bytes32 nullifier,
        bytes calldata proof
    ) external {
        require(!nullifierUsed[nullifier], "Identity: nullifier reused");
        require(!identities[msg.sender].active, "Identity: already registered");
        require(jurisdiction > 0 && jurisdiction <= 50, "Identity: invalid jurisdiction");

        // Verify ZK proof
        require(
            verifier.verifyProof(proof, keccak256("Identity"), nullifier),
            "Identity: invalid proof"
        );

        nullifierUsed[nullifier] = true;

        identities[msg.sender] = Identity({
            active: true,
            jurisdiction: jurisdiction,
            fingerprintCommitment: fingerprint,
            issuedAt: uint64(block.timestamp)
        });

        emit IdentityRegistered(msg.sender, jurisdiction, fingerprint);
    }

    /// @notice Register or update credential for a user
    function registerCredential(
        address user,
        Credential kind,
        bytes32 metadataHash,
        bytes32 nullifier,
        bytes calldata proof
    ) external {
        require(msg.sender == user || msg.sender == owner, "Identity: issuer only");
        require(identities[user].active, "Identity: user not registered");
        require(!nullifierUsed[nullifier], "Identity: nullifier reused");

        // Verify ZK proof
        require(
            verifier.verifyProof(proof, bytes32(uint256(kind)), nullifier),
            "Identity: invalid proof"
        );

        nullifierUsed[nullifier] = true;

        credentials[user][kind] = Attestation({
            valid: true,
            metadataHash: metadataHash,
            issuedAt: uint64(block.timestamp)
        });

        emit CredentialIssued(user, kind, metadataHash);
    }

    /// @notice Revoke a credential (owner only)
    function revokeCredential(address user, Credential kind) external onlyOwner {
        credentials[user][kind].valid = false;
        emit CredentialRevoked(user, kind);
    }

    /// @notice Check if user can claim (has active identity and valid credential)
    function canClaim(address user, uint8 kind) external view returns (bool) {
        if (!identities[user].active) return false;

        // Federal claims require Citizenship credential
        if (kind == 0) {
            return credentials[user][Credential.Citizenship].valid;
        }
        // State claims require Residence credential
        if (kind == 1) {
            return credentials[user][Credential.Residence].valid;
        }
        return false;
    }

    /// @notice Check if user has a specific credential
    function hasCredential(address user, Credential kind) external view returns (bool) {
        return identities[user].active && credentials[user][kind].valid;
    }

    /// @notice Get user's jurisdiction (state ID)
    function getJurisdiction(address user) external view returns (uint16) {
        return identities[user].active ? identities[user].jurisdiction : 0;
    }

    /// @notice Update fingerprint commitment (e.g., for re-enrollment)
    function updateFingerprint(
        bytes32 newFingerprint,
        bytes32 nullifier,
        bytes calldata proof
    ) external {
        require(identities[msg.sender].active, "Identity: not registered");
        require(!nullifierUsed[nullifier], "Identity: nullifier reused");

        // Verify ZK proof
        require(
            verifier.verifyProof(proof, keccak256("Fingerprint"), nullifier),
            "Identity: invalid proof"
        );

        nullifierUsed[nullifier] = true;
        identities[msg.sender].fingerprintCommitment = newFingerprint;
        emit FingerprintUpdated(msg.sender, newFingerprint);
    }
}
