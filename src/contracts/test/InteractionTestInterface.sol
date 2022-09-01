// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "../libraries/Interaction.sol";

contract InteractionTestInterface {
    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

    function executeTest(Interaction.Data calldata interaction) external {
        Interaction.execute(interaction);
    }
}
