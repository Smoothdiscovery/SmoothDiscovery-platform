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

    
}
