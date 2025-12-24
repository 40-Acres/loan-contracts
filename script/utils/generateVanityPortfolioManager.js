#!/usr/bin/env node

/**
 * @title Generate Vanity PortfolioManager Address
 * @dev JavaScript script to find a salt that produces a PortfolioManager address starting with "40Ac2e"
 * 
 * Usage:
 *   node script/utils/generateVanityPortfolioManager.js
 * 
 * Requirements:
 *   npm install ethers
 */

const { ethers } = require('ethers');
const { readFileSync } = require('fs');
const { join } = require('path');
const { keccak_256 } = require('js-sha3');

// Helper to compute keccak256 hash
function keccak256(data) {
    // Try ethers first (most reliable)
    if (ethers.keccak256) {
        return ethers.keccak256(data);
    } else if (ethers.utils && ethers.utils.keccak256) {
        return ethers.utils.keccak256(data);
    } else {
        // Fallback to js-sha3
        const hex = data.startsWith('0x') ? data.slice(2) : data;
        const buffer = Buffer.from(hex, 'hex');
        const hash = keccak_256(buffer);
        return '0x' + hash;
    }
}

// Constants
const FORTY_ACRES_DEPLOYER = '0x40FecA5f7156030b78200450852792ea93f7c6cd';
// Target prefix - case insensitive (0x40Ac2e = 0x40ac2e = 0x40AC2E)
// We use lowercase for consistency, but any case will match
const TARGET_PREFIX = '0x40ac2e'; // Lowercase for consistency
const TARGET_PREFIX_VALUE = BigInt(TARGET_PREFIX); // Numeric value for comparison
const PREFIX_BITS = 24; // 6 hex characters = 24 bits
const SHIFT_BITS = 160 - PREFIX_BITS; // 136 bits

// PortfolioManager bytecode (we'll need to get this from the compiled contract)
// For now, we'll compute it dynamically or you can hardcode it
function getPortfolioManagerBytecode() {
    // Try to read from artifacts if available
    try {
        const artifactPath = join(__dirname, '../../out/PortfolioManager.sol/PortfolioManager.json');
        const artifact = JSON.parse(readFileSync(artifactPath, 'utf8'));
        return artifact.bytecode.object;
    } catch (e) {
        console.error('Could not read PortfolioManager artifact. Please compile first: forge build');
        process.exit(1);
    }
}

/**
 * Compute CREATE2 address
 * Formula: keccak256(0xff || deployer || salt || keccak256(bytecode))[12:]
 */
function computeCreate2Address(salt, bytecode, deployer) {
    // Hash the bytecode first
    const bytecodeWithPrefix = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode;
    const bytecodeHash = keccak256(bytecodeWithPrefix);
    
    // Create the data: 0xff || deployer || salt || bytecodeHash
    // Manually construct the bytes
    let deployerBytes, saltBytes, hashBytes;
    if (ethers.getBytes) {
        // ethers v6
        deployerBytes = ethers.getBytes(deployer);
        saltBytes = ethers.getBytes(salt);
        hashBytes = ethers.getBytes(bytecodeHash);
    } else if (ethers.utils && ethers.utils.arrayify) {
        // ethers v5
        deployerBytes = ethers.utils.arrayify(deployer);
        saltBytes = ethers.utils.arrayify(salt);
        hashBytes = ethers.utils.arrayify(bytecodeHash);
    } else {
        // Manual conversion
        deployerBytes = Buffer.from(deployer.slice(2), 'hex');
        saltBytes = Buffer.from(salt.slice(2), 'hex');
        hashBytes = Buffer.from(bytecodeHash.slice(2), 'hex');
    }
    
    // Concatenate: 0xff (1 byte) + deployer (20 bytes) + salt (32 bytes) + hash (32 bytes) = 85 bytes
    const data = Buffer.concat([
        Buffer.from([0xff]),
        deployerBytes,
        saltBytes,
        hashBytes
    ]);
    
    // Hash the concatenated data
    const dataHex = '0x' + data.toString('hex');
    const hash = keccak256(dataHex);
    
    // Take last 20 bytes (40 hex characters) and format as address
    const address = '0x' + hash.slice(-40);
    return ethers.getAddress ? ethers.getAddress(address) : address;
}

/**
 * Check if address starts with target prefix
 * Case-insensitive: 0x40Ac2e, 0x40ac2e, 0x40AC2E all match
 */
function matchesPrefix(address) {
    // Convert address to BigInt for bit operations (case-insensitive)
    // BigInt conversion automatically handles any case in hex
    const addrBigInt = BigInt(address.toLowerCase());
    // Shift right by 136 bits to get first 24 bits
    const prefix = addrBigInt >> BigInt(SHIFT_BITS);
    // Compare with target prefix value (case-insensitive comparison)
    const matches = prefix === TARGET_PREFIX_VALUE;
    
    return matches;
}

