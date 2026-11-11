// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IOFT} from "../../src/interfaces/IVenues.sol";

/// @dev A LayerZero OFT adapter stand-in: send() pulls amountLD from the caller and records the message.
contract MockOFT {
    address public immutable token;
    uint32 public lastDstEid;
    bytes32 public lastTo;
    uint256 public lastAmount;
    uint256 public lastFee;
    address public lastRefund;

    constructor(address token_) {
        token = token_;
    }

    function send(IOFT.SendParam calldata p, IOFT.MessagingFee calldata fee, address refund) external payable {
        require(msg.value == fee.nativeFee, "fee");
        require(IERC20(token).transferFrom(msg.sender, address(this), p.amountLD), "pull");
        lastDstEid = p.dstEid;
        lastTo = p.to;
        lastAmount = p.amountLD;
        lastFee = msg.value;
        lastRefund = refund;
    }
}
