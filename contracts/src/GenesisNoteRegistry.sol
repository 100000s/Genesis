// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract GenesisNoteRegistry {
    uint256 public constant UNIT = 1e18;
    mapping(uint256 => bool) public denominationAllowed;
    mapping(bytes32 => bool) public issued;
    mapping(bytes32 => bytes32) public replacedBy;
    struct Metadata { uint256 denomination; bytes32 vaultId; bytes32 designVersion; bytes32 controllerSignature; bytes32 issuerSignature; uint64 issuedAt; bytes32 origin; bytes32 atmSignature; uint64 lastScanAt; bytes32 lastScanLocation; uint16 conditionScore; bytes32 noteHash; }
    mapping(bytes32 => Metadata) public metadata;
    address public owner;
    event NoteIssued(bytes32 indexed serial, uint256 denomination, bytes32 vaultId);
    event NoteReplaced(bytes32 indexed oldSerial, bytes32 indexed newSerial);
    modifier onlyOwner() { require(msg.sender == owner, "GenesisNoteRegistry: owner only"); _; }
    constructor() { owner = msg.sender; denominationAllowed[1] = true; denominationAllowed[5] = true; denominationAllowed[20] = true; denominationAllowed[100] = true; }
    function issue(bytes32 serial, uint256 denomination, bytes32 vaultId, Metadata calldata note) external onlyOwner {
        require(denominationAllowed[denomination] && !issued[serial], "GenesisNoteRegistry: invalid note");
        issued[serial] = true;
        metadata[serial] = Metadata(denomination, vaultId, note.designVersion, note.controllerSignature, note.issuerSignature, uint64(block.timestamp), note.origin, note.atmSignature, note.lastScanAt, note.lastScanLocation, note.conditionScore, note.noteHash);
        emit NoteIssued(serial, denomination, vaultId);
    }
    function recordScan(bytes32 serial, bytes32 atmSignature, uint64 scanAt, bytes32 location, uint16 conditionScore) external onlyOwner {
        require(issued[serial], "GenesisNoteRegistry: unknown note");
        Metadata storage note = metadata[serial]; note.atmSignature = atmSignature; note.lastScanAt = scanAt; note.lastScanLocation = location; note.conditionScore = conditionScore;
    }
    function replace(bytes32 oldSerial, bytes32 newSerial) external onlyOwner {
        require(issued[oldSerial] && !issued[newSerial], "GenesisNoteRegistry: invalid replacement");
        issued[newSerial] = true;
        replacedBy[oldSerial] = newSerial;
        emit NoteReplaced(oldSerial, newSerial);
    }
}