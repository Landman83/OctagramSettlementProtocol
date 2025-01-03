// SPDX-License-Identifier: MIT

/*
pragma solidity ^0.8.26;

import "../../tokens/IERC20Token.sol";
import "../../tokens/IEtherToken.sol";
import "../../errors/LibRichErrorsV06.sol";
import "../../utils/LibMathV06.sol";
import "../../errors/LibNativeOrdersRichErrors.sol";
import "../../fixins/FixinCommon.sol";
import "../../libs/LibNativeOrdersStorage.sol";
import "../../interfaces/IStaking.sol";
import "../../interfaces/INativeOrderEvents.sol";
import "../../libs/LibSignature.sol";
import "../../libs/LibNativeOrder.sol";
import "./NativeOrdersCancellation.sol";
import "./NativeOrdersProtocolFees.sol";

abstract contract NativeOrdersSettlement is
    INativeOrdersEvents,
    NativeOrdersCancellation,
    NativeOrdersProtocolFees,
    FixinCommon
{
    using LibRichErrorsV08 for bytes;

    struct SettleOrderInfo {
        bytes32 orderHash;
        address maker;
        address payer;
        address recipient;
        IERC20Token makerToken;
        IERC20Token takerToken;
        uint128 makerAmount;
        uint128 takerAmount;
        uint128 takerTokenFillAmount;
        uint128 takerTokenFilledAmount;
    }

    struct FillLimitOrderPrivateParams {
        LibNativeOrder.LimitOrder order;
        LibSignature.Signature signature;
        uint128 takerTokenFillAmount;
        address taker;
        address sender;
    }

    struct FillNativeOrderResults {
        uint256 ethProtocolFeePaid;
        uint128 takerTokenFilledAmount;
        uint128 makerTokenFilledAmount;
        uint128 takerTokenFeeFilledAmount;
    }

    constructor(
        address zeroExAddress,
        IEtherToken weth,
        IStaking staking,
        FeeCollectorController feeCollectorController,
        uint32 protocolFeeMultiplier
    )
        NativeOrdersCancellation(zeroExAddress)
        NativeOrdersProtocolFees(weth, staking, feeCollectorController, protocolFeeMultiplier)
    {}

    function fillLimitOrder(
        LibNativeOrder.LimitOrder memory order,
        LibSignature.Signature memory signature,
        uint128 takerTokenFillAmount
    ) public payable returns (uint128 takerTokenFilledAmount, uint128 makerTokenFilledAmount) {
        FillNativeOrderResults memory results = _fillLimitOrderPrivate(
            FillLimitOrderPrivateParams({
                order: order,
                signature: signature,
                takerTokenFillAmount: takerTokenFillAmount,
                taker: msg.sender,
                sender: msg.sender
            })
        );
        LibNativeOrder.refundExcessProtocolFeeToSender(results.ethProtocolFeePaid);
        (takerTokenFilledAmount, makerTokenFilledAmount) = (
            results.takerTokenFilledAmount,
            results.makerTokenFilledAmount
        );
    }

    function _fillLimitOrder(
        LibNativeOrder.LimitOrder memory order,
        LibSignature.Signature memory signature,
        uint128 takerTokenFillAmount,
        address taker,
        address sender
    ) public payable virtual onlySelf returns (uint128 takerTokenFilledAmount, uint128 makerTokenFilledAmount) {
        FillNativeOrderResults memory results = _fillLimitOrderPrivate(
            FillLimitOrderPrivateParams(order, signature, takerTokenFillAmount, taker, sender)
        );
        (takerTokenFilledAmount, makerTokenFilledAmount) = (
            results.takerTokenFilledAmount,
            results.makerTokenFilledAmount
        );
    }

    function _fillLimitOrderPrivate(
        FillLimitOrderPrivateParams memory params
    ) private returns (FillNativeOrderResults memory results) {
        LibNativeOrder.OrderInfo memory orderInfo = getLimitOrderInfo(params.order);

        if (orderInfo.status != LibNativeOrder.OrderStatus.FILLABLE) {
            revert LibNativeOrdersRichErrors.OrderNotFillableError(orderInfo.orderHash, uint8(orderInfo.status));
        }

        if (params.order.taker != address(0) && params.order.taker != params.taker) {
            revert LibNativeOrdersRichErrors
                .OrderNotFillableByTakerError(orderInfo.orderHash, params.taker, params.order.taker);
        }

        if (params.order.sender != address(0) && params.order.sender != params.sender) {
            revert LibNativeOrdersRichErrors
                .OrderNotFillableBySenderError(orderInfo.orderHash, params.sender, params.order.sender);
        }

        {
            address signer = LibSignature.getSignerOfHash(orderInfo.orderHash, params.signature);
            if (signer != params.order.maker && !isValidOrderSigner(params.order.maker, signer)) {
                revert LibNativeOrdersRichErrors
                    .OrderNotSignedByMakerError(orderInfo.orderHash, signer, params.order.maker);
            }
        }

        results.ethProtocolFeePaid = _collectProtocolFee(params.order.pool);

        (results.takerTokenFilledAmount, results.makerTokenFilledAmount) = _settleOrder(
            SettleOrderInfo({
                orderHash: orderInfo.orderHash,
                maker: params.order.maker,
                payer: params.taker,
                recipient: params.taker,
                makerToken: IERC20Token(params.order.makerToken),
                takerToken: IERC20Token(params.order.takerToken),
                makerAmount: params.order.makerAmount,
                takerAmount: params.order.takerAmount,
                takerTokenFillAmount: params.takerTokenFillAmount,
                takerTokenFilledAmount: orderInfo.takerTokenFilledAmount
            })
        );

        if (params.order.takerTokenFeeAmount > 0) {
            results.takerTokenFeeFilledAmount = uint128(
                LibMathV06.getPartialAmountFloor(
                    results.takerTokenFilledAmount,
                    params.order.takerAmount,
                    params.order.takerTokenFeeAmount
                )
            );
            _transferERC20TokensFrom(
                params.order.takerToken,
                params.taker,
                params.order.feeRecipient,
                uint256(results.takerTokenFeeFilledAmount)
            );
        }

        emit LimitOrderFilled(
            orderInfo.orderHash,
            params.order.maker,
            params.taker,
            params.order.feeRecipient,
            address(params.order.makerToken),
            address(params.order.takerToken),
            results.takerTokenFilledAmount,
            results.makerTokenFilledAmount,
            results.takerTokenFeeFilledAmount,
            results.ethProtocolFeePaid,
            params.order.pool
        );
    }

    function _settleOrder(
        SettleOrderInfo memory settleInfo
    ) private returns (uint128 takerTokenFilledAmount, uint128 makerTokenFilledAmount) {
        takerTokenFilledAmount = min(
            settleInfo.takerTokenFillAmount,
            settleInfo.takerAmount - settleInfo.takerTokenFilledAmount
        );
        makerTokenFilledAmount = uint128(
            LibMathV06.getPartialAmountFloor(
                uint256(takerTokenFilledAmount),
                uint256(settleInfo.takerAmount),
                uint256(settleInfo.makerAmount)
            )
        );

        if (takerTokenFilledAmount == 0 || makerTokenFilledAmount == 0) {
            return (0, 0);
        }

        LibNativeOrdersStorage.getStorage().orderHashToTakerTokenFilledAmount[settleInfo.orderHash] = settleInfo
            .takerTokenFilledAmount + takerTokenFilledAmount;

        _transferERC20TokensFrom(settleInfo.takerToken, settleInfo.payer, settleInfo.maker, takerTokenFilledAmount);
        _transferERC20TokensFrom(settleInfo.makerToken, settleInfo.maker, settleInfo.recipient, makerTokenFilledAmount);
    }

    function registerAllowedOrderSigner(address signer, bool allowed) external {
        LibNativeOrdersStorage.Storage storage stor = LibNativeOrdersStorage.getStorage();
        stor.orderSignerRegistry[msg.sender][signer] = allowed;
        emit OrderSignerRegistered(msg.sender, signer, allowed);
    }

    function min(uint128 a, uint128 b) private pure returns (uint128) {
        return a < b ? a : b;
    }
}
*/