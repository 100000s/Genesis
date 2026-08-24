// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract GenesisToken {
    string public constant name = "Genesis Token";
    string public constant symbol = "GEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public owner;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public minters;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event MinterUpdated(address indexed minter, bool enabled);

    modifier onlyOwner() {
        require(msg.sender == owner, "GenesisToken: owner only");
        _;
    }

    modifier onlyMinter() {
        require(minters[msg.sender], "GenesisToken: minter only");
        _;
    }

    constructor() {
        owner = msg.sender;
        minters[msg.sender] = true;
    }

    function setMinter(address minter, bool enabled) external onlyOwner {
        require(minter != address(0), "GenesisToken: zero address");
        minters[minter] = enabled;
        emit MinterUpdated(minter, enabled);
    }

    function mint(address to, uint256 amount) external onlyMinter {
        require(to != address(0), "GenesisToken: zero recipient");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[from][msg.sender];
        require(permitted >= amount, "GenesisToken: allowance exceeded");
        if (permitted != type(uint256).max) allowance[from][msg.sender] = permitted - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "GenesisToken: zero recipient");
        require(balanceOf[from] >= amount, "GenesisToken: balance exceeded");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}