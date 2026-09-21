import os
from web3 import Web3
from web3.exceptions import ContractLogicError, TimeExhausted
from dotenv import load_dotenv

load_dotenv()
RPC_URL = os.getenv("RPC_URL", "http://127.0.0.1:8545")
PRIVATE_KEY = os.getenv("PRIVATE_KEY")
ESCROW_CONTRACT_ADDRESS = os.getenv("ESCROW_CONTRACT_ADDRESS")

# Minimal ABI for the canonical GenesisEscrow arbitration path.
CONTRACT_ABI = [{
    "inputs": [{"name": "id", "type": "uint256"}, {"name": "releaseToSeller", "type": "bool"}],
    "name": "castArbitrationVote",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
}]

def main():
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    if not w3.is_connected():
        raise ConnectionError(f"[-] Cannot connect to Genesis node at {RPC_URL}")
    account = w3.eth.account.from_key(PRIVATE_KEY)
    contract = w3.eth.contract(address=w3.to_checksum_address(ESCROW_CONTRACT_ADDRESS), abi=CONTRACT_ABI)
    dispute_id = int(os.getenv("DISPUTE_ID", "0"))
    release_to_seller = os.getenv("RELEASE_TO_SELLER", "false").lower() == "true"
    function = contract.functions.castArbitrationVote(dispute_id, release_to_seller)
    nonce = w3.eth.get_transaction_count(account.address, "pending")
    try:
        gas = int(function.estimate_gas({"from": account.address}) * 1.2)
    except ContractLogicError as err:
        print(f"[-] EVM reversion during simulation: {err}")
        return
    tx = function.build_transaction({"chainId": w3.eth.chain_id, "nonce": nonce, "from": account.address, "gas": gas, "gasPrice": 0, "value": 0})
    signed = w3.eth.account.sign_transaction(tx, private_key=PRIVATE_KEY)
    raw = getattr(signed, "raw_transaction", getattr(signed, "rawTransaction", None))
    tx_hash = w3.eth.send_raw_transaction(raw)
    print(f"[*] Broadcasted Tx Hash: {tx_hash.hex()}")
    print(w3.eth.wait_for_transaction_receipt(tx_hash))

if __name__ == "__main__":
    main()
