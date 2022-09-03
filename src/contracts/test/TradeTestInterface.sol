// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "../libraries/Order.sol";
import "../libraries/Trade.sol";

contract TradeTestInterface {
    function extractOrderTest(
        IERC20[] calldata tokens,
        Trade.Data calldata trade
    ) external pure returns (Order.Data memory order) {
        Trade.extractOrder(trade, tokens, order);
    }

    function extractFlagsTest(uint256 flags)
        external
        pure
        returns (
            bytes32 kind,
            bool partiallyFillable,
            bytes32 sellTokenBalance,
            bytes32 buyTokenBalance,
            Signing.Scheme signingScheme
        )
    {
        return Trade.extractFlags(flags);
    }
}
