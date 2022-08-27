// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "./interfaces/IERC20.sol";
import "./interfaces/IVault.sol";
import "./libraries/Transfer.sol";


contract VaultRelayer {
    using Transfer for IVault;

    address private immutable creator;
    IVault private immutable vault;

    constructor(IVault vault_) {
        creator = msg.sender;
        vault = vault_;
    }

    
    modifier onlyCreator() {
        require(msg.sender == creator, "GPv2: not creator");
        _;
    }

   
    function transferFromAccounts(GPv2Transfer.Data[] calldata transfers)
        external
        onlyCreator
    {
        vault.transferFromAccounts(transfers, msg.sender);
    }

}
