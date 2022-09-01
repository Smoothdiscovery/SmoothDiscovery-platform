// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;

import "../AllowListAuthentication.sol";
import "../libraries/EIP1967.sol";

contract AllowListAuthenticationTestInterface is
    AllowListAuthentication
{
    constructor(address owner) {
        EIP1967.setAdmin(owner);
    }
}
