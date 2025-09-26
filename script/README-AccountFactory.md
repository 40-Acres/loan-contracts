# Account Factory Deployment Scripts

This directory contains deployment scripts for the Account Factory system, which creates diamond-based user accounts with upgradeable implementations.

## Scripts Overview

### 1. `PortfolioFactoryDeploy.s.sol` - Basic Deployment
- **Purpose**: Complete deployment with verification and testing
- **Features**: 
  - Deploys all components
  - Includes test implementation
  - Verifies deployment
  - Tests account creation
- **Use Case**: Standard deployment with full testing

### 2. `PortfolioFactoryDeployAdvanced.s.sol` - Network-Specific Deployment
- **Purpose**: Advanced deployment with network configurations
- **Features**:
  - Supports multiple networks (Ethereum, Base, Polygon, Arbitrum, Optimism)
  - Network-specific configurations
  - Multiple implementation versions
  - Comprehensive testing
- **Use Case**: Production deployment across multiple networks

### 3. `PortfolioFactoryDeploySimple.s.sol` - Quick Testing
- **Purpose**: Minimal deployment for quick testing
- **Features**:
  - Minimal components
  - Quick account creation test
  - Simple verification
- **Use Case**: Development and testing

## Deployment Components

The scripts deploy the following components:

1. **ImplementationRegistry** - Manages different account implementations
2. **DiamondCutFacet** - Core diamond functionality
3. **DiamondLoupeFacet** - Diamond introspection
4. **OwnershipFacet** - Ownership management
5. **AccountFacet** - Account-specific functions
6. **PortfolioFactory** - Main factory contract
7. **Test Implementations** - Sample implementations

## Usage

### Environment Setup

Create a `.env` file with:
```bash
PRIVATE_KEY=your_private_key_here
NETWORK=base  # For advanced script
```

### Basic Deployment

```bash
# Deploy with full testing
forge script script/PortfolioFactoryDeploy.s.sol --rpc-url $RPC_URL --broadcast --verify

# Deploy advanced version
forge script script/PortfolioFactoryDeployAdvanced.s.sol --rpc-url $RPC_URL --broadcast --verify

# Deploy simple version
forge script script/PortfolioFactoryDeploySimple.s.sol --rpc-url $RPC_URL --broadcast
```

### Network-Specific Deployment

```bash
# Deploy to Base
NETWORK=base forge script script/PortfolioFactoryDeployAdvanced.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify

# Deploy to Polygon
NETWORK=polygon forge script script/PortfolioFactoryDeployAdvanced.s.sol --rpc-url $POLYGON_RPC_URL --broadcast --verify
```

### Testing Functions

```bash
# Test account creation
forge script script/PortfolioFactoryDeploy.s.sol:PortfolioFactoryDeploy --sig "testAccountCreation()" --rpc-url $RPC_URL

# Test account system
forge script script/PortfolioFactoryDeployAdvanced.s.sol:PortfolioFactoryDeployAdvanced --sig "testAccountSystem()" --rpc-url $RPC_URL
```

## Post-Deployment

### Adding New Implementations

```bash
# Add new implementation version
forge script script/PortfolioFactoryDeploy.s.sol:PortfolioFactoryDeploy --sig "addImplementationVersion(uint256,address,string)" 3 0x... "New Implementation v3.0" --rpc-url $RPC_URL

# Set latest version
forge script script/PortfolioFactoryDeploy.s.sol:PortfolioFactoryDeploy --sig "setLatestVersion(uint256)" 3 --rpc-url $RPC_URL
```

### Verification

After deployment, verify the contracts:

```bash
# Verify all contracts
forge verify-contract --chain-id $CHAIN_ID --num-of-optimizations 200 --watch --constructor-args $(cast abi-encode "constructor(address,address,address)" $REGISTRY $DIAMOND_CUT $ACCOUNT_FACET) $FACTORY_ADDRESS src/accounts/PortfolioFactory.sol:PortfolioFactory
```

## Deployment Output

The scripts will output:

```
=== Deploying Implementation Registry ===
Implementation Registry: 0x...

=== Deploying Facets ===
DiamondCutFacet: 0x...
AccountFacet: 0x...

=== Deploying Account Factory ===
Account Factory: 0x...

=== Testing Account Creation ===
Account created: 0x...
✅ Account creation test passed!

============================================================
ACCOUNT FACTORY DEPLOYMENT SUMMARY
============================================================
Implementation Registry: 0x...
Account Factory: 0x...
Test Implementation: 0x...
============================================================
```

## Network Configurations

The advanced script supports these networks:

| Network | Chain ID | USDC Address | Deterministic Deployer |
|---------|----------|--------------|----------------------|
| Ethereum | 1 | 0xA0b86a33E6441b8c4C8C0C4C0C4C0C4C0C4C0C4C | ✅ |
| Base | 8453 | 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 | ✅ |
| Polygon | 137 | 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174 | ✅ |
| Arbitrum | 42161 | 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 | ✅ |
| Optimism | 10 | 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85 | ✅ |

## Troubleshooting

### Common Issues

1. **Insufficient Gas**: Increase gas limit in deployment
2. **Network Mismatch**: Ensure correct RPC URL and chain ID
3. **Private Key Issues**: Verify private key format and permissions
4. **Verification Failures**: Check constructor arguments and optimization settings

### Gas Optimization

For production deployments, consider:
- Using `--gas-limit` flag for large deployments
- Deploying during low network activity
- Using gas estimation tools

## Security Notes

- Never commit private keys to version control
- Use environment variables for sensitive data
- Verify all contracts after deployment
- Test thoroughly on testnets before mainnet deployment
- Consider using multisig for production deployments

