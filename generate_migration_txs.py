#!/usr/bin/env python3

import json
import subprocess
import sys

# Token IDs in the order specified by the user
token_ids = [5959, 5961, 6335, 6524, 4593, 5603, 5597, 4613, 5596, 5418, 6336, 5451, 6088, 4997, 6301, 4345, 6769, 502, 6179, 6346, 6351, 6511, 6378, 5447, 6397, 6452, 6136, 6734, 6430, 3601, 5595, 204, 6106, 6554, 6459, 6427, 6341, 5618, 6396, 195, 6107, 5186, 327, 3802, 6457, 4554, 6530, 5510, 6163, 6304, 6699, 3884, 6617, 6513, 4141, 6391, 3993, 108, 6613, 420, 3818, 5604, 6135, 3178, 3111, 4390, 4240, 6517, 4995, 100, 16201, 93, 4496, 6093, 3618, 6515, 3383]

# Contract addresses
pharaoh_loan = "0xf6A044c3b2a3373eF2909E2474f3229f23279B5F"
xpharaoh_loan = "0x6Bf2Fe80D245b06f6900848ec52544FBdE6c8d2C"
portfolio_factory = "0x52d43C377e498980135C8F2E858f120A18Ea96C2"

def generate_calldata(token_id):
    """Generate calldata for migrateNft function"""
    try:
        result = subprocess.run([
            'cast', 'calldata', 
            'migrateNft(uint256,address,address)', 
            str(token_id), 
            xpharaoh_loan, 
            portfolio_factory
        ], capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"Error generating calldata for token {token_id}: {e}")
        return None

def create_transaction_json(token_ids, calldatas):
    """Create transaction JSON for multiple token IDs"""
    transactions = []
    for i, token_id in enumerate(token_ids):
        transactions.append({
            "to": pharaoh_loan,
            "value": "0",
            "data": calldatas[i]
        })
    
    return {
        "chainId": "43114",
        "transactions": transactions
    }

def main():
    print(f"Generating migration transactions for {len(token_ids)} token IDs...")
    print("Grouping 5 token IDs per file...")
    
    file_count = 0
    batch_token_ids = []
    batch_calldatas = []
    
    for i, token_id in enumerate(token_ids):
        print(f"Processing token ID {token_id} ({i+1}/{len(token_ids)})")
        
        # Generate calldata
        calldata = generate_calldata(token_id)
        if not calldata:
            print(f"Failed to generate calldata for token {token_id}, skipping...")
            continue
        
        batch_token_ids.append(token_id)
        batch_calldatas.append(calldata)
        
        # Create file when we have 5 tokens or reach the end
        if len(batch_token_ids) == 5 or i == len(token_ids) - 1:
            file_count += 1
            tx_json = create_transaction_json(batch_token_ids, batch_calldatas)
            
            # Create filename with individual token IDs
            token_list = "_".join(map(str, batch_token_ids))
            filename = f"migrate_tokens_{token_list}.json"
            
            with open(filename, 'w') as f:
                json.dump(tx_json, f, indent=2)
            
            print(f"Created {filename} with {len(batch_token_ids)} transactions")
            
            # Reset batch
            batch_token_ids = []
            batch_calldatas = []
    
    print(f"\nGenerated {file_count} migration transaction files!")
    print("Each file contains up to 5 transactions.")

if __name__ == "__main__":
    main()
