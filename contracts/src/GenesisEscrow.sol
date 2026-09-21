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
 * @notice Canonical purchase escrow with proof-gated delivery and integrated arbitration.
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
        mapping(address => bool) voteForSeller;
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

    event EscrowCreated(uint256 indexed id, address indexed buyer, address indexed seller, uint256 amount);
    event EscrowFulfilled(uint256 indexed id, address indexed seller);
    event EscrowDefaulted(uint256 indexed id, address indexed buyer);
    event ArbitratorVerified(address indexed arbitrator, bytes32 indexed credentialType);
    event PurchaseEscrowCreated(uint256 indexed id, address indexed buyer, address indexed seller, uint256 itemValue, uint256 feePool);
    event SingleArbitratorProposed(uint256 indexed id, address indexed proposedBy, address arbitrator);
    event SingleArbitratorAgreed(uint256 indexed id, address indexed arbitrator);
    event EscrowShiftedToPanel(uint256 indexed id);
    event PanelArbitratorSelected(uint256 indexed id, address indexed arbitrator, string role);
    event VoteCast(uint256 indexed id, address indexed voter, bool votedForSeller);
    event EscrowSettled(uint256 indexed id, address indexed recipient, uint256 itemValue, uint256 feePaid);

    constructor(address token, address verifier) Ownable(msg.sender) {
        require(token != address(0) && verifier != address(0), "GenesisEscrow: zero address");
        GenesisToken = IERC20(token);
        zkVerifier = IZkSBTVerifier(verifier);
    }

    function setArbitratorCredentialType(bytes32 credentialType) external onlyOwner { arbitratorCredentialType = credentialType; }

    function createEscrow(address seller, uint256 amount, bytes32 credentialType, uint64 duration)
        external nonReentrant returns (uint256 id)
    {
        require(seller != address(0) && amount > 0, "GenesisEscrow: invalid escrow");
        require(GenesisToken.transferFrom(msg.sender, address(this), amount), "GenesisEscrow: transfer failed");
        id = nextEscrowId++;
        escrows[id] = EscrowAgreement(msg.sender, seller, amount, credentialType, EscrowState.AwaitingProof, uint64(block.timestamp + duration));
        emit EscrowCreated(id, msg.sender, seller, amount);
    }

    function fulfillEscrow(uint256 id, bytes calldata proof) external nonReentrant {
        EscrowAgreement storage e = escrows[id];
        require(msg.sender == e.seller, "GenesisEscrow: seller only");
        require(e.state == EscrowState.AwaitingProof && block.timestamp <= e.expiryTimestamp, "GenesisEscrow: invalid state");
        require(zkVerifier.verifyAttestationProof(e.seller, e.requiredCredentialType, proof), "GenesisEscrow: invalid proof");
        e.state = EscrowState.Completed;
        require(GenesisToken.transfer(e.seller, e.amountGenesisTokens), "GenesisEscrow: transfer failed");
        emit EscrowFulfilled(id, e.seller);
    }

    function triggerDefault(uint256 id) external nonReentrant {
        EscrowAgreement storage e = escrows[id];
        require(block.timestamp > e.expiryTimestamp && e.state == EscrowState.AwaitingProof, "GenesisEscrow: not defaultable");
        e.state = EscrowState.Defaulted;
        require(GenesisToken.transfer(e.buyer, e.amountGenesisTokens), "GenesisEscrow: refund failed");
        emit EscrowDefaulted(id, e.buyer);
    }

    function verifyAndRegisterArbitrator(bytes calldata proof) external returns (bool) {
        require(zkVerifier.verifyAttestationProof(msg.sender, arbitratorCredentialType, proof), "GenesisEscrow: invalid credential");
        isVerifiedArbitrator[msg.sender] = true;
        emit ArbitratorVerified(msg.sender, arbitratorCredentialType);
        return true;
    }

    function initiateSecurePurchase(address seller, uint256 itemValue, uint256 feePool, uint64 window)
        external nonReentrant returns (uint256 id)
    {
        require(seller != address(0) && seller != msg.sender && itemValue > 0, "GenesisEscrow: invalid purchase");
        require(GenesisToken.transferFrom(msg.sender, address(this), itemValue + feePool), "GenesisEscrow: deposit failed");
        id = nextPurchaseId++;
        ArbitrationCase storage p = arbitrationCases[id];
        p.buyer = msg.sender; p.seller = seller; p.itemValue = itemValue; p.arbitratorFeePool = feePool;
        p.creationTimestamp = uint64(block.timestamp); p.selectionWindowSeconds = window; p.stage = SelectionStage.SingleArbitrator;
        emit PurchaseEscrowCreated(id, msg.sender, seller, itemValue, feePool);
    }

    function proposeOrAgreeSingleArbitrator(uint256 id, address arbitrator) external {
        ArbitrationCase storage p = arbitrationCases[id];
        require(p.stage == SelectionStage.SingleArbitrator && block.timestamp <= p.creationTimestamp + p.selectionWindowSeconds, "GenesisEscrow: selection closed");
        require(isVerifiedArbitrator[arbitrator], "GenesisEscrow: arbitrator not verified");
        if (msg.sender == p.buyer) p.buyerAgreedSingle = true;
        else if (msg.sender == p.seller) p.sellerAgreedSingle = true;
        else revert("GenesisEscrow: party only");
        p.singleArbitrator = arbitrator;
        emit SingleArbitratorProposed(id, msg.sender, arbitrator);
        if (p.buyerAgreedSingle && p.sellerAgreedSingle) { p.stage = SelectionStage.Finalized; emit SingleArbitratorAgreed(id, arbitrator); }
    }

    function transitionToPanelStage(uint256 id) external {
        ArbitrationCase storage p = arbitrationCases[id];
        require(p.stage == SelectionStage.SingleArbitrator && block.timestamp > p.creationTimestamp + p.selectionWindowSeconds, "GenesisEscrow: window open");
        require(!p.buyerAgreedSingle || !p.sellerAgreedSingle, "GenesisEscrow: already agreed");
        p.stage = SelectionStage.PanelSelection;
        emit EscrowShiftedToPanel(id);
    }

    function selectPartyArbitrator(uint256 id, address arbitrator) external {
        ArbitrationCase storage p = arbitrationCases[id];
        require(p.stage == SelectionStage.PanelSelection && isVerifiedArbitrator[arbitrator], "GenesisEscrow: invalid panel selection");
        if (msg.sender == p.buyer) { p.buyerArbitrator = arbitrator; emit PanelArbitratorSelected(id, arbitrator, "BuyerArbitrator"); }
        else if (msg.sender == p.seller) { p.sellerArbitrator = arbitrator; emit PanelArbitratorSelected(id, arbitrator, "SellerArbitrator"); }
        else revert("GenesisEscrow: party only");
    }

    function nominateChiefArbitrator(uint256 id, address chief) external {
        ArbitrationCase storage p = arbitrationCases[id];
        require(p.stage == SelectionStage.PanelSelection && p.buyerArbitrator != address(0) && p.sellerArbitrator != address(0), "GenesisEscrow: panel incomplete");
        require(isVerifiedArbitrator[chief], "GenesisEscrow: chief not verified");
        if (msg.sender == p.buyerArbitrator) p.buyerArbAgreedChief = true;
        else if (msg.sender == p.sellerArbitrator) p.sellerArbAgreedChief = true;
        else revert("GenesisEscrow: appointed arbitrator only");
        p.chiefArbitrator = chief;
        if (p.buyerArbAgreedChief && p.sellerArbAgreedChief) { p.stage = SelectionStage.Finalized; emit PanelArbitratorSelected(id, chief, "ChiefArbitrator"); }
    }

    function castArbitrationVote(uint256 id, bool releaseToSeller) external nonReentrant {
        ArbitrationCase storage p = arbitrationCases[id];
        require(p.stage == SelectionStage.Finalized && !p.resolved && !p.hasVoted[msg.sender], "GenesisEscrow: invalid vote");
        bool single = msg.sender == p.singleArbitrator;
        bool panel = msg.sender == p.buyerArbitrator || msg.sender == p.sellerArbitrator || msg.sender == p.chiefArbitrator;
        require(single || panel, "GenesisEscrow: arbitrator only");
        p.hasVoted[msg.sender] = true; p.voteForSeller[msg.sender] = releaseToSeller;
        if (releaseToSeller) p.votesForSellerCount++; else p.votesForBuyerCount++;
        emit VoteCast(id, msg.sender, releaseToSeller);
        if (single) _finalize(id, releaseToSeller ? p.seller : p.buyer, 1);
        else if (p.votesForSellerCount >= 2) _finalize(id, p.seller, 3);
        else if (p.votesForBuyerCount >= 2) _finalize(id, p.buyer, 3);
    }

    function _finalize(uint256 id, address recipient, uint8 count) internal {
        ArbitrationCase storage p = arbitrationCases[id];
        p.resolved = true;
        require(GenesisToken.transfer(recipient, p.itemValue), "GenesisEscrow: item transfer failed");
        uint256 fee = p.arbitratorFeePool / count;
        if (count == 1) require(GenesisToken.transfer(p.singleArbitrator, p.arbitratorFeePool), "GenesisEscrow: fee transfer failed");
        else {
            if (p.hasVoted[p.buyerArbitrator]) require(GenesisToken.transfer(p.buyerArbitrator, fee), "GenesisEscrow: fee transfer failed");
            if (p.hasVoted[p.sellerArbitrator]) require(GenesisToken.transfer(p.sellerArbitrator, fee), "GenesisEscrow: fee transfer failed");
            if (p.hasVoted[p.chiefArbitrator]) require(GenesisToken.transfer(p.chiefArbitrator, fee), "GenesisEscrow: fee transfer failed");
        }
        emit EscrowSettled(id, recipient, p.itemValue, p.arbitratorFeePool);
    }
}
