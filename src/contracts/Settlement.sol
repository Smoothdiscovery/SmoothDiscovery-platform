// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "./VaultRelayer.sol";
import "./interfaces/Authentication.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IVault.sol";
import "./libraries/Interaction.sol";
import "./libraries/Order.sol";
import "./libraries/Trade.sol";
import "./libraries/Transfer.sol";
import "./libraries/SafeCast.sol";
import "./libraries/SafeMath.sol";
import "./mixins/Signing.sol";
import "./mixins/ReentrancyGuard.sol";
import "./mixins/StorageAccessible.sol";


contract Settlement is Signing, ReentrancyGuard, StorageAccessible {
    using Order for bytes;
    using Transfer for IVault;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeMath for uint256;

    
    Authentication public immutable authenticator;

    IVault public immutable vault;

    VaultRelayer public immutable vaultRelayer;

    mapping(bytes => uint256) public filledAmount;

    event Trade(
        address indexed owner,
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 feeAmount,
        bytes orderUid
    );

    event Interaction(address indexed target, uint256 value, bytes4 selector);

    event Settlement(address indexed solver);

    event OrderInvalidated(address indexed owner, bytes orderUid);

    constructor(Authentication authenticator_, IVault vault_) {
        authenticator = authenticator_;
        vault = vault_;
        vaultRelayer = new VaultRelayer(vault_);
    }

    // solhint-disable-next-line no-empty-blocks
    receive() external payable {
        // NOTE: Include an empty receive function so that the settlement
        // contract can receive Ether from contract interactions.
    }

    /// @dev This modifier is called by settle function to block any non-listed
    /// senders from settling batches.
    modifier onlySolver() {
        require(authenticator.isSolver(msg.sender), "address: not a solver");
        _;
    }

    /// @dev Modifier to ensure that an external function is only callable as a
    /// settlement interaction.
    modifier onlyInteraction() {
        require(address(this) == msg.sender, "address: not an interaction");
        _;
    }

   
    function settle(
        IERC20[] calldata tokens,
        uint256[] calldata clearingPrices,
        Trade.Data[] calldata trades,
        Interaction.Data[][3] calldata interactions
    ) external nonReentrant onlySolver {
        executeInteractions(interactions[0]);

        (
            Transfer.Data[] memory inTransfers,
            Transfer.Data[] memory outTransfers
        ) = computeTradeExecutions(tokens, clearingPrices, trades);

        vaultRelayer.transferFromAccounts(inTransfers);

        executeInteractions(interactions[1]);

        vault.transferToAccounts(outTransfers);

        executeInteractions(interactions[2]);

        emit Settlement(msg.sender);
    }

    /// @dev Settle an order directly against Balancer V2 pools.
    ///
    /// @param swaps The Balancer V2 swap steps to use for trading.
    /// @param tokens An array of ERC20 tokens to be traded in the settlement.
    /// Swaps and the trade encode tokens as indices into this array.
    /// @param trade The trade to match directly against Balancer liquidity. The
    /// order will always be fully executed, so the trade's `executedAmount`
    /// field is used to represent a swap limit amount.
    function swap(
        IVault.BatchSwapStep[] calldata swaps,
        IERC20[] calldata tokens,
        Trade.Data calldata trade
    ) external nonReentrant onlySolver {
        RecoveredOrder memory recoveredOrder = allocateRecoveredOrder();
        Order.Data memory order = recoveredOrder.data;
        recoverOrderFromTrade(recoveredOrder, tokens, trade);

        IVault.SwapKind kind = order.kind == Order.KIND_SELL
            ? IVault.SwapKind.GIVEN_IN
            : IVault.SwapKind.GIVEN_OUT;

        IVault.FundManagement memory funds;
        funds.sender = recoveredOrder.owner;
        funds.fromInternalBalance =
            order.sellTokenBalance == Order.BALANCE_INTERNAL;
        funds.recipient = payable(recoveredOrder.receiver);
        funds.toInternalBalance =
            order.buyTokenBalance == Order.BALANCE_INTERNAL;

        int256[] memory limits = new int256[](tokens.length);
        uint256 limitAmount = trade.executedAmount;
        // NOTE: Array allocation initializes elements to 0, so we only need to
        // set the limits we care about. This ensures that the swap will respect
        // the order's limit price.
        if (order.kind == Order.KIND_SELL) {
            require(limitAmount >= order.buyAmount, "address: limit too low");
            limits[trade.sellTokenIndex] = order.sellAmount.toInt256();
            limits[trade.buyTokenIndex] = -limitAmount.toInt256();
        } else {
            require(limitAmount <= order.sellAmount, "address: limit too high");
            limits[trade.sellTokenIndex] = limitAmount.toInt256();
            limits[trade.buyTokenIndex] = -order.buyAmount.toInt256();
        }

        Transfer.Data memory feeTransfer;
        feeTransfer.account = recoveredOrder.owner;
        feeTransfer.token = order.sellToken;
        feeTransfer.amount = order.feeAmount;
        feeTransfer.balance = order.sellTokenBalance;

        int256[] memory tokenDeltas = vaultRelayer.batchSwapWithFee(
            kind,
            swaps,
            tokens,
            funds,
            limits,
            // NOTE: Specify a deadline to ensure that an expire order
            // cannot be used to trade.
            order.validTo,
            feeTransfer
        );

        bytes memory orderUid = recoveredOrder.uid;
        uint256 executedSellAmount = tokenDeltas[trade.sellTokenIndex]
            .toUint256();
        uint256 executedBuyAmount = (-tokenDeltas[trade.buyTokenIndex])
            .toUint256();

        // NOTE: Check that the orders were completely filled and update their
        // filled amounts to avoid replaying them. The limit price and order
        // validity have already been verified when executing the swap through
        // the `limit` and `deadline` parameters.
        require(filledAmount[orderUid] == 0, "address: order filled");
        if (order.kind == Order.KIND_SELL) {
            require(
                executedSellAmount == order.sellAmount,
                "address: sell amount not respected"
            );
            filledAmount[orderUid] = order.sellAmount;
        } else {
            require(
                executedBuyAmount == order.buyAmount,
                "address: buy amount not respected"
            );
            filledAmount[orderUid] = order.buyAmount;
        }

        emit Trade(
            recoveredOrder.owner,
            order.sellToken,
            order.buyToken,
            executedSellAmount,
            executedBuyAmount,
            order.feeAmount,
            orderUid
        );
        emit Settlement(msg.sender);
    }

    /// @dev Invalidate onchain an order that has been signed offline.
    ///
    /// @param orderUid The unique identifier of the order that is to be made
    /// invalid after calling this function. The user that created the order
    /// must be the the sender of this message. See [`extractOrderUidParams`]
    /// for details on orderUid.
    function invalidateOrder(bytes calldata orderUid) external {
        (, address owner, ) = orderUid.extractOrderUidParams();
        require(owner == msg.sender, "address: caller does not own order");
        filledAmount[orderUid] = uint256(-1);
        emit OrderInvalidated(owner, orderUid);
    }

    /// @dev Free storage from the filled amounts of **expired** orders to claim
    /// a gas refund. This method can only be called as an interaction.
    ///
    /// @param orderUids The unique identifiers of the expired order to free
    /// storage for.
    function freeFilledAmountStorage(bytes[] calldata orderUids)
        external
        onlyInteraction
    {
        freeOrderStorage(filledAmount, orderUids);
    }

    /// @dev Free storage from the pre signatures of **expired** orders to claim
    /// a gas refund. This method can only be called as an interaction.
    ///
    /// @param orderUids The unique identifiers of the expired order to free
    /// storage for.
    function freePreSignatureStorage(bytes[] calldata orderUids)
        external
        onlyInteraction
    {
        freeOrderStorage(preSignature, orderUids);
    }

    /// @dev Process all trades one at a time returning the computed net in and
    /// out transfers for the trades.
    ///
    /// This method reverts if processing of any single trade fails. See
    /// [`computeTradeExecution`] for more details.
    ///
    /// @param tokens An array of ERC20 tokens to be traded in the settlement.
    /// @param clearingPrices An array of token clearing prices.
    /// @param trades Trades for signed orders.
    /// @return inTransfers Array of in transfers of executed sell amounts.
    /// @return outTransfers Array of out transfers of executed buy amounts.
    function computeTradeExecutions(
        IERC20[] calldata tokens,
        uint256[] calldata clearingPrices,
        Trade.Data[] calldata trades
    )
        internal
        returns (
            Transfer.Data[] memory inTransfers,
            Transfer.Data[] memory outTransfers
        )
    {
        RecoveredOrder memory recoveredOrder = allocateRecoveredOrder();

        inTransfers = new Transfer.Data[](trades.length);
        outTransfers = new Transfer.Data[](trades.length);

        for (uint256 i = 0; i < trades.length; i++) {
            Trade.Data calldata trade = trades[i];

            recoverOrderFromTrade(recoveredOrder, tokens, trade);
            computeTradeExecution(
                recoveredOrder,
                clearingPrices[trade.sellTokenIndex],
                clearingPrices[trade.buyTokenIndex],
                trade.executedAmount,
                inTransfers[i],
                outTransfers[i]
            );
        }
    }

    /// @dev Compute the in and out transfer amounts for a single trade.
    /// This function reverts if:
    /// - The order has expired
    /// - The order's limit price is not respected
    /// - The order gets over-filled
    /// - The fee discount is larger than the executed fee
    ///
    /// @param recoveredOrder The recovered order to process.
    /// @param sellPrice The price of the order's sell token.
    /// @param buyPrice The price of the order's buy token.
    /// @param executedAmount The portion of the order to execute. This will be
    /// ignored for fill-or-kill orders.
    /// @param inTransfer Memory location for computed executed sell amount
    /// transfer.
    /// @param outTransfer Memory location for computed executed buy amount
    /// transfer.
    function computeTradeExecution(
        RecoveredOrder memory recoveredOrder,
        uint256 sellPrice,
        uint256 buyPrice,
        uint256 executedAmount,
        Transfer.Data memory inTransfer,
        Transfer.Data memory outTransfer
    ) internal {
        Order.Data memory order = recoveredOrder.data;
        bytes memory orderUid = recoveredOrder.uid;

        // solhint-disable-next-line not-rely-on-time
        require(order.validTo >= block.timestamp, "address: order expired");

        // NOTE: The following computation is derived from the equation:
        // ```
        // amount_x * price_x = amount_y * price_y
        // ```
        // Intuitively, if a chocolate bar is 0,50€ and a beer is 4€, 1 beer
        // is roughly worth 8 chocolate bars (`1 * 4 = 8 * 0.5`). From this
        // equation, we can derive:
        // - The limit price for selling `x` and buying `y` is respected iff
        // ```
        // limit_x * price_x >= limit_y * price_y
        // ```
        // - The executed amount of token `y` given some amount of `x` and
        //   clearing prices is:
        // ```
        // amount_y = amount_x * price_x / price_y
        // ```

        require(
            order.sellAmount.mul(sellPrice) >= order.buyAmount.mul(buyPrice),
            "address: limit price not respected"
        );

        uint256 executedSellAmount;
        uint256 executedBuyAmount;
        uint256 executedFeeAmount;
        uint256 currentFilledAmount;

        if (order.kind == Order.KIND_SELL) {
            if (order.partiallyFillable) {
                executedSellAmount = executedAmount;
                executedFeeAmount = order.feeAmount.mul(executedSellAmount).div(
                        order.sellAmount
                    );
            } else {
                executedSellAmount = order.sellAmount;
                executedFeeAmount = order.feeAmount;
            }

            executedBuyAmount = executedSellAmount.mul(sellPrice).ceilDiv(
                buyPrice
            );

            currentFilledAmount = filledAmount[orderUid].add(
                executedSellAmount
            );
            require(
                currentFilledAmount <= order.sellAmount,
                "address: order filled"
            );
        } else {
            if (order.partiallyFillable) {
                executedBuyAmount = executedAmount;
                executedFeeAmount = order.feeAmount.mul(executedBuyAmount).div(
                    order.buyAmount
                );
            } else {
                executedBuyAmount = order.buyAmount;
                executedFeeAmount = order.feeAmount;
            }

            executedSellAmount = executedBuyAmount.mul(buyPrice).div(sellPrice);

            currentFilledAmount = filledAmount[orderUid].add(executedBuyAmount);
            require(
                currentFilledAmount <= order.buyAmount,
                "address: order filled"
            );
        }

        executedSellAmount = executedSellAmount.add(executedFeeAmount);
        filledAmount[orderUid] = currentFilledAmount;

        emit Trade(
            recoveredOrder.owner,
            order.sellToken,
            order.buyToken,
            executedSellAmount,
            executedBuyAmount,
            executedFeeAmount,
            orderUid
        );

        inTransfer.account = recoveredOrder.owner;
        inTransfer.token = order.sellToken;
        inTransfer.amount = executedSellAmount;
        inTransfer.balance = order.sellTokenBalance;

        outTransfer.account = recoveredOrder.receiver;
        outTransfer.token = order.buyToken;
        outTransfer.amount = executedBuyAmount;
        outTransfer.balance = order.buyTokenBalance;
    }

    /// @dev Execute a list of arbitrary contract calls from this contract.
    /// @param interactions The list of interactions to execute.
    function executeInteractions(Interaction.Data[] calldata interactions)
        internal
    {
        for (uint256 i; i < interactions.length; i++) {
            Interaction.Data calldata interaction = interactions[i];

            // To prevent possible attack on user funds, we explicitly disable
            // any interactions with the vault relayer contract.
            require(
                interaction.target != address(vaultRelayer),
                "address: forbidden interaction"
            );
            Interaction.execute(interaction);

            emit Interaction(
                interaction.target,
                interaction.value,
                Interaction.selector(interaction)
            );
        }
    }

    /// @dev Claims refund for the specified storage and order UIDs.
    ///
    /// This method reverts if any of the orders are still valid.
    ///
    /// @param orderUids Order refund data for freeing storage.
    /// @param orderStorage Order storage mapped on a UID.
    function freeOrderStorage(
        mapping(bytes => uint256) storage orderStorage,
        bytes[] calldata orderUids
    ) internal {
        for (uint256 i = 0; i < orderUids.length; i++) {
            bytes calldata orderUid = orderUids[i];

            (, , uint32 validTo) = orderUid.extractOrderUidParams();
            // solhint-disable-next-line not-rely-on-time
            require(validTo < block.timestamp, "address: order still valid");

            orderStorage[orderUid] = 0;
        }
    }
}
