// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;

import "../interfaces/GPv2EIP1271.sol";

contract StateChangingEIP1271 {
    uint256 public state = 0;

    function isValidSignature(bytes32 _hash, bytes memory _signature)
        public
        returns (bytes4 magicValue)
    {
        state += 1;
        magicValue = GPv2EIP1271.MAGICVALUE;
        _hash;
        _signature;
    }
}
