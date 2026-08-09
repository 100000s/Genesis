// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IZkSBTVerifier {
    function verifyAttestationProof(
        address user,
        bytes32 credentialType,
        bytes calldata zkProof
    ) external view returns (bool);
}

contract GenesisEscrow is ReentrancyGuard {
    enum EscrowState { AwaitingProof, Active, Completed, Defaulted }

    struct EscrowAgreement {
        address buyer;
        address seller;
        uint256 amountGenTokens;
        bytes32 requiredCredentialType;
        EscrowState state;
        uint64 expiryTimestamp;
    }

    IERC20 public immutable genToken;
    IZkSBTVerifier public zkVerifier;
    uint256 public nextEscrowId;

    mapping(uint256 => EscrowAgreement) public escrows;

    event EscrowCreated(uint256 indexed id, address buyer, address seller, uint256 amount);
    event EscrowFulfilled(uint256 indexed id, address seller);
    event EscrowDefaulted(uint256 indexed id, address buyer);

    constructor(address _genToken, address _zkVerifier) {
        require(_genToken != address(0), "Invalid token address");
        genToken = IERC20(_genToken);
        zkVerifier = IZkSBTVerifier(_zkVerifier);
    }

    function createEscrow(
        address seller,
        uint256 amount,
        bytes32 requiredCredentialType,
        uint64 durationSeconds
    ) external nonReentrant returns (uint256) {
        require(amount > 0, "Escrow amount must be > 0");
        require(seller != address(0), "Invalid seller address");

        // Lock GenTokens from buyer into this escrow contract
        require(genToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        uint256 id = nextEscrowId++;
        escrows[id] = EscrowAgreement({
            buyer: msg.sender,
            seller: seller,
            amountGenTokens: amount,
            requiredCredentialType: requiredCredentialType,
            state: EscrowState.AwaitingProof,
            expiryTimestamp: uint64(block.timestamp + durationSeconds)
        });

        emit EscrowCreated(id, msg.sender, seller, amount);
        return id;
    }

    function fulfillEscrow(uint256 escrowId, bytes calldata zkProof) external nonReentrant {
        EscrowAgreement storage agreement = escrows[escrowId];
        require(msg.sender == agreement.seller, "Only seller can fulfill");
        require(agreement.state == EscrowState.AwaitingProof, "Invalid state");
        require(block.timestamp <= agreement.expiryTimestamp, "Escrow expired");

        bool isValidProof = zkVerifier.verifyAttestationProof(
            agreement.seller,
            agreement.requiredCredentialType,
            zkProof
        );
        require(isValidProof, "Invalid ZK proof");

        agreement.state = EscrowState.Completed;

        // Release GenTokens to Seller
        require(genToken.transfer(agreement.seller, agreement.amountGenTokens), "Transfer to seller failed");
        emit EscrowFulfilled(escrowId, agreement.seller);
    }

    function triggerDefault(uint256 escrowId) external nonReentrant {
        EscrowAgreement storage agreement = escrows[escrowId];
        require(block.timestamp > agreement.expiryTimestamp, "Escrow not expired");
        require(agreement.state == EscrowState.AwaitingProof, "Already settled");

        agreement.state = EscrowState.Defaulted;

        // Refund GenTokens to Buyer
        require(genToken.transfer(agreement.buyer, agreement.amountGenTokens), "Refund to buyer failed");
        emit EscrowDefaulted(escrowId, agreement.buyer);
    }
}
