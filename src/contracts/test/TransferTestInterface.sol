// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "../libraries/Transfer.sol";

contract TransferTestInterface {
    function fastTransferFromAccountTest(
        IVault vault,
        Transfer.Data calldata transfer,
        address recipient
    ) external {
        Transfer.fastTransferFromAccount(vault, transfer, recipient);
    }

    function transferFromAccountsTest(
        IVault vault,
        Transfer.Data[] calldata transfers,
        address recipient
    ) external {
        Transfer.transferFromAccounts(vault, transfers, recipient);
    }

    receive() external payable {}
}
