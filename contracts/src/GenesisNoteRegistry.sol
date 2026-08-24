// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract GenesisNoteRegistry {
    uint256 public constant UNIT = 1e18;
    mapping(uint256 => bool) public denominationAllowed;
    mapping(bytes32 => bool) public issued;
    mapping(bytes32 => bytes32) public replacedBy;
    address public owner;
    event NoteIssued(bytes32 indexed serial, uint256 denomination, bytes32 vaultId);
    event NoteReplaced(bytes32 indexed oldSerial, bytes32 indexed newSerial);
    modifier onlyOwner() { require(msg.sender == owner, "GenesisNoteRegistry: owner only"); _; }
    constructor() { owner = msg.sender; denominationAllowed[1] = true; denominationAllowed[5] = true; denominationAllowed[20] = true; denominationAllowed[100] = true; }
    function issue(bytes32 serial, uint256 denomination, bytes32 vaultId) external onlyOwner {
        require(denominationAllowed[denomination] && !issued[serial], "GenesisNoteRegistry: invalid note");
        issued[serial] = true;
        emit NoteIssued(serial, denomination, vaultId);
    }
    function replace(bytes32 oldSerial, bytes32 newSerial) external onlyOwner {
        require(issued[oldSerial] && !issued[newSerial], "GenesisNoteRegistry: invalid replacement");
        issued[newSerial] = true;
        replacedBy[oldSerial] = newSerial;
        emit NoteReplaced(oldSerial, newSerial);
    }
}