// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;


interface Authentication {
  
    function isSolver(address prospectiveSolver) external view returns (bool);
}
