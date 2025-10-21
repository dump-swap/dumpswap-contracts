// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DumpSwap {
    address public constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function batchSwap(
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes[] calldata calldatas
    ) external {
        require(tokens.length == amounts.length && amounts.length == calldatas.length, "Length mismatch");

        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).transferFrom(msg.sender, address(this), amounts[i]);
            IERC20(tokens[i]).approve(ONEINCH_ROUTER, amounts[i]);
            (bool success, ) = ONEINCH_ROUTER.call(calldatas[i]);
            require(success);
        }

        IERC20(USDC).transfer(msg.sender, IERC20(USDC).balanceOf(address(this)));
    }
}
