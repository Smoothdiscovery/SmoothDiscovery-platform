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
    
    function computeTradeExecutionsTest(
        IERC20[] calldata tokens,
        uint256[] calldata clearingPrices,
        Trade.Data[] calldata trades
    )
        external
        returns (
            Transfer.Data[] memory inTransfers,
            Transfer.Data[] memory outTransfers
        )
    {
        (inTransfers, outTransfers) = computeTradeExecutions(
            tokens,
            clearingPrices,
            trades
        );
    }
    function computeTradeExecutionMemoryTest() external returns (uint256 mem) {
        RecoveredOrder memory recoveredOrder;
        Transfer.Data memory inTransfer;
        Transfer.Data memory outTransfer;

        assembly {
            mem := mload(0x40)
        }

        recoveredOrder.data.validTo = uint32(block.timestamp);
        computeTradeExecution(recoveredOrder, 1, 1, 0, inTransfer, outTransfer);

        assembly {
            mem := sub(mload(0x40), mem)
        }
    }
    
    function executeInteractionsTest(
        Interaction.Data[] calldata interactions
    ) external {
        executeInteractions(interactions);
    }

    function freeFilledAmountStorageTest(bytes[] calldata orderUids) external {
        this.freeFilledAmountStorage(orderUids);
    }

    function freePreSignatureStorageTest(bytes[] calldata orderUids) external {
        this.freePreSignatureStorage(orderUids);
    }
}
