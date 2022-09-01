// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "../libraries/Order.sol";

contract OrderTestInterface {
    using Order for Order.Data;
    using Order for bytes;

    function typeHashTest() external pure returns (bytes32) {
        return Order.TYPE_HASH;
    }
    
    function hashTest(Order.Data memory order, bytes32 domainSeparator) external pure returns (bytes32 orderDigest) {
        orderDigest = order.hash(domainSeparator);
    }

}
