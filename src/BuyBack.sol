// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IGovernance} from "./interfaces/IGovernance.sol";
import {IInitiative} from "./interfaces/IInitiative.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";
import {Actions} from "./utils/Actions.sol";
import {Commands} from "./utils/Commands.sol";

contract BuyBack is Ownable, IInitiative {
    using SafeERC20 for IERC20;

    IUniversalRouter public immutable router;
    IGovernance public immutable governance;
    IPermit2 public immutable permit2;
    IERC20 public constant USDFI = IERC20(0xa0ED3359902EfF692e5b8167038133a73D641909);
    IERC20 public constant DEFI = IERC20(0x0883eA1df0E3a5630Be9aEdad4F2C1E2d0182593);

    event BuyBackExecuted(PoolKey key, uint128 amountIn, uint256 amountOut);

    constructor(address _router, address _governance, address _permit2) Ownable(msg.sender) {
        router = IUniversalRouter(_router);
        governance = IGovernance(_governance);
        permit2 = IPermit2(_permit2);

        IERC20(USDFI).approve(address(permit2), type(uint256).max);
    }

    modifier onlyGovernance() {
        require(msg.sender == address(governance), "BuyBack: invalid-sender");
        _;
    }

    /// @inheritdoc IInitiative
    function onRegisterInitiative(uint256 _atEpoch) external override {}

    /// @inheritdoc IInitiative
    function onUnregisterInitiative(uint256 _atEpoch) external override {}

    /// @inheritdoc IInitiative
    function onAfterAllocateLQTY(
        uint256 _currentEpoch,
        address _user,
        IGovernance.UserState calldata _userState,
        IGovernance.Allocation calldata _allocation,
        IGovernance.InitiativeState calldata _initiativeState
    ) external override {}

    /// @inheritdoc IInitiative
    function onClaimForInitiative(uint256 _claimEpoch, uint256 _bold) external override onlyGovernance {}

    /**
     * @notice Claim rewards for the initiative
     * @return claimed The amount of USDFI claimed for the initiative
     */
    function claimRewards() external onlyOwner returns (uint256) {
        return governance.claimForInitiative(address(this));
    }

    /**
     * @notice Buy back DEFI using USDFI
     * @param key The pool key for the DEFI/USDFI pool
     * @param amountIn The amount of USDFI to spend
     * @param minAmountOut The minimum amount of DEFI to receive
     * @param claim Whether to claim rewards for the initiative
     * @return amountOut The amount of DEFI received
     */
    function buyBack(PoolKey calldata key, uint128 amountIn, uint128 minAmountOut, bool claim)
        external
        onlyOwner
        returns (uint256)
    {
        if (claim) {
            governance.claimForInitiative(address(this));
        }

        require(key.currency0 == Currency.wrap(address(DEFI)), "BuyBack: invalid currency0");
        require(key.currency1 == Currency.wrap(address(USDFI)), "BuyBack: invalid currency1");

        uint256 amount = USDFI.balanceOf(address(this));
        require(amount >= amountIn, "BuyBack: insufficient USDFI balance");

        uint256 amountOut = _swapExactInputSingle(key, amountIn, minAmountOut);

        emit BuyBackExecuted(key, amountIn, amountOut);

        return amountOut;
    }

    /**
     * @notice Withdraw DEFI tokens from the contract
     */
    function withdrawDefi() external onlyOwner {
        uint256 balance = DEFI.balanceOf(address(this));
        DEFI.safeTransfer(msg.sender, balance);
    }

    /**
     * @dev Swap exact input for DEFI using USDFI
     * @param key The pool key for the DEFI/USDFI pool
     * @param amountIn The amount of USDFI to spend
     * @param minAmountOut The minimum amount of DEFI to receive
     * @return amountOut The amount of DEFI received
     */
    function _swapExactInputSingle(PoolKey calldata key, uint128 amountIn, uint128 minAmountOut)
        internal
        returns (uint256 amountOut)
    {
        // Approve the router to spend USDFI.
        permit2.approve(address(USDFI), address(router), amountIn, 0);

        // Encode the Universal Router command.
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions.
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // Prepare parameters for each action.
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency1, amountIn);
        params[2] = abi.encode(key.currency0, minAmountOut);

        // Combine actions and params into inputs.
        inputs[0] = abi.encode(actions, params);

        // Execute the swap.
        uint256 deadline = block.timestamp + 20;
        router.execute(commands, inputs, deadline);

        // Verify and return the output amount.
        amountOut = key.currency0.balanceOf(address(this));
        require(amountOut >= minAmountOut, "Insufficient output amount");
        return amountOut;
    }
}
