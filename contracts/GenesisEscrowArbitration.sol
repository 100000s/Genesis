// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IZkSBTVerifier {
    function verifyAttestationProof(
        address user,
        bytes32 credentialType,
        bytes calldata zkProof
    ) external view returns (bool);
}

/**
 * @title GenesisEscrowArbitration
 * @dev Multi-stage escrow arbitration with dynamic selection windows and GenToken arbitrator compensation.
 */
contract GenesisEscrowArbitration is ReentrancyGuard, Ownable {

    IERC20 public immutable genToken;
    IZkSBTVerifier public immutable zkVerifier;
    bytes32 public immutable arbitratorCredentialType;

    enum SelectionStage { SingleArbitrator, PanelSelection, Finalized }

    struct EscrowPurchase {
        address buyer;
        address seller;
        uint256 itemValue;
        uint256 arbitratorFeePool; // GenTokens reserved for compensating arbitrators
        uint64 creationTimestamp;
        uint64 selectionWindowSeconds; // Timeframe to agree on single arbitrator
        
        SelectionStage stage;
        
        // Single Arbitrator Mode
        address singleArbitrator;
        bool buyerAgreedSingle;
        bool sellerAgreedSingle;

        // Panel Mode (3 Arbitrators)
        address buyerArbitrator;
        address sellerArbitrator;
        address chiefArbitrator;
        bool buyerArbAgreedChief;
        bool sellerArbAgreedChief;

        // Panel Voting (2-of-3)
        mapping(address => bool) hasVoted;
        mapping(address => bool) voteForSeller;
        uint8 votesForSellerCount;
        uint8 votesForBuyerCount;
        
        bool resolved;
    }

    mapping(uint256 => EscrowPurchase) public escrowRegistry;
    mapping(address => bool) public isVerifiedArbitrator;
    uint256 public nextPurchaseId;

    event ArbitratorVerified(address indexed arbitrator, bytes32 indexed credentialType);
    event PurchaseEscrowCreated(uint256 indexed id, address indexed buyer, address indexed seller, uint256 itemValue, uint256 feePool);
    event SingleArbitratorProposed(uint256 indexed id, address indexed proposedBy, address arbitrator);
    event SingleArbitratorAgreed(uint256 indexed id, address indexed arbitrator);
    event EscrowShiftedToPanel(uint256 indexed id);
    event PanelArbitratorSelected(uint256 indexed id, address indexed arbitrator, string role);
    event VoteCast(uint256 indexed id, address indexed voter, bool votedForSeller);
    event EscrowSettled(uint256 indexed id, address indexed recipient, uint256 itemValue, uint256 feePaid);

    constructor(
        address _genToken, 
        address _zkVerifier, 
        bytes32 _arbitratorCredentialType
    ) Ownable(msg.sender) {
        require(_genToken != address(0), "Invalid token address");
        require(_zkVerifier != address(0), "Invalid ZK Verifier address");
        genToken = IERC20(_genToken);
        zkVerifier = IZkSBTVerifier(_zkVerifier);
        arbitratorCredentialType = _arbitratorCredentialType;
    }

    /**
     * @notice Register as a ZK-verified arbitrator.
     */
    function verifyAndRegisterArbitrator(bytes calldata zkProof) external returns (bool) {
        bool isValid = zkVerifier.verifyAttestationProof(msg.sender, arbitratorCredentialType, zkProof);
        require(isValid, "Invalid ZK credential proof");

        isVerifiedArbitrator[msg.sender] = true;
        emit ArbitratorVerified(msg.sender, arbitratorCredentialType);
        return true;
    }

    /**
     * @notice Initiate escrow with an item value and an explicit arbitrator compensation pool in GenTokens.
     */
    function initiateSecurePurchase(
        address _to, 
        uint256 _itemValue,
        uint256 _arbitratorFeePool,
        uint64 _selectionWindowSeconds
    ) external nonReentrant returns (uint256 purchaseId) {
        require(_to != address(0) && _to != msg.sender, "Invalid seller address");
        require(_itemValue > 0, "Item value must be > 0");

        purchaseId = nextPurchaseId++;

        uint256 totalDeposit = _itemValue + _arbitratorFeePool;
        require(genToken.transferFrom(msg.sender, address(this), totalDeposit), "Deposit transfer failed");

        EscrowPurchase storage p = escrowRegistry[purchaseId];
        p.buyer = msg.sender;
        p.seller = _to;
        p.itemValue = _itemValue;
        p.arbitratorFeePool = _arbitratorFeePool;
        p.creationTimestamp = uint64(block.timestamp);
        p.selectionWindowSeconds = _selectionWindowSeconds;
        p.stage = SelectionStage.SingleArbitrator;

        emit PurchaseEscrowCreated(purchaseId, msg.sender, _to, _itemValue, _arbitratorFeePool);
    }

    // =========================================================================
    // STAGE 1: SINGLE ARBITRATOR MUTUAL SELECTION
    // =========================================================================

    /**
     * @notice Buyer or Seller proposes/accepts a single arbitrator during the window.
     */
    function proposeOrAgreeSingleArbitrator(uint256 _purchaseId, address _arbitrator) external {
        EscrowPurchase storage p = escrowRegistry[_purchaseId];
        require(p.stage == SelectionStage.SingleArbitrator, "Not in single selection stage");
        require(block.timestamp <= p.creationTimestamp + p.selectionWindowSeconds, "Selection window expired");
        require(isVerifiedArbitrator[_arbitrator], "Arbitrator not ZK verified");

        if (msg.sender == p.buyer) {
            p.singleArbitrator = _arbitrator;
            p.buyerAgreedSingle = true;
            emit SingleArbitratorProposed(_purchaseId, msg.sender, _arbitrator);
        } else if (msg.sender == p.seller) {
            p.singleArbitrator = _arbitrator;
            p.sellerAgreedSingle = true;
            emit SingleArbitratorProposed(_purchaseId, msg.sender, _arbitrator);
        } else {
            revert("Unauthorized caller");
        }

        // If both agree on the same arbitrator, finalize selection
        if (p.buyerAgreedSingle && p.sellerAgreedSingle) {
            p.stage = SelectionStage.Finalized;
            emit SingleArbitratorAgreed(_purchaseId, p.singleArbitrator);
        }
    }

    /**
     * @notice Shift escrow to Panel Selection if window expired without mutual agreement.
     */
    function transitionToPanelStage(uint256 _purchaseId) external {
        EscrowPurchase storage p = escrowRegistry[_purchaseId];
        require(p.stage == SelectionStage.SingleArbitrator, "Already transitioned");
        require(block.timestamp > p.creationTimestamp + p.selectionWindowSeconds, "Window still open");
        require(!p.buyerAgreedSingle || !p.sellerAgreedSingle, "Single arbitrator already agreed");

        p.stage = SelectionStage.PanelSelection;
        emit EscrowShiftedToPanel(_purchaseId);
    }

    // =========================================================================
    // STAGE 2: THREE-ARBITRATOR PANEL SELECTION
    // =========================================================================

    /**
     * @notice Parties select their individual panel arbitrators.
     */
    function selectPartyArbitrator(uint256 _purchaseId, address _arbitrator) external {
        EscrowPurchase storage p = escrowRegistry[_purchaseId];
        require(p.stage == SelectionStage.PanelSelection, "Not in panel stage");
        require(isVerifiedArbitrator[_arbitrator], "Arbitrator not ZK verified");

        if (msg.sender == p.buyer) {
            p.buyerArbitrator = _arbitrator;
            emit PanelArbitratorSelected(_purchaseId, _arbitrator, "BuyerArbitrator");
        } else if (msg.sender == p.seller) {
            p.sellerArbitrator = _arbitrator;
            emit PanelArbitratorSelected(_purchaseId, _arbitrator, "SellerArbitrator");
        } else {
            revert("Unauthorized party");
        }
    }

    /**
     * @notice Buyer's and Seller's arbitrators nominate and agree on the 3rd Chief Arbitrator.
     */
    function nominateChiefArbitrator(uint256 _purchaseId, address _chiefArbitrator) external {
        EscrowPurchase storage p = escrowRegistry[_purchaseId];
        require(p.stage == SelectionStage.PanelSelection, "Not in panel stage");
        require(p.buyerArbitrator != address(0) && p.sellerArbitrator != address(0), "Party arbitrators incomplete");
        require(isVerifiedArbitrator[_chiefArbitrator], "Chief arbitrator not ZK verified");

        if (msg.sender == p.buyerArbitrator) {
            p.chiefArbitrator = _chiefArbitrator;
            p.buyerArbAgreedChief = true;
        } else if (msg.sender == p.sellerArbitrator) {
            p.chiefArbitrator = _chiefArbitrator;
            p.sellerArbAgreedChief = true;
        } else {
            revert("Only appointed arbitrators can nominate chief");
        }

        if (p.buyerArbAgreedChief && p.sellerArbAgreedChief) {
            p.stage = SelectionStage.Finalized;
            emit PanelArbitratorSelected(_purchaseId, p.chiefArbitrator, "ChiefArbitrator");
        }
    }

    // =========================================================================
    // RESOLUTION & COMPENSATED VOTING
    // =========================================================================

    /**
     * @notice Cast vote to resolve dispute and receive GenToken compensation upon finality.
     */
    function castArbitrationVote(uint256 _purchaseId, bool _releaseToSeller) external nonReentrant {
        EscrowPurchase storage p = escrowRegistry[_purchaseId];
        require(p.stage == SelectionStage.Finalized, "Arbitration panel not fully formed");
        require(!p.resolved, "Escrow already resolved");
        require(!p.hasVoted[msg.sender], "Already voted");

        bool isSingle = (p.singleArbitrator != address(0) && msg.sender == p.singleArbitrator);
        bool isPanelMember = (msg.sender == p.buyerArbitrator || msg.sender == p.sellerArbitrator || msg.sender == p.chiefArbitrator);

        require(isSingle || isPanelMember, "Unauthorized arbitrator");

        p.hasVoted[msg.sender] = true;
        p.voteForSeller[msg.sender] = _releaseToSeller;

        if (_releaseToSeller) {
            p.votesForSellerCount++;
        } else {
            p.votesForBuyerCount++;
        }

        emit VoteCast(_purchaseId, msg.sender, _releaseToSeller);

        // Check Resolution Conditions
        if (isSingle) {
            _finalize(_purchaseId, _releaseToSeller ? p.seller : p.buyer, 1);
        } else if (p.votesForSellerCount >= 2) {
            _finalize(_purchaseId, p.seller, 3);
        } else if (p.votesForBuyerCount >= 2) {
            _finalize(_purchaseId, p.buyer, 3);
        }
    }

    /**
     * @dev Settles escrow and pays out GenToken fee pool to active arbitrators.
     */
    function _finalize(uint256 _purchaseId, address _recipient, uint8 _activeArbitratorCount) internal {
        EscrowPurchase storage p = escrowRegistry[_purchaseId];
        p.resolved = true;

        uint256 itemVal = p.itemValue;
        uint256 totalFee = p.arbitratorFeePool;
        uint256 feePerArb = _activeArbitratorCount > 0 ? totalFee / _activeArbitratorCount : 0;

        // Pay item recipient
        require(genToken.transfer(_recipient, itemVal), "Item transfer failed");

        // Pay Arbitrator Rewards
        if (_activeArbitratorCount == 1) {
            require(genToken.transfer(p.singleArbitrator, totalFee), "Arbitrator fee transfer failed");
        } else {
            if (p.hasVoted[p.buyerArbitrator]) genToken.transfer(p.buyerArbitrator, feePerArb);
            if (p.hasVoted[p.sellerArbitrator]) genToken.transfer(p.sellerArbitrator, feePerArb);
            if (p.hasVoted[p.chiefArbitrator]) genToken.transfer(p.chiefArbitrator, feePerArb);
        }

        emit EscrowSettled(_purchaseId, _recipient, itemVal, totalFee);
    }
}
