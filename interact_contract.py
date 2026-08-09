import os
import json
from dotenv import load_dotenv
from web3 import Web3
from web3.exceptions import ContractLogicError, TimeExhausted

load_dotenv()

RPC_URL = os.getenv("RPC_URL", "http://127.0.0.1:8545")
PRIVATE_KEY = os.getenv("PRIVATE_KEY")
ESCROW_CONTRACT_ADDRESS = os.getenv("ESCROW_CONTRACT_ADDRESS")

# Minimal ABI structure for GenesisEscrowArbitration / Sovereign interactions
CONTRACT_ABI = [
    {
        "inputs": [
            {"name": "disputeId", "type": "bytes32"},
            {"name": "decision", "type": "uint8"}
        ],
        "name": "resolveArbitration",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
    }
]

def main():
    # 1. Connect to Sovereign Local Node RPC/IPC
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    if not w3.is_connected():
        raise ConnectionError(f"[-] Cannot connect to Genesis node at {RPC_URL}")
    print(f"[+] Connected to Sovereign Genesis Node | Chain ID: {w3.eth.chain_id}")

    # 2. Setup Account (Verifier, Validator, Issuer, or Arbitrator)
    account = w3.eth.account.from_key(PRIVATE_KEY)
    sender_address = account.address
    print(f"[+] Signer Address: {sender_address}")

    # 3. Load Escrow / Sovereign Contract
    contract_checksum = w3.to_checksum_address(ESCROW_CONTRACT_ADDRESS)
    contract = w3.eth.contract(address=contract_checksum, abi=CONTRACT_ABI)

    # 4. Transaction Setup (Zero Fees)
    nonce = w3.eth.get_transaction_count(sender_address, "pending")

    # Target method & arguments (e.g., GenesisEscrowArbitration resolution)
    dispute_id = w3.keccak(text="dispute_sample_001")
    decision_code = 1  # Arbitrator decision payload
    
    contract_func = contract.functions.resolveArbitration(dispute_id, decision_code)

    # In a zero-fee chain, gasLimit is still required for EVM execution step limits,
    # but gasPrice and fee parameters are explicitly set to 0.
    try:
        estimated_gas_units = contract_func.estimate_gas({"from": sender_address, "value": 0})
        gas_limit = int(estimated_gas_units * 1.2)
    except ContractLogicError as err:
        print(f"[-] EVM Reversion during simulation: {err}")
        return

    # Construct Zero-Fee Transaction Payload
    tx_params = {
        "chainId": w3.eth.chain_id,
        "nonce": nonce,
        "from": sender_address,
        "gas": gas_limit,
        "gasPrice": 0,           # Zero-fee network execution
        "value": 0,
    }

    # 5. Build, Sign, and Broadcast
    built_tx = contract_func.build_transaction(tx_params)
    signed_tx = w3.eth.account.sign_transaction(built_tx, private_key=PRIVATE_KEY)

    raw_tx = getattr(signed_tx, "raw_transaction", getattr(signed_tx, "rawTransaction", None))
    tx_hash = w3.eth.send_raw_transaction(raw_tx)
    print(f"[*] Broadcasted Tx Hash: {tx_hash.hex()}")

    # 6. Await Receipt Confirmation
    print("[*] Awaiting block inclusion...")
    try:
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60, poll_latency=1)
        if receipt.status == 1:
            print(f"[✔] Transaction Executed Successfully in Block #{receipt.blockNumber}")
        else:
            print(f"[✘] Transaction Reverted on-chain in Block #{receipt.blockNumber}")
    except TimeExhausted:
        print("[-] Timeout waiting for block receipt.")

if __name__ == "__main__":
    main()
