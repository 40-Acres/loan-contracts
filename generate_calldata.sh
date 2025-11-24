#!/bin/bash

# Check if token IDs are provided as command line arguments
if [ $# -gt 0 ]; then
    # Use command line arguments
    token_ids=("$@")
else
    # Default token IDs if no arguments provided
    token_ids=(5618)
fi

# Contract addresses
xpharaoh_loan="0x6Bf2Fe80D245b06f6900848ec52544FBdE6c8d2C"
portfolio_factory="0x52d43C377e498980135C8F2E858f120A18Ea96C2"

echo "Generated calldata for migration transactions:"
echo "=============================================="

for token_id in "${token_ids[@]}"; do
    calldata=$(cast calldata "migrateNft(uint256,address,address)" $token_id $xpharaoh_loan $portfolio_factory)
    echo "Token ID $token_id: $calldata"
done