/**
 * Generate PortfolioManager bytecode with constructor args
 * This gets the creation code from the compiled artifact
 */
function generateBytecode() {
    const artifactPath = join(__dirname, '../../out/PortfolioManager.sol/PortfolioManager.json');
    
    try {
        // Read the artifact
        const artifact = JSON.parse(readFileSync(artifactPath, 'utf8'));
        
        // Get the creation bytecode (this is the bytecode used for deployment)
        // The artifact has 'bytecode' which is the creation code
        let creationCode = artifact.bytecode.object;
        
        // Encode constructor arguments (ABI encoding)
        // Address is 20 bytes, ABI-encoded as 32 bytes (left-padded with zeros)
        // Remove '0x' prefix and pad to 64 hex characters (32 bytes)
        const addressHex = FORTY_ACRES_DEPLOYER.slice(2).toLowerCase();
        // ABI encoding: address is left-padded to 32 bytes (64 hex chars)
        const constructorArgs = '0x' + addressHex.padStart(64, '0');
        
        // Creation code = bytecode + constructor args (without 0x prefix)
        const fullBytecode = creationCode + constructorArgs.slice(2);
        
        return fullBytecode;
    } catch (e) {
        console.error('Error getting bytecode:', e.message);
        console.error('Stack:', e.stack);
        console.error('Please compile the contracts first: forge build');
        process.exit(1);
    }
}

// Global variables
let shouldStop = false;
let forceExit = false;
let attempts = 0; // Make attempts global for debug logging

// Handle Ctrl+C gracefully - set up early
process.on('SIGINT', () => {
    if (forceExit) {
        console.log('\n\nForce exiting...');
        process.exit(1);
    }
    if (!shouldStop) {
        shouldStop = true;
        console.log('\n\nStopping search... (press Ctrl+C again to force exit)');
    } else {
        forceExit = true;
        console.log('\n\nForce exiting...');
        process.exit(1);
    }
});

process.on('SIGTERM', () => {
    shouldStop = true;
    console.log('\n\nSearch terminated.');
});

// Test function to verify matching logic works
function testMatching() {
    console.log('Testing prefix matching logic...');
    
    // Test addresses that should match
    const testAddresses = [
        '0x40Ac2e1234567890abcdef1234567890abcdef12',
        '0x40ac2e1234567890abcdef1234567890abcdef12',
        '0x40AC2E1234567890abcdef1234567890abcdef12',
    ];
    
    // Test addresses that should NOT match
    const nonMatchAddresses = [
        '0x40Ac2f1234567890abcdef1234567890abcdef12', // Different last char
        '0x40Ac2d1234567890abcdef1234567890abcdef12', // Different last char
        '0x50Ac2e1234567890abcdef1234567890abcdef12', // Different first char
    ];
    
    console.log('Testing addresses that SHOULD match:');
    testAddresses.forEach(addr => {
        const result = matchesPrefix(addr);
        console.log(`  ${addr.slice(0, 10)}... : ${result ? '✓ MATCH' : '✗ NO MATCH'}`);
        if (!result) {
            console.error('ERROR: Should have matched!');
            process.exit(1);
        }
    });
    
    console.log('Testing addresses that should NOT match:');
    nonMatchAddresses.forEach(addr => {
        const result = matchesPrefix(addr);
        console.log(`  ${addr.slice(0, 10)}... : ${result ? '✗ FALSE MATCH' : '✓ NO MATCH (correct)'}`);
        if (result) {
            console.error('ERROR: Should not have matched!');
            process.exit(1);
        }
    });
    
    console.log('✓ All matching tests passed!\n');
}

