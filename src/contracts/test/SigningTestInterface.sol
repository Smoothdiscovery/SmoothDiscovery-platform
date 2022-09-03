// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "../libraries/Order.sol";
import "../libraries/Trade.sol";
import "../mixins/Signing.sol";

contract SigningTestInterface is Signing {
    function recoverOrderFromTradeTest(
        IERC20[] calldata tokens,
        Trade.Data calldata trade
    ) external view returns (RecoveredOrder memory recoveredOrder) {
        recoveredOrder = allocateRecoveredOrder();
        recoverOrderFromTrade(recoveredOrder, tokens, trade);
    }

    function recoverOrderSignerTest(
        Order.Data memory order,
        Signing.Scheme signingScheme,
        bytes calldata signature
    ) external view returns (address owner) {
        (, owner) = recoverOrderSigner(order, signingScheme, signature);
    }
}
