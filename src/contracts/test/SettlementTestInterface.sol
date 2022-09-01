// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "../Settlement.sol";
import "../libraries/Interaction.sol";
import "../libraries/Trade.sol";
import "../libraries/Transfer.sol";

contract SettlementTestInterface is Settlement {
    constructor(Authentication authenticator_, IVault vault)
        Settlement(authenticator_, vault)
    {

    }

    function setFilledAmount(bytes calldata orderUid, uint256 amount) external {
        filledAmount[orderUid] = amount;
    }
}
