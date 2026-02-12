// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SwapMod} from "../swap/SwapMod.sol";
import {SwapConfig} from "../config/SwapConfig.sol";
import {VotingEscrowFacet} from "../votingEscrow/VotingEscrowFacet.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";


// WalletFacet is a facet that can handle tokens for the owner, so they can be utilized without having to approve each token individually
// There should be no other functions on this diamond other than the ones listed here, and it should not hold any collateral or have any borrowing power on its own. It is purely a utility for the owner to manage their tokens across their portfolios
contract WalletFacet is AccessControl, IERC721Receiver {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    SwapConfig public immutable _swapConfig;

    event LockCreated(uint256 indexed tokenId, uint256 amount, address indexed owner, address indexed toPortfolio);

    /**
     * @dev Required by PortfolioManager.multicall - always returns true since wallet has no collateral requirements
     */
    function enforceCollateralRequirements() external pure returns (bool) {
        return true;
    }

    constructor(address portfolioFactory, address portfolioAccountConfig, address swapConfig) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        require(swapConfig != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _swapConfig = SwapConfig(swapConfig);
    }

    function transferERC20(address token, uint256 amount, address to) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        // Verify the destination portfolio is owned by the same user
        PortfolioManager manager = PortfolioManager(address(_portfolioFactory.portfolioManager()));
        address walletOwner = _portfolioFactory.ownerOf(address(this));
        address targetFactory = manager.getFactoryForPortfolio(to);
        require(targetFactory != address(0), "Target portfolio not registered");
        address targetOwner = PortfolioFactory(targetFactory).ownerOf(to);
        require(walletOwner == targetOwner, "Must own both portfolios");
        IERC20(token).transfer(to, amount);
    }

    function transferNFT(address nft, uint256 tokenId, address to) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        // Verify the destination portfolio is owned by the same user
        PortfolioManager manager = PortfolioManager(address(_portfolioFactory.portfolioManager()));
        address walletOwner = _portfolioFactory.ownerOf(address(this));
        address targetFactory = manager.getFactoryForPortfolio(to);
        require(targetFactory != address(0), "Target portfolio not registered");
        address targetOwner = PortfolioFactory(targetFactory).ownerOf(to);
        require(walletOwner == targetOwner, "Must own both portfolios");
        IERC721(nft).transferFrom(address(this), to, tokenId);
    }

    function swap(address swapTarget, bytes memory swapData, address inputToken, uint256 inputAmount, address outputToken, uint256 minimumOutputAmount) external onlyPortfolioManagerMulticall(_portfolioFactory) returns (uint256 amount) {
        uint256 swappedAmount = SwapMod.swap(address(_swapConfig), swapTarget, swapData, inputToken, inputAmount, outputToken, minimumOutputAmount);
        return swappedAmount;
    }

    /**
    * @dev Required by IERC721Receiver - allows this contract to receive ERC721 tokens
    */ 
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}