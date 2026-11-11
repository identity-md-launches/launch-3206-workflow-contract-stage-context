// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {PoolKey} from "./interfaces/IVenues.sol";

interface ILpDeskForVault {
    function token() external view returns (address);
    function burner() external view returns (address);
    function operator() external view returns (address);
    function registered() external view returns (bool);
    function registeredPoolKey() external view returns (PoolKey memory);
    function venueV4() external view returns (address);
    function creditFromFirmVault(uint256 amount) external;
}

interface IDeskSwapV4 {
    function swapExactInForVault(PoolKey calldata key, address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut);
}

/// @notice Receives the launch pool's 1% fee cut (IMD and NOTSTOCK) by plain transfers from the launch
/// factory once the project wallet made it the pool fee recipient. Anyone calls distribute(token);
/// only LpDesk's operator calls buyback(amount, minOut). No owner, no pause, no other withdrawal path.
contract FirmVault {
    address public constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable projectWallet;
    ILpDeskForVault public immutable lpDesk_;

    /// @notice IMD reserved for buybacks: 25% of each distribute(IMD) plus LpDesk's 25% buyback share.
    uint256 public buybackBucket;

    event Distributed(address indexed token, uint256 amount);
    event Credited(uint256 amount);
    event Buyback(uint256 amountIn, uint256 notstockOut);

    error NotRegistered();
    error UnsupportedToken();
    error NotLpDesk();
    error NotOperator();
    error AboveBucket();
    error TransferFailed();
    error CreditExceedsBalance();
    error NoSwapModule();

    constructor(address projectWallet_, address lpDeskAddress) {
        projectWallet = projectWallet_;
        lpDesk_ = ILpDeskForVault(lpDeskAddress);
    }

    function lpDesk() external view returns (address) {
        return address(lpDesk_);
    }

    /// @notice IMD FirmVault holds that is not in the buyback bucket (clamped at zero).
    function undistributed(address token) public view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (token != IMD) return balance;
        return balance > buybackBucket ? balance - buybackBucket : 0;
    }

    /// @notice Splits the whole undistributed balance of `token`. IMD: 25% buyback bucket, 25% project
    /// wallet, 25% LpDesk top-up basket of IMD, 25% LpDesk free IMD. NOTSTOCK: 100% to Burner.
    function distribute(address token) external {
        if (!lpDesk_.registered()) revert NotRegistered();
        address notstock = lpDesk_.token();
        if (token == notstock) {
            uint256 amount = IERC20(token).balanceOf(address(this));
            if (amount > 0) _send(token, lpDesk_.burner(), amount);
            emit Distributed(token, amount);
            return;
        }
        if (token != IMD) revert UnsupportedToken();
        uint256 total = undistributed(IMD);
        if (total == 0) {
            emit Distributed(IMD, 0);
            return;
        }
        uint256 quarter = total / 4;
        uint256 toLpDesk = total - 2 * quarter; // 25% top-up + 25% free, rounding dust included
        buybackBucket += quarter;
        _send(IMD, projectWallet, quarter);
        uint256 before = IERC20(IMD).balanceOf(address(lpDesk_));
        _send(IMD, address(lpDesk_), toLpDesk);
        uint256 received = IERC20(IMD).balanceOf(address(lpDesk_)) - before;
        lpDesk_.creditFromFirmVault(received);
        emit Distributed(IMD, total);
    }

    /// @notice LpDesk credits the IMD it just transferred as its 25% buyback share: 100% to the bucket.
    function creditFromLpDesk(uint256 amount) external {
        if (msg.sender != address(lpDesk_)) revert NotLpDesk();
        if (buybackBucket + amount > IERC20(IMD).balanceOf(address(this))) revert CreditExceedsBalance();
        buybackBucket += amount;
        emit Credited(amount);
    }

    /// @notice Swaps `amount` IMD of the buyback bucket for NOTSTOCK in the registered NOTSTOCK/IMD pool
    /// (exact input, pool fee taken by the swap) and sends every NOTSTOCK received to the dead address.
    /// minOut is the operator's manual slippage bound; no other price check exists.
    function buyback(uint256 amount, uint256 minOut) external {
        if (msg.sender != lpDesk_.operator()) revert NotOperator();
        if (!lpDesk_.registered()) revert NotRegistered();
        if (amount > buybackBucket) revert AboveBucket();
        address swapModule = lpDesk_.venueV4();
        if (swapModule.code.length == 0) revert NoSwapModule();
        buybackBucket -= amount;
        _send(IMD, swapModule, amount);
        uint256 out =
            IDeskSwapV4(swapModule).swapExactInForVault(lpDesk_.registeredPoolKey(), IMD, amount, minOut, DEAD);
        emit Buyback(amount, out);
    }

    function _send(address token, address to, uint256 amount) internal {
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
    }
}