async function main() {
    // Test matching logic first
    testMatching();
    
    console.log('Looking for PortfolioManager address starting with 0x40Ac2e...');
    console.log('(Case-insensitive: will match 0x40Ac2e, 0x40ac2e, 0x40AC2E, etc.)');
    console.log('Deployer address:', FORTY_ACRES_DEPLOYER);
    
    // Generate bytecode
    console.log('Generating bytecode...');
    let bytecode = generateBytecode();
    // Ensure bytecode has 0x prefix
    if (!bytecode.startsWith('0x')) {
        bytecode = '0x' + bytecode;
    }
    
    // Hash bytecode
    const bytecodeHash = keccak256(bytecode);
    console.log('Bytecode hash:', bytecodeHash);
    console.log('Bytecode length:', (bytecode.length - 2) / 2, 'bytes');
    
    attempts = 0;
    const maxAttempts = Number.MAX_SAFE_INTEGER; // No limit in JS
    const startTime = Date.now();
    
    console.log('Starting search...');
    console.log('Target prefix: 0x40Ac2e... (first 6 hex characters, case-insensitive)');
    console.log('Press Ctrl+C to stop\n');
    
    while (attempts < maxAttempts && !shouldStop && !forceExit) {
        // Check for interrupt every iteration (for immediate response)
        if (shouldStop || forceExit) {
            break;
        }
        
        // Generate salt using timestamp and attempts (matching Solidity script)
        const timestamp = Math.floor(Date.now() / 1000);
        
        // Pack the data: abi.encodePacked(timestamp, attempts, deployer)
        // uint256 (32 bytes) + uint256 (32 bytes) + address (20 bytes) = 84 bytes
        const timestampHex = BigInt(timestamp).toString(16).padStart(64, '0');
        const attemptsHex = BigInt(attempts).toString(16).padStart(64, '0');
        const deployerHex = FORTY_ACRES_DEPLOYER.slice(2).toLowerCase();
        const packedData = '0x' + timestampHex + attemptsHex + deployerHex;
        
        // Hash the packed data
        const salt = keccak256(packedData);
        
        // Compute address
        const predictedAddress = computeCreate2Address(salt, bytecode, FORTY_ACRES_DEPLOYER);
        
        // Check if it matches
        if (matchesPrefix(predictedAddress)) {
            const elapsed = ((Date.now() - startTime) / 1000).toFixed(2);
            console.log('\n=== FOUND VANITY ADDRESS ===');
            console.log('Salt (hex):', salt);
            console.log('Salt (uint256):', BigInt(salt).toString());
            console.log('Predicted PortfolioManager address:', predictedAddress);
            console.log('Attempts needed:', attempts.toLocaleString());
            console.log('Time elapsed:', elapsed, 'seconds');
            console.log('Speed:', (attempts / parseFloat(elapsed)).toFixed(0), 'attempts/second');
            
            // Verify
            const verified = computeCreate2Address(salt, bytecode, FORTY_ACRES_DEPLOYER);
            if (verified.toLowerCase() !== predictedAddress.toLowerCase()) {
                console.error('ERROR: Address verification failed!');
                process.exit(1);
            }
            console.log('Address verification: PASSED');
            
            console.log('\n=== DEPLOYMENT INSTRUCTIONS ===');
            console.log('Use this salt when deploying PortfolioManager via CREATE2:');
            console.log(`bytes32 salt = bytes32(${BigInt(salt).toString()});`);
            console.log(`// Or in hex:`);
            console.log(`bytes32 salt = ${salt};`);
            console.log('// Deploy from a contract using CREATE2:');
            console.log('PortfolioManager manager = new PortfolioManager{salt: salt}(FORTY_ACRES_DEPLOYER);');
            console.log('\nNOTE: The deployer must be a contract address that can execute CREATE2.');
            console.log('If deploying from an EOA, you\'ll need a deployer contract.');
            
            process.exit(0);
        }
        
        attempts++;
        
        // Allow event loop to process signals every 1000 attempts
        if (attempts % 1000 === 0) {
            // Use setImmediate to allow signal processing
            if (shouldStop || forceExit) {
                break;
            }
            // Give event loop a chance to process signals
            await new Promise(resolve => setImmediate(resolve));
        }
        
        // Progress logging
        if (attempts % 100000 === 0) {
            if (shouldStop || forceExit) {
                break;
            }
            const elapsed = (Date.now() - startTime) / 1000;
            const speed = attempts / elapsed;
            const addrPrefix = predictedAddress.slice(0, 8); // Show first 6 hex chars
            console.log(`Attempts: ${attempts.toLocaleString()} | Speed: ${speed.toFixed(0)}/s | Current: ${addrPrefix}...`);
            
            // Show probability info every 1M attempts
            if (attempts % 1000000 === 0) {
                // Probability of finding 6-char prefix = 1 / 16^6 = 1 / 16,777,216
                const expectedAttempts = 16777216;
                const probability = Math.min(1, attempts / expectedAttempts);
                console.log(`  Probability of finding match: ${(probability * 100).toFixed(2)}% (expected: ~${expectedAttempts.toLocaleString()} attempts)`);
            }
        }
    }
    
    if (shouldStop || forceExit) {
        console.log('\n\nSearch interrupted by user.');
        const elapsed = ((Date.now() - startTime) / 1000).toFixed(2);
        console.log(`Total attempts: ${attempts.toLocaleString()}`);
        console.log(`Time elapsed: ${elapsed} seconds`);
        if (parseFloat(elapsed) > 0) {
            const speed = attempts / parseFloat(elapsed);
            console.log(`Average speed: ${speed.toFixed(0)} attempts/second`);
        }
        process.exit(0);
    }
}

main().catch((error) => {
    console.error('Error:', error);
    process.exit(1);
});

