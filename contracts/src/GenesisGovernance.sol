// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract GenesisGovernance {
    enum Track{Authentication,Core,Interface,Knowledge,Oracle,Process} enum Status{Draft,Review,LastCall,Staged,Implemented,NotImplemented}
    uint64 public constant REVIEW_PERIOD=7 days; uint64 public constant LAST_CALL_PERIOD=28 days; uint64 public constant ACTIVATION_WINDOW=12 weeks; uint256 public constant REQUIRED_BPS=5001; address public owner;
    struct GiP{bytes32 id;Track track;address proposer;bytes32 specificationHash;bytes32 ordinalHash;uint64 createdAt;uint64 lastCallEnds;Status status;}
    mapping(bytes32=>GiP) public proposals; mapping(bytes32=>mapping(address=>bool)) public voted; mapping(bytes32=>uint256) public yes; mapping(bytes32=>uint256) public no; mapping(address=>uint256) public credits; mapping(address=>address) public delegateOf;
    event GiPProposed(bytes32 indexed id,Track track,bytes32 specificationHash,bytes32 ordinalHash); event VoteCast(bytes32 indexed id,address indexed voter,bool support,uint256 weight); event StatusChanged(bytes32 indexed id,Status status);
    modifier onlyOwner(){require(msg.sender==owner,"Governance: owner");_;} constructor(){owner=msg.sender;}
    function propose(bytes32 id,Track track,bytes32 specificationHash,bytes32 ordinalHash) external{require(proposals[id].proposer==address(0),"Governance: exists");proposals[id]=GiP(id,track,msg.sender,specificationHash,ordinalHash,uint64(block.timestamp),uint64(block.timestamp)+REVIEW_PERIOD+LAST_CALL_PERIOD,Status.Review);emit GiPProposed(id,track,specificationHash,ordinalHash);}
    function issueCredits(address who,uint256 amount) external onlyOwner{require(amount<=150,"Governance: credits");credits[who]=amount;} function setDelegate(address who) external{delegateOf[msg.sender]=who;}
    function enterLastCall(bytes32 id) external onlyOwner{GiP storage p=proposals[id];require(p.status==Status.Review&&block.timestamp>=p.createdAt+REVIEW_PERIOD,"Governance: review");p.status=Status.LastCall;emit StatusChanged(id,p.status);}
    function vote(bytes32 id,bool support,uint256 spent) external{GiP memory p=proposals[id];require(p.status==Status.Review||p.status==Status.LastCall,"Governance: inactive");require(block.timestamp<p.lastCallEnds&&!voted[id][msg.sender]&&spent>0&&spent<=credits[msg.sender],"Governance: vote");voted[id][msg.sender]=true;uint256 weight=spent*spent;if(support)yes[id]+=weight;else no[id]+=weight;emit VoteCast(id,msg.sender,support,weight);}
    function resolve(bytes32 id) external onlyOwner{GiP storage p=proposals[id];require(p.status==Status.LastCall&&block.timestamp>=p.lastCallEnds,"Governance: window");p.status=yes[id]*BPS()/ (yes[id]+no[id])>=REQUIRED_BPS?Status.Staged:Status.NotImplemented;emit StatusChanged(id,p.status);}
    function activate(bytes32 id) external onlyOwner{GiP storage p=proposals[id];require(p.status==Status.Staged&&block.timestamp<=p.lastCallEnds+ACTIVATION_WINDOW,"Governance: activation");p.status=Status.Implemented;emit StatusChanged(id,p.status);}
    function BPS() private pure returns(uint256){return 10000;}
}
