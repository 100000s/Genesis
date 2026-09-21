// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IZkSBTVerifier {
    function verifyAttestationProof(address user, bytes32 credentialType, bytes calldata zkProof) external view returns (bool);
}

/**
 * @title GenesisEscrow
 * @notice Canonical escrow with integrated single-arbitrator and 2-of-3 panel arbitration.
 */
contract GenesisEscrow is ReentrancyGuard, Ownable {
    enum EscrowState { AwaitingProof, Active, Completed, Defaulted }
    enum SelectionStage { SingleArbitrator, PanelSelection, Finalized }

    struct EscrowAgreement {
        address buyer;
        address seller;
        uint256 amountGenesisTokens;
        bytes32 requiredCredentialType;
        EscrowState state;
        uint64 expiryTimestamp;
    }

    struct ArbitrationCase {
        address buyer;
        address seller;
        uint256 itemValue;
        uint256 arbitratorFeePool;
        uint64 creationTimestamp;
        uint64 selectionWindowSeconds;
        SelectionStage stage;
        address singleArbitrator;
        bool buyerAgreedSingle;
        bool sellerAgreedSingle;
        address buyerArbitrator;
        address sellerArbitrator;
        address chiefArbitrator;
        bool buyerArbAgreedChief;
        bool sellerArbAgreedChief;
        mapping(address => bool) hasVoted;
        uint8 votesForSellerCount;
        uint8 votesForBuyerCount;
        bool resolved;
    }

    IERC20 public immutable GenesisToken;
    IZkSBTVerifier public zkVerifier;
    bytes32 public arbitratorCredentialType;
    uint256 public nextEscrowId;
    uint256 public nextPurchaseId;

    mapping(uint256 => EscrowAgreement) public escrows;
    mapping(uint256 => ArbitrationCase) public arbitrationCases;
    mapping(address => bool) public isVerifiedArbitrator;

    event EscrowCreated(uint256 indexed id, address buyer, address seller, uint256 amount);
    event EscrowFulfilled(uint256 indexed id, address seller);
    event EscrowDefaulted(uint256 indexed id, address buyer);
    event ArbitratorVerified(address indexed arbitrator, bytes32 indexed credentialType);
    event PurchaseEscrowCreated(uint256 indexed id, address indexed buyer, address indexed seller, uint256 itemValue, uint256 feePool);
    event SingleArbitratorProposed(uint256 indexed id, address indexed proposedBy, address arbitrator);
    event SingleArbitratorAgreed(uint256 indexed id, address indexed arbitrator);
    event EscrowShiftedToPanel(uint256 indexed id);
    event PanelArbitratorSelected(uint256 indexed id, address indexed arbitrator, string role);
    event VoteCast(uint256 indexed id, address indexed voter, bool votedForSeller);
    event EscrowSettled(uint256 indexed id, address indexed recipient, uint256 itemValue, uint256 feePaid);

    constructor(address _GenesisToken, address _zkVerifier) Ownable(msg.sender) {
        require(_GenesisToken != address(0), "Invalid token address");
        require(_zkVerifier != address(0), "Invalid ZK verifier address");

    constructor(address _GenesisToken, address _zkVerifier) {
        require(_GenesisToken != address(0), "Invalid token address");
        GenesisToken = IERC20(_GenesisToken);
        zkVerifier = IZkSBTVerifier(_zkVerifier);
    }

    function setArbitratorCredentialType(bytes32 credentialType) external onlyOwner { arbitratorCredentialType = credentialType; }

    function createEscrow(address seller, uint256 amount, bytes32 requiredCredentialType, uint64 durationSeconds)
        external nonReentrant returns (uint256)
    {
        require(amount > 0, "Escrow amount must be > 0");
        require(seller != address(0), "Invalid seller address");
        require(GenesisToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        uint256 id = nextEscrowId++;
        escrows[id] = EscrowAgreement(msg.sender, seller, amount, requiredCredentialType, EscrowState.AwaitingProof, uint64(block.timestamp + durationSeconds));

        // Lock GenesisTokens from buyer into this escrow contract
        require(GenesisToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        uint256 id = nextEscrowId++;
        escrows[id] = EscrowAgreement({
            buyer: msg.sender,
            seller: seller,
            amountGenesisTokens: amount,
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
        require(zkVerifier.verifyAttestationProof(agreement.seller, agreement.requiredCredentialType, zkProof), "Invalid ZK proof");
        agreement.state = EscrowState.Completed;

        // Release GenesisTokens to Seller
        require(GenesisToken.transfer(agreement.seller, agreement.amountGenesisTokens), "Transfer to seller failed");
        emit EscrowFulfilled(escrowId, agreement.seller);
    }

    function triggerDefault(uint256 escrowId) external nonReentrant {
        EscrowAgreement storage agreement = escrows[escrowId];
        require(block.timestamp > agreement.expiryTimestamp, "Escrow not expired");
        require(agreement.state == EscrowState.AwaitingProof, "Already settled");
        agreement.state = EscrowState.Defaulted;

        // Refund GenesisTokens to Buyer
        require(GenesisToken.transfer(agreement.buyer, agreement.amountGenesisTokens), "Refund to buyer failed");
        emit EscrowDefaulted(escrowId, agreement.buyer);
    }

    function verifyAndRegisterArbitrator(bytes calldata zkProof) external returns (bool) {
        require(zkVerifier.verifyAttestationProof(msg.sender, arbitratorCredentialType, zkProof), "Invalid ZK credential proof");
        isVerifiedArbitrator[msg.sender] = true;
        emit ArbitratorVerified(msg.sender, arbitratorCredentialType);
        return true;
    }

    function initiateSecurePurchase(address seller, uint256 itemValue, uint256 arbitratorFeePool, uint64 selectionWindowSeconds)
        external nonReentrant returns (uint256 purchaseId)
    {
        require(seller != address(0) && seller != msg.sender, "Invalid seller address");
        require(itemValue > 0, "Item value must be > 0");
        purchaseId = nextPurchaseId++;
        require(GenesisToken.transferFrom(msg.sender, address(this), itemValue + arbitratorFeePool), "Deposit transfer failed");
        ArbitrationCase storage p = arbitrationCases[purchaseId];
        p.buyer = msg.sender; p.seller = seller; p.itemValue = itemValue; p.arbitratorFeePool = arbitratorFeePool;
        p.creationTimestamp = uint64(block.timestamp); p.selectionWindowSeconds = selectionWindowSeconds; p.stage = SelectionStage.SingleArbitrator;
        emit PurchaseEscrowCreated(purchaseId, msg.sender, seller, itemValue, arbitratorFeePool);
    }

    function proposeOrAgreeSingleArbitrator(uint256 id, address arbitrator) external {
        ArbitrationCase storage p = arbitrationCases[id];
        require(p.stage == SelectionStage.SingleArbitrator, "Not in single selection stage");
        require(block.timestamp <= p.creationTimestamp + p.selectionWindowSeconds, "Selection window expired");
        require(isVerifiedArbitrator[arbitrator], "Arbitrator not verified");
        if (msg.sender == p.buyer) { p.singleArbitrator = arbitrator; p.buyerAgreedSingle = true; }
        else if (msg.sender == p.seller) { p.singleArbitrator = arbitrator; p.sellerAgreedSingle = true; }
        else revert("Unauthorized caller");
        emit SingleArbitratorProposed(id, msg.sender, arbitrator);
        if (p.buyerAgreedSingle && p.sellerAgreedSingle) { p.stage = SelectionStage.Finalized; emit SingleArbitratorAgreed(id, p.singleArbitrator); }
    }

    function transitionToPanelStage(uint256 id) external {
        ArbitrationCase storage p = arbitrationCases[id];
        require(p.stage == SelectionStage.SingleArbitrator, "Already transitioned");
        require(block.timestamp > p.creationTimestamp + p.selectionWindowSeconds, "Window still open");
        require(!p.buyerAgreedSingle || !p.sellerAgreedSingle, "Single arbitrator already agreed");
        p.stage = SelectionStage.PanelSelection;
        emit EscrowShiftedToPanel(id);
    }

    function selectPartyArbitrator(uint256 id, address arbitrator) external {
        ArbitrationCase storage p = arbitrationCases[id];
        require(p.stage == SelectionStage.PanelSelection, "Not in panel stage");
        require(isVerifiedArbitrator[arbitrator], "Arbitrator not verified");
        if (msg.sender == p.buyer) { p.buyerArbitrator = arbitrator; emit PanelArbitratorSelected(id, arbitrator, "BuyerArbitrator"); }
        else if (msg.sender == p.seller) { p.sellerArbitrator = arbitrator; emit PanelArbitratorSelected(id, arbitrator, "SellerArbitrator"); }
        else revert("Unauthorized party");
    }

    function nominateChiefArbitrator(uint256 id, address chief) external {
        ArbitrationCase storage p = arbitrationCases[id];
        require(p.stage == SelectionStage.PanelSelection, "Not in panel stage");
        require(p.buyerArbitrator != address(0) && p.sellerArbitrator != address(0), "Party arbitrators incomplete");
        require(isVerifiedArbitrator[chief], "Chief arbitrator not verified");
        if (msg.sender == p.buyerArbitrator) { p.chiefArbitrator = chief; p.buyerArbAgreedChief = true; }
        else if (msg.sender == p.sellerArbitrator) { p.chiefArbitrator = chief; p.sellerArbAgreedChief = true; }
        else revert("Only appointed arbitrators can nominate chief");
        if (p.buyerArbAgreedChief && p.sellerArbAgreedChief) { p.stage = SelectionStage.Finalized; emit PanelArbitratorSelected(id, chief, "ChiefArbitrator"); }
    }

    function castArbitrationVote(uint256 id, bool releaseToSeller) external nonReentrant {
        ArbitrationCase storage p = arbitrationCases[id];
        require(p.stage == SelectionStage.Finalized, "Arbitration panel not fully formed");
        require(!p.resolved && !p.hasVoted[msg.sender], "Invalid arbitration vote");
        bool isSingle = p.singleArbitrator != address(0) && msg.sender == p.singleArbitrator;
        bool isPanel = msg.sender == p.buyerArbitrator || msg.sender == p.sellerArbitrator || msg.sender == p.chiefArbitrator;
        require(isSingle || isPanel, "Unauthorized arbitrator");
        p.hasVoted[msg.sender] = true;
        if (releaseToSeller) p.votesForSellerCount++; else p.votesForBuyerCount++;
        emit VoteCast(id, msg.sender, releaseToSeller);
        if (isSingle) _finalize(id, releaseToSeller ? p.seller : p.buyer, 1);
        else if (p.votesForSellerCount >= 2) _finalize(id, p.seller, 3);
        else if (p.votesForBuyerCount >= 2) _finalize(id, p.buyer, 3);
    }

    function _finalize(uint256 id, address recipient, uint8 activeArbitratorCount) internal {
        ArbitrationCase storage p = arbitrationCases[id];
        p.resolved = true;
        uint256 feePerArb = activeArbitratorCount == 0 ? 0 : p.arbitratorFeePool / activeArbitratorCount;
        require(GenesisToken.transfer(recipient, p.itemValue), "Item transfer failed");
        if (activeArbitratorCount == 1) require(GenesisToken.transfer(p.singleArbitrator, p.arbitratorFeePool), "Arbitrator fee transfer failed");
        else {
            if (p.hasVoted[p.buyerArbitrator]) require(GenesisToken.transfer(p.buyerArbitrator, feePerArb), "Buyer arbitrator fee failed");
            if (p.hasVoted[p.sellerArbitrator]) require(GenesisToken.transfer(p.sellerArbitrator, feePerArb), "Seller arbitrator fee failed");
            if (p.hasVoted[p.chiefArbitrator]) require(GenesisToken.transfer(p.chiefArbitrator, feePerArb), "Chief arbitrator fee failed");
        }
        emit EscrowSettled(id, recipient, p.itemValue, p.arbitratorFeePool);
    }
}
