// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DumpSwap - Batch Token Swapper
/// @author Sacha Dujardin
/// @notice Allows users to swap multiple ERC20 tokens to a single destination token in one transaction
/// @dev Uses 1inch router for optimal swap routes
contract DumpSwap is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========== STATE VARIABLES ==========

    /// @notice Contract version
    string public constant VERSION = "1.0.0";

    /// @notice Fee percentage in basis points (10 = 0.1%)
    uint256 public feePercent = 10;

    /// @notice Maximum fee allowed (100 = 1%)
    uint256 public constant MAX_FEE = 100;

    /// @notice Address that receives collected fees
    address public feeRecipient;

    /// @notice Maximum number of tokens that can be swapped in a single transaction
    /// @dev Prevents DoS attacks and ensures reasonable gas costs
    uint256 public constant MAX_TOKENS = 50;

    // ========== EVENTS ==========

    /// @notice Emitted when a batch swap is successfully executed
    /// @param user The address that initiated the swap
    /// @param tokensCount Number of tokens swapped
    /// @param destinationToken The token received
    /// @param totalAmountOut Total amount of destination token received (before fees)
    event BatchSwapExecuted(
        address indexed user,
        uint256 tokensCount,
        address destinationToken,
        uint256 totalAmountOut
    );

    /// @notice Emitted for each individual token swapped
    /// @param user The address that initiated the swap
    /// @param tokenIn The source token
    /// @param amountIn Amount of source token
    /// @param amountOut Amount of destination token received for this swap
    event TokenSwapped(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Emitted when tokens are rescued by owner
    /// @param token The rescued token
    /// @param to Destination address
    /// @param amount Amount rescued
    event TokensRescued(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    /// @notice Emitted when protocol fees are collected
    /// @param user The user who paid the fee
    /// @param amount The fee amount collected
    event FeeCollected(
        address indexed user,
        uint256 amount
    );

    // ========== ERRORS ==========

    /// @notice Thrown when array lengths don't match or are invalid
    error LengthMismatch();

    /// @notice Thrown when a swap fails
    /// @param index The index of the failed token
    error SwapFailed(uint256 index);

    /// @notice Thrown when slippage is too high
    /// @param amountOut The amount received
    /// @param minAmountOut The minimum amount expected
    error SlippageTooHigh(uint256 amountOut, uint256 minAmountOut);

    /// @notice Thrown when there are no tokens to rescue
    error NoTokensToRescue();

    /// @notice Thrown when destination token is invalid
    error InvalidDestination();

    /// @notice Thrown when token or amount is invalid
    /// @param index The index of the invalid token
    error InvalidTokenOrAmount(uint256 index);

    /// @notice Thrown when fee is set too high
    /// @param newFee The attempted fee
    /// @param maxFee The maximum allowed fee
    error FeeTooHigh(uint256 newFee, uint256 maxFee);

    /// @notice Thrown when router is invalid
    error InvalidRouter();

    // ========== CONSTRUCTOR ==========

    /// @notice Initialize the contract
    /// @param initialOwner The address that will own the contract
    constructor(address initialOwner) Ownable(initialOwner) {
        feeRecipient = initialOwner;
    }

    // ========== MAIN FUNCTIONS ==========

    /// @notice Batch swap multiple tokens to a destination token in one transaction
    /// @dev Requires prior approval of each token for this contract
    /// @param tokens Array of token addresses to swap from
    /// @param amounts Array of amounts to swap for each token
    /// @param calldatas Array of encoded 1inch swap data for each token
    /// @param destinationToken The ERC20 token to receive
    /// @param minAmountOut Minimum total amount of destination token expected (slippage protection)
    /// @custom:security Protected by ReentrancyGuard
    /// @custom:security Pausable by owner in case of emergency
    function batchSwap(
        address router,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes[] calldata calldatas,
        address destinationToken,
        uint256 minAmountOut
    ) external nonReentrant whenNotPaused {
        if (tokens.length != amounts.length || amounts.length != calldatas.length) {
            revert LengthMismatch();
        }

        if (tokens.length == 0 || tokens.length > MAX_TOKENS) {
            revert LengthMismatch();
        }

        if (destinationToken == address(0)) {
            revert InvalidDestination();
        }

        if (router == address(0)) {
            revert InvalidRouter();
        }

        uint256 length = tokens.length;
        for (uint256 i = 0; i < length;) {
            if (tokens[i] == address(0) || amounts[i] == 0) {
                revert InvalidTokenOrAmount(i);
            }

            uint256 balanceBefore = IERC20(destinationToken).balanceOf(address(this));

            IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            IERC20(tokens[i]).forceApprove(router, type(uint256).max);
            (bool success, ) = router.call(calldatas[i]);
            if (!success) {
                revert SwapFailed(i);
            }

            uint256 balanceAfter = IERC20(destinationToken).balanceOf(address(this));
            uint256 amountOut = balanceAfter - balanceBefore;
            emit TokenSwapped(msg.sender, tokens[i], amounts[i], amountOut);

            unchecked { ++i; }
        }

        uint256 totalAmountOut = IERC20(destinationToken).balanceOf(address(this));
        if (totalAmountOut < minAmountOut) {
            revert SlippageTooHigh(totalAmountOut, minAmountOut);
        }

        uint256 fee = (totalAmountOut * feePercent) / 10000;
        uint256 amountAfterFee = totalAmountOut - fee;

        if (fee > 0) {
            IERC20(destinationToken).safeTransfer(feeRecipient, fee);
            emit FeeCollected(msg.sender, fee);
        }

        IERC20(destinationToken).safeTransfer(msg.sender, amountAfterFee);
        emit BatchSwapExecuted(msg.sender, tokens.length, destinationToken, amountAfterFee);
    }

    // ========== ADMIN FUNCTIONS ==========

    /// @notice Rescue tokens stuck in the contract
    /// @dev Only callable by owner. Used for emergency recovery.
    /// @param token The token address to rescue
    /// @param to The address to send rescued tokens to
    function rescueTokens(address token, address to) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) {
            revert NoTokensToRescue();
        }
        IERC20(token).safeTransfer(to, balance);

        emit TokensRescued(token, to, balance);
    }

    /// @notice Pause the contract (disables batchSwap)
    /// @dev Only callable by owner
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    /// @dev Only callable by owner
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Set the protocol fee percentage
    /// @dev Fee is in basis points (10 = 0.1%, 100 = 1%)
    /// @param newFee The new fee percentage (must be <= MAX_FEE)
    function setFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_FEE) {
            revert FeeTooHigh(newFee, MAX_FEE);
        }
        feePercent = newFee;
    }

    /// @notice Set the fee recipient address
    /// @param newRecipient The new fee recipient address
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) {
            revert InvalidDestination();
        }
        feeRecipient = newRecipient;
    }
}
