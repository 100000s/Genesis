// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface IIdentityVerifier { function verifyProof(bytes calldata proof,bytes32 credentialType,bytes32 nullifier) external view returns(bool); }
contract GenesisIdentityRegistry {
    enum Credential{Fingerprint,Citizenship,Residence,Arbitrator,Competence,Hardware,Worker,Governance}
    struct Identity{bool active;uint16 jurisdiction;bytes32 fingerprintCommitment;uint64 issuedAt;}
    struct Attestation{bool valid;bytes32 metadataHash;uint64 issuedAt;}
    address public owner; IIdentityVerifier public verifier; mapping(address=>Identity) public identities; mapping(address=>mapping(Credential=>Attestation)) public credentials; mapping(bytes32=>bool) public nullifierUsed;
    event IdentityRegistered(address indexed user,uint16 jurisdiction,bytes32 fingerprint); event CredentialIssued(address indexed user,Credential indexed kind,bytes32 metadataHash); event CredentialRevoked(address indexed user,Credential indexed kind);
    modifier onlyOwner(){require(msg.sender==owner,"Identity: owner");_;} constructor(address verifierAddress){owner=msg.sender;verifier=IIdentityVerifier(verifierAddress);}
    function registerIdentity(uint16 jurisdiction,bytes32 fingerprint,bytes32 nullifier,bytes calldata proof) external{require(!nullifierUsed[nullifier]&&!identities[msg.sender].active,"Identity: registered");require(address(verifier)==address(0)||verifier.verifyProof(proof,bytes32(uint256(Credential.Fingerprint)),nullifier),"Identity: proof");nullifierUsed[nullifier]=true;identities[msg.sender]=Identity(true,jurisdiction,fingerprint,uint64(block.timestamp));emit IdentityRegistered(msg.sender,jurisdiction,fingerprint);}
    function registerCredential(address user,Credential kind,bytes32 metadataHash,bytes32 nullifier,bytes calldata proof) external{require(msg.sender==user||msg.sender==owner,"Identity: issuer");require(!nullifierUsed[nullifier],"Identity: replay");require(address(verifier)==address(0)||verifier.verifyProof(proof,bytes32(uint256(kind)),nullifier),"Identity: proof");nullifierUsed[nullifier]=true;credentials[user][kind]=Attestation(true,metadataHash,uint64(block.timestamp));emit CredentialIssued(user,kind,metadataHash);}
    function revokeCredential(address user,Credential kind) external onlyOwner{credentials[user][kind].valid=false;emit CredentialRevoked(user,kind);} function canClaim(address user,uint8 kind) external view returns(bool){return identities[user].active&&credentials[user][kind==0?Credential.Citizenship:Credential.Residence].valid;}
    function hasCredential(address user,Credential kind) external view returns(bool){return identities[user].active&&credentials[user][kind].valid;}
}
