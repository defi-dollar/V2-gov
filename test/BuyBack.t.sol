// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/contracts/interfaces/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

import {BuyBack} from "../src/BuyBack.sol";

// Mock contracts for testing
contract MockGovernance {
    mapping(address => uint256) public claimableAmounts;
    IERC20 public constant USDFI = IERC20(0xa0ED3359902EfF692e5b8167038133a73D641909);

    function setClaimableAmount(address initiative, uint256 amount) external {
        claimableAmounts[initiative] = amount;
    }

    function claimForInitiative(address initiative) external returns (uint256 claimed) {
        uint256 amount = claimableAmounts[initiative];
        if (amount > 0) {
            // Transfer USDFI to the initiative
            USDFI.transfer(initiative, amount);
            claimableAmounts[initiative] = 0;
        }
        return amount;
    }
}

contract BuyBackTest is Test {
    using PoolIdLibrary for PoolKey;

    BuyBack buyBack;
    MockGovernance governance;

    // Token addresses (matching BuyBack contract)
    address constant USDFI = 0xa0ED3359902EfF692e5b8167038133a73D641909;
    address constant DEFI = 0x0883eA1df0E3a5630Be9aEdad4F2C1E2d0182593;

    address constant ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Pool configuration
    PoolKey poolKey = PoolKey({
        currency0: Currency.wrap(DEFI),
        currency1: Currency.wrap(USDFI),
        fee: 3000,
        tickSpacing: 60,
        hooks: IHooks(address(0))
    });

    function setUp() public {
        // Fork mainnet for realistic testing environment
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        // Deploy mock contracts
        governance = new MockGovernance();

        // Deploy BuyBack contract
        buyBack = new BuyBack(ROUTER, address(governance), PERMIT2);
    }

    function test_buyBack_success() public {
        // Execute buyBack
        uint128 amountIn = 1e18;
        uint128 minAmountOut = 0;

        deal(USDFI, address(buyBack), amountIn);

        buyBack.buyBack(poolKey, amountIn, minAmountOut, false);
    }

    function test_buyBack_with_claim() public {
        // Setup governance with claimable amount
        uint256 claimableAmount = 5e18; // 5 USDFI
        governance.setClaimableAmount(address(buyBack), claimableAmount);

        // Give governance some USDFI to transfer
        deal(USDFI, address(governance), claimableAmount);

        uint128 amountIn = 1e18;
        uint128 minAmountOut = 0;

        // Test buyBack with claim=true
        buyBack.buyBack(poolKey, amountIn, minAmountOut, true);

        // Verify that USDFI was claimed
        assertGe(IERC20(USDFI).balanceOf(address(buyBack)), amountIn);
    }

    function test_buyBack_consecutive_calls() public {
        // First buyBack
        uint128 amountIn1 = 1e18;
        deal(USDFI, address(buyBack), amountIn1);

        uint256 defiBalanceBefore = IERC20(DEFI).balanceOf(address(buyBack));
        buyBack.buyBack(poolKey, amountIn1, 0, false);
        uint256 defiBalanceAfter1 = IERC20(DEFI).balanceOf(address(buyBack));

        // Verify first swap worked
        assertGt(defiBalanceAfter1, defiBalanceBefore);

        // Second buyBack
        uint128 amountIn2 = 2e18;
        deal(USDFI, address(buyBack), amountIn2);

        buyBack.buyBack(poolKey, amountIn2, 0, false);
        uint256 defiBalanceAfter2 = IERC20(DEFI).balanceOf(address(buyBack));

        // Verify second swap worked and accumulated DEFI
        assertGt(defiBalanceAfter2, defiBalanceAfter1);
    }

    function test_buyBack_with_minimum_output() public {
        uint128 amountIn = 1e18;
        uint128 minAmountOut = 1e17; // Require at least 0.1 DEFI

        deal(USDFI, address(buyBack), amountIn);

        buyBack.buyBack(poolKey, amountIn, minAmountOut, false);

        // Verify we got at least the minimum amount
        assertGe(IERC20(DEFI).balanceOf(address(buyBack)), minAmountOut);
    }

    function test_buyBack_revert_insufficient_balance() public {
        uint128 amountIn = 1e18;
        uint128 minAmountOut = 0;

        // Don't give any USDFI to the contract

        vm.expectRevert("BuyBack: insufficient USDFI balance");
        buyBack.buyBack(poolKey, amountIn, minAmountOut, false);
    }

    function test_buyBack_revert_invalid_currency0() public {
        uint128 amountIn = 1e18;
        uint128 minAmountOut = 0;

        deal(USDFI, address(buyBack), amountIn);

        // Create pool key with wrong currency0
        PoolKey memory invalidKey = PoolKey({
            currency0: Currency.wrap(USDFI), // Wrong! Should be DEFI
            currency1: Currency.wrap(USDFI),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.expectRevert("BuyBack: invalid currency0");
        buyBack.buyBack(invalidKey, amountIn, minAmountOut, false);
    }

    function test_buyBack_revert_invalid_currency1() public {
        uint128 amountIn = 1e18;
        uint128 minAmountOut = 0;

        deal(USDFI, address(buyBack), amountIn);

        // Create pool key with wrong currency1
        PoolKey memory invalidKey = PoolKey({
            currency0: Currency.wrap(DEFI),
            currency1: Currency.wrap(DEFI), // Wrong! Should be USDFI
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.expectRevert("BuyBack: invalid currency1");
        buyBack.buyBack(invalidKey, amountIn, minAmountOut, false);
    }

    function test_buyBack_revert_only_owner() public {
        uint128 amountIn = 1e18;
        uint128 minAmountOut = 0;

        deal(USDFI, address(buyBack), amountIn);

        // Try to call from non-owner address
        vm.prank(address(0x123));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x123)));
        buyBack.buyBack(poolKey, amountIn, minAmountOut, false);
    }

    function test_withdrawDefi_success() public {
        // Give the contract some DEFI tokens
        uint256 defiAmount = 5e18;
        deal(DEFI, address(buyBack), defiAmount);

        uint256 ownerBalanceBefore = IERC20(DEFI).balanceOf(address(this));

        buyBack.withdrawDefi();

        uint256 ownerBalanceAfter = IERC20(DEFI).balanceOf(address(this));
        uint256 contractBalance = IERC20(DEFI).balanceOf(address(buyBack));

        // Verify DEFI was transferred to owner and contract is empty
        assertEq(ownerBalanceAfter - ownerBalanceBefore, defiAmount);
        assertEq(contractBalance, 0);
    }

    function test_withdrawDefi_revert_only_owner() public {
        // Give the contract some DEFI tokens
        uint256 defiAmount = 5e18;
        deal(DEFI, address(buyBack), defiAmount);

        // Try to call from non-owner address
        vm.prank(address(0x123));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x123)));
        buyBack.withdrawDefi();
    }

    function test_withdrawDefi_when_empty() public {
        // Contract has no DEFI tokens
        uint256 ownerBalanceBefore = IERC20(DEFI).balanceOf(address(this));

        buyBack.withdrawDefi();

        uint256 ownerBalanceAfter = IERC20(DEFI).balanceOf(address(this));

        // Should not revert, but no tokens should be transferred
        assertEq(ownerBalanceAfter, ownerBalanceBefore);
    }

    function test_claimRewards_success() public {
        // Setup governance with claimable amount
        uint256 claimableAmount = 10e18; // 10 USDFI
        governance.setClaimableAmount(address(buyBack), claimableAmount);

        // Give governance some USDFI to transfer
        deal(USDFI, address(governance), claimableAmount);

        uint256 contractBalanceBefore = IERC20(USDFI).balanceOf(address(buyBack));

        // Call claimRewards
        uint256 claimed = buyBack.claimRewards();

        uint256 contractBalanceAfter = IERC20(USDFI).balanceOf(address(buyBack));

        // Verify that USDFI was claimed
        assertEq(claimed, claimableAmount);
        assertEq(contractBalanceAfter - contractBalanceBefore, claimableAmount);
    }

    function test_claimRewards_when_no_rewards() public {
        // Don't set any claimable amount for the contract
        uint256 contractBalanceBefore = IERC20(USDFI).balanceOf(address(buyBack));

        // Call claimRewards
        uint256 claimed = buyBack.claimRewards();

        uint256 contractBalanceAfter = IERC20(USDFI).balanceOf(address(buyBack));

        // Verify that no tokens were claimed
        assertEq(claimed, 0);
        assertEq(contractBalanceAfter, contractBalanceBefore);
    }

    function test_claimRewards_revert_only_owner() public {
        // Setup governance with claimable amount
        uint256 claimableAmount = 10e18; // 10 USDFI
        governance.setClaimableAmount(address(buyBack), claimableAmount);

        // Give governance some USDFI to transfer
        deal(USDFI, address(governance), claimableAmount);

        // Try to call from non-owner address
        vm.prank(address(0x123));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x123)));
        buyBack.claimRewards();
    }

    function test_claimRewards_multiple_calls() public {
        // Setup governance with claimable amount
        uint256 claimableAmount = 5e18; // 5 USDFI per call
        governance.setClaimableAmount(address(buyBack), claimableAmount);

        // Give governance enough USDFI for multiple transfers
        deal(USDFI, address(governance), claimableAmount * 3);

        uint256 contractBalanceBefore = IERC20(USDFI).balanceOf(address(buyBack));

        // First claim
        uint256 claimed1 = buyBack.claimRewards();
        uint256 contractBalanceAfter1 = IERC20(USDFI).balanceOf(address(buyBack));

        // Verify first claim worked
        assertEq(claimed1, claimableAmount);
        assertEq(contractBalanceAfter1 - contractBalanceBefore, claimableAmount);

        // Reset claimable amount for second call
        governance.setClaimableAmount(address(buyBack), claimableAmount);

        // Second claim
        uint256 claimed2 = buyBack.claimRewards();
        uint256 contractBalanceAfter2 = IERC20(USDFI).balanceOf(address(buyBack));

        // Verify second claim worked and accumulated
        assertEq(claimed2, claimableAmount);
        assertEq(contractBalanceAfter2 - contractBalanceBefore, claimableAmount * 2);
    }
}
