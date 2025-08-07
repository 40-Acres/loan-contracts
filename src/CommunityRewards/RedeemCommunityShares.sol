// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

interface IOwnable {
    function owner() external view returns (address);
}

contract RedeemCommunityShares is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable {

    IERC20 public payoutToken;
    IERC20 public communityRewards;
    address public loanContract;

    /* 
     * @notice Error thrown when an unauthorized action is attempted.
     */
    error NotAuthorized();

    /* 
     * @notice Error thrown when a zero redemption is attempted.
     */
    error ZeroRedemption();

    /* 
     * @notice Error thrown when a transfer fails.
     */
    error TransferFailed();

    /* 
     * @notice Error thrown when the user does not have enough shares to redeem.
     */
    error InsufficientShares();

    /* 
     * @notice Error thrown when the contract does not have enough payout tokens to redeem.
     */
    error InsufficientPayoutTokens();

    /* 
     * @notice Emitted when shares are redeemed.
     * @param user The address of the user who redeemed the shares.
     * @param totalSharesRedeemed The amount of shares redeemed and sent to the owner of the loan contract.
     * @param totalPayout The amount of payout tokens received by the user.
     */
    event Redeemed(address indexed user, uint256 totalSharesRedeemed, uint256 totalPayout);

    /* 
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     */
    function _authorizeUpgrade(address) internal override view {
        if (msg.sender != IOwnable(loanContract).owner()) revert NotAuthorized();
    }
    
    /* 
     * @notice Initializes the contract.
     * @param _payoutToken The address of the payout token.
     * @param _communityRewards The address of the community rewards contract.
     */
    function initialize(
        address _payoutToken,
        address _loanContract,
        address _communityRewards
    ) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        
        payoutToken = IERC20(_payoutToken);
        loanContract = _loanContract;
        communityRewards = IERC20(_communityRewards);
    }

    /* 
     * @notice Redeems shares 1:1 for payout tokens
     * @param totalSharesToRedeem The amount of shares to redeem.
     * @dev Owner of the loan contract cannot redeem.
     */
    function redeem(uint256 totalSharesToRedeem) external nonReentrant {
        require(totalSharesToRedeem > 0, ZeroRedemption());
        // require not owner of the loan contract
        require(msg.sender != IOwnable(loanContract).owner(), NotAuthorized());


        // check total payout available. Shares are paid 1:1 to the payout token
        require(payoutToken.balanceOf(address(this)) >= totalSharesToRedeem, InsufficientPayoutTokens());

        // get the amount of shares the user has
        uint256 userShares = communityRewards.balanceOf(msg.sender);

        // check if the user has enough shares to redeem
        require(userShares >= totalSharesToRedeem, InsufficientShares());

        // Send shares to owner of the loan contract
        require(communityRewards.transferFrom(msg.sender, IOwnable(loanContract).owner(), totalSharesToRedeem), TransferFailed());

        // transfer the payout token to the user
        require(payoutToken.transfer(msg.sender, totalSharesToRedeem), TransferFailed());

        emit Redeemed(msg.sender, totalSharesToRedeem, totalSharesToRedeem);
    }

    /* 
     * @notice Rescue any ERC20 tokens that are stuck in the contract.
     * @dev This function can only be called by the owner of the loan contract.
     * @param token The address of the ERC20 token to rescue.
     * @param amount The amount of tokens to rescue.
     */
    function rescueERC20(address token, uint256 amount) public {
        if (msg.sender != IOwnable(loanContract).owner()) revert NotAuthorized();

        IERC20(token).transfer(IOwnable(loanContract).owner(), amount);
    }
}