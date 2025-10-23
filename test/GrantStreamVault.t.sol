// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GrantStreamVault.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 token for testing
contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract GrantStreamVaultTest is Test {
    GrantStreamVault public vault;
    MockToken public token;

    address public owner = address(1);
    address public feeRecipient = address(2);
    address public recipient = address(3);
    address public otherRecipient = address(4);

    uint16 constant FEE_BPS = 250; // 2.5%
    uint256 constant GRANT_AMOUNT = 100_000 * 10 ** 18;
    uint32 constant DURATION = 365 days;
    uint32 constant CLIFF = 90 days;

    event GrantCreated(
        address indexed recipient, uint256 totalAmount, uint32 startTime, uint32 duration, uint32 cliffDuration
    );

    event FundsClaimed(address indexed recipient, uint256 claimAmount, uint256 feeAmount, uint256 netAmount);

    event GrantRevoked(address indexed recipient, uint256 vestedUnclaimed, uint256 unvestedReturned);

    function setUp() public {
        // Deploy token and vault
        vm.startPrank(owner);
        token = new MockToken();
        vault = new GrantStreamVault(FEE_BPS, address(token), feeRecipient, owner);
        vm.stopPrank();
    }

    // ============ CORE FLOW TESTS ============

    function test_CreateGrant_Success() public {
        vm.startPrank(owner);

        // Approve and create grant
        token.approve(address(vault), GRANT_AMOUNT);

        uint32 startTime = uint32(block.timestamp);

        vm.expectEmit(true, false, false, true);
        emit GrantCreated(recipient, GRANT_AMOUNT, startTime, DURATION, CLIFF);

        vault.createGrant(recipient, GRANT_AMOUNT, startTime, DURATION, CLIFF);

        // Verify grant was created
        (
            uint128 totalAmount,
            uint128 claimedAmount,
            uint32 _startTime,
            uint32 duration,
            uint32 cliffDuration,
            bool isActive
        ) = vault.grants(recipient);

        assertEq(totalAmount, GRANT_AMOUNT);
        assertEq(claimedAmount, 0);
        assertEq(_startTime, startTime);
        assertEq(duration, DURATION);
        assertEq(cliffDuration, CLIFF);
        assertTrue(isActive);

        // Verify tokens were transferred
        assertEq(token.balanceOf(address(vault)), GRANT_AMOUNT);

        vm.stopPrank();
    }

    function test_VestingCalculation_BeforeCliff() public {
        _createTestGrant();

        // Warp to before cliff
        vm.warp(block.timestamp + 30 days);

        // Should have 0 vested before cliff
        assertEq(vault.vestedAmount(recipient), 0);
        (uint256 feeAmount, uint256 netAmount) = vault.claimableAmount(recipient);
        assertEq(feeAmount, 0);
        assertEq(netAmount, 0);
    }

    function test_VestingCalculation_AfterCliff() public {
        uint32 startTime = uint32(block.timestamp);
        _createTestGrant();

        // Warp to after cliff (180 days = ~50% vested)
        vm.warp(startTime + 180 days);

        uint256 expectedVested = (GRANT_AMOUNT * 180 days) / DURATION;
        uint256 actualVested = vault.vestedAmount(recipient);

        // Allow small rounding difference
        assertApproxEqRel(actualVested, expectedVested, 0.001e18);
    }

    function test_VestingCalculation_FullyVested() public {
        uint32 startTime = uint32(block.timestamp);
        _createTestGrant();

        // Warp past full duration
        vm.warp(startTime + DURATION + 1 days);

        assertEq(vault.vestedAmount(recipient), GRANT_AMOUNT);
    }

    function test_Claim_Success_WithFee() public {
        uint32 startTime = uint32(block.timestamp);
        _createTestGrant();

        // Warp to 50% vested (after cliff)
        vm.warp(startTime + 180 days);

        uint256 vestedAmount = vault.vestedAmount(recipient);
        uint256 expectedFee = (vestedAmount * FEE_BPS) / 10000;
        uint256 expectedNet = vestedAmount - expectedFee;

        vm.startPrank(recipient);

        vm.expectEmit(true, false, false, true);
        emit FundsClaimed(recipient, vestedAmount, expectedFee, expectedNet);

        vault.claim();

        // Verify balances
        assertEq(token.balanceOf(recipient), expectedNet);
        assertEq(token.balanceOf(feeRecipient), expectedFee);

        // Verify claimed amount updated
        (, uint128 claimedAmount,,,,) = vault.grants(recipient);
        assertEq(claimedAmount, vestedAmount);

        vm.stopPrank();
    }

    function test_Claim_MultipleClaims() public {
        uint32 startTime = uint32(block.timestamp);
        _createTestGrant();

        // First claim at 25%
        vm.warp(startTime + 90 days);
        vm.prank(recipient);
        vault.claim();

        uint256 balanceAfterFirst = token.balanceOf(recipient);

        // Second claim at 50%
        vm.warp(startTime + 180 days);
        vm.prank(recipient);
        vault.claim();

        uint256 balanceAfterSecond = token.balanceOf(recipient);

        // Should have received additional tokens
        assertGt(balanceAfterSecond, balanceAfterFirst);

        // Final claim after full vesting
        vm.warp(startTime + DURATION);
        vm.prank(recipient);
        vault.claim();

        // Calculate total expected after fees
        uint256 totalExpectedNet = GRANT_AMOUNT - ((GRANT_AMOUNT * FEE_BPS) / 10000);

        assertApproxEqRel(token.balanceOf(recipient), totalExpectedNet, 0.001e18);
    }

    function test_UpdateGrant_IncreaseAmount() public {
        _createTestGrant();

        uint256 additionalAmount = 50_000 * 10 ** 18;
        uint256 newTotal = GRANT_AMOUNT + additionalAmount;

        vm.startPrank(owner);
        token.approve(address(vault), additionalAmount);

        vault.updateGrant(recipient, newTotal, DURATION, CLIFF);

        (uint128 totalAmount,,,,,) = vault.grants(recipient);
        assertEq(totalAmount, newTotal);

        vm.stopPrank();
    }

    function test_Revert_UpdateGrant_DecreaseDuration() public {
        _createTestGrant();

        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.InvalidDuration.selector);
        vault.updateGrant(recipient, GRANT_AMOUNT, DURATION - 30 days, CLIFF); // ← Decreasing should fail
    }

    function test_UpdateGrant_IncreaseDuration() public {
        _createTestGrant();

        uint32 newDuration = DURATION + 30 days; // Can increase

        vm.prank(owner);
        vault.updateGrant(recipient, GRANT_AMOUNT, newDuration, CLIFF);

        (,,, uint32 duration,,) = vault.grants(recipient);
        assertEq(duration, newDuration);
    }

    function test_RevokeGrant_ReturnsUnvestedFunds() public {
        uint32 startTime = uint32(block.timestamp);
        _createTestGrant();

        // Warp to 50% vested
        vm.warp(startTime + 180 days);

        uint256 vestedAmount = vault.vestedAmount(recipient);
        uint256 unvestedAmount = GRANT_AMOUNT - vestedAmount;

        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit GrantRevoked(recipient, vestedAmount, unvestedAmount);

        vault.revokeGrant(recipient);

        // Verify unvested funds returned
        assertEq(token.balanceOf(owner) - ownerBalanceBefore, unvestedAmount);

        // Verify grant is inactive but recipient can still claim vested
        (uint128 totalAmount,,,,, bool isActive) = vault.grants(recipient);
        assertEq(totalAmount, vestedAmount);
        assertFalse(isActive);

        // Recipient should still be able to claim vested amount
        vm.prank(recipient);
        vault.claim();

        uint256 expectedNet = vestedAmount - ((vestedAmount * FEE_BPS) / 10000);
        assertApproxEqRel(token.balanceOf(recipient), expectedNet, 0.001e18);
    }

    function test_PauseAndUnpause() public {
        _createTestGrant();

        vm.warp(block.timestamp + DURATION); // Fully vested

        // Pause claims
        vm.prank(owner);
        vault.togglePause(true);

        assertTrue(vault.paused());

        // Claim should revert
        vm.prank(recipient);
        vm.expectRevert(GrantStreamVault.ClaimsPaused.selector);
        vault.claim();

        // Unpause
        vm.prank(owner);
        vault.togglePause(false);

        assertFalse(vault.paused());

        // Claim should succeed
        vm.prank(recipient);
        vault.claim();

        assertGt(token.balanceOf(recipient), 0);
    }

    // ============ REVERT TESTS ============

    function testRevert_CreateGrant_ZeroAddress() public {
        vm.startPrank(owner);
        token.approve(address(vault), GRANT_AMOUNT);

        vm.expectRevert(GrantStreamVault.ZeroAddress.selector);
        vault.createGrant(address(0), GRANT_AMOUNT, uint32(block.timestamp), DURATION, CLIFF);

        vm.stopPrank();
    }

    function testRevert_CreateGrant_ZeroAmount() public {
        vm.startPrank(owner);

        vm.expectRevert(GrantStreamVault.InvalidAmount.selector);
        vault.createGrant(recipient, 0, uint32(block.timestamp), DURATION, CLIFF);

        vm.stopPrank();
    }

    function testRevert_CreateGrant_ZeroDuration() public {
        vm.startPrank(owner);
        token.approve(address(vault), GRANT_AMOUNT);

        vm.expectRevert(GrantStreamVault.InvalidDuration.selector);
        vault.createGrant(recipient, GRANT_AMOUNT, uint32(block.timestamp), 0, CLIFF);

        vm.stopPrank();
    }

    function testRevert_CreateGrant_CliffTooLong() public {
        vm.startPrank(owner);
        token.approve(address(vault), GRANT_AMOUNT);

        vm.expectRevert(GrantStreamVault.InvalidCliffDuration.selector);
        vault.createGrant(recipient, GRANT_AMOUNT, uint32(block.timestamp), DURATION, DURATION + 1);

        vm.stopPrank();
    }

    function testRevert_CreateGrant_PastStartTime() public {
        vm.warp(100 days); // ensure timestamp high enough
        vm.startPrank(owner);
        token.approve(address(vault), GRANT_AMOUNT);

        uint32 pastTime = uint32(block.timestamp - 1 days);
        vm.expectRevert(GrantStreamVault.InvalidStartTime.selector);
        vault.createGrant(recipient, GRANT_AMOUNT, pastTime, DURATION, CLIFF);

        vm.stopPrank();
    }

    function testRevert_CreateGrant_InsufficientAllowance() public {
        vm.startPrank(owner);
        // Don't approve tokens

        vm.expectRevert(GrantStreamVault.InsufficientAllowance.selector);
        vault.createGrant(recipient, GRANT_AMOUNT, uint32(block.timestamp), DURATION, CLIFF);

        vm.stopPrank();
    }

    function testRevert_CreateGrant_DuplicateRecipient() public {
        _createTestGrant();

        vm.startPrank(owner);
        token.approve(address(vault), GRANT_AMOUNT);

        vm.expectRevert(GrantStreamVault.RecipientAlreadyHasGrant.selector);
        vault.createGrant(recipient, GRANT_AMOUNT, uint32(block.timestamp), DURATION, CLIFF);

        vm.stopPrank();
    }

    function testRevert_Claim_NoGrant() public {
        vm.prank(otherRecipient);
        vm.expectRevert(GrantStreamVault.GrantNotFound.selector);
        vault.claim();
    }

    function testRevert_Claim_NoVestedFunds() public {
        _createTestGrant();

        // Try to claim before cliff
        vm.warp(block.timestamp + 30 days);

        vm.prank(recipient);
        vm.expectRevert(GrantStreamVault.NoVestedFunds.selector);
        vault.claim();
    }

    function testRevert_Claim_AlreadyClaimedAll() public {
        uint32 startTime = uint32(block.timestamp);
        _createTestGrant();

        // Warp to fully vested
        vm.warp(startTime + DURATION);

        // Claim once
        vm.prank(recipient);
        vault.claim();

        // Try to claim again
        vm.prank(recipient);
        vm.expectRevert(GrantStreamVault.NoVestedFunds.selector);
        vault.claim();
    }

    function testRevert_Claim_WhenPaused() public {
        _createTestGrant();

        vm.warp(block.timestamp + DURATION);

        // Pause
        vm.prank(owner);
        vault.togglePause(true);

        // Try to claim
        vm.prank(recipient);
        vm.expectRevert(GrantStreamVault.ClaimsPaused.selector);
        vault.claim();
    }

    function testRevert_UpdateGrant_NotFound() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.GrantNotFound.selector);
        vault.updateGrant(recipient, GRANT_AMOUNT * 2, DURATION, CLIFF);
    }

    function testRevert_UpdateGrant_Inactive() public {
        _createTestGrant();

        // Revoke grant
        vm.prank(owner);
        vault.revokeGrant(recipient);

        // Try to update an inactive (revoked) grant; expect GrantInactive
        vm.startPrank(owner);
        token.approve(address(vault), GRANT_AMOUNT);
        vm.expectRevert(GrantStreamVault.GrantInactive.selector);
        vault.updateGrant(recipient, GRANT_AMOUNT * 2, DURATION, CLIFF);
        vm.stopPrank();
    }

    function testRevert_UpdateGrant_DecreaseAmount() public {
        _createTestGrant();

        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.InvalidAmount.selector);
        vault.updateGrant(recipient, GRANT_AMOUNT / 2, DURATION, CLIFF);
    }

    function testRevert_UpdateGrant_DecreaseDuration() public {
        _createTestGrant();

        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.InvalidDuration.selector);
        vault.updateGrant(recipient, GRANT_AMOUNT, DURATION - 30 days, CLIFF);
    }

    function testRevert_UpdateGrant_IncreaseCliffduration() public {
        _createTestGrant();

        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.InvalidCliffDuration.selector);
        vault.updateGrant(recipient, GRANT_AMOUNT, DURATION, CLIFF + 30 days);
    }

    function testRevert_RevokeGrant_NotFound() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.GrantNotFound.selector);
        vault.revokeGrant(recipient);
    }

    function testRevert_RevokeGrant_AlreadyRevoked() public {
        _createTestGrant();

        vm.startPrank(owner);

        // First revoke
        vault.revokeGrant(recipient);

        // Try to revoke again → should revert with GrantInactive (not GrantNotFound)
        vm.expectRevert(GrantStreamVault.GrantInactive.selector);
        vault.revokeGrant(recipient);

        vm.stopPrank();
    }

    function testRevert_OnlyOwner_CreateGrant() public {
        vm.startPrank(recipient);
        token.approve(address(vault), GRANT_AMOUNT);

        vm.expectRevert(GrantStreamVault.NotOwner.selector);
        vault.createGrant(otherRecipient, GRANT_AMOUNT, uint32(block.timestamp), DURATION, CLIFF);

        vm.stopPrank();
    }

    function testRevert_OnlyOwner_UpdateGrant() public {
        _createTestGrant();

        vm.prank(recipient);
        vm.expectRevert(GrantStreamVault.NotOwner.selector);
        vault.updateGrant(recipient, GRANT_AMOUNT * 2, DURATION, CLIFF);
    }

    function testRevert_OnlyOwner_RevokeGrant() public {
        _createTestGrant();

        vm.prank(recipient);
        vm.expectRevert(GrantStreamVault.NotOwner.selector);
        vault.revokeGrant(recipient);
    }

    function testRevert_OnlyOwner_TogglePause() public {
        vm.prank(recipient);
        vm.expectRevert(GrantStreamVault.NotOwner.selector);
        vault.togglePause(true);
    }

    function testRevert_InvalidFee() public {
        // Test fee > 500 bps (5%)
        vm.expectRevert(GrantStreamVault.InvalidFee.selector);
        new GrantStreamVault(501, address(token), feeRecipient, owner);
    }

    // ============ EDGE CASE TESTS ============

    function test_VestingAtExactCliff() public {
        uint32 startTime = uint32(block.timestamp);
        _createTestGrant();

        // Warp to exact cliff moment
        vm.warp(startTime + CLIFF);

        uint256 expectedVested = (GRANT_AMOUNT * uint256(CLIFF)) / DURATION;
        assertEq(vault.vestedAmount(recipient), expectedVested);
    }

    function test_VestingAtExactEnd() public {
        uint32 startTime = uint32(block.timestamp);
        _createTestGrant();

        // Warp to exact end
        vm.warp(startTime + DURATION);

        assertEq(vault.vestedAmount(recipient), GRANT_AMOUNT);
    }

    function test_MultipleRecipients() public {
        // Create grants for two recipients
        vm.startPrank(owner);

        token.approve(address(vault), GRANT_AMOUNT * 2);

        uint32 startTime = uint32(block.timestamp);
        vault.createGrant(recipient, GRANT_AMOUNT, startTime, DURATION, CLIFF);
        vault.createGrant(otherRecipient, GRANT_AMOUNT, startTime, DURATION, CLIFF);

        vm.stopPrank();

        // Warp and both claim
        vm.warp(startTime + 180 days);

        vm.prank(recipient);
        vault.claim();

        vm.prank(otherRecipient);
        vault.claim();

        // Both should have received funds
        assertGt(token.balanceOf(recipient), 0);
        assertGt(token.balanceOf(otherRecipient), 0);
    }

    function test_RevokeAtStart() public {
        _createTestGrant();

        // Revoke immediately (nothing vested yet)
        vm.prank(owner);
        vault.revokeGrant(recipient);

        // All funds should be returned
        assertEq(token.balanceOf(address(vault)), 0);

        // Recipient cannot claim, expect GrantNotFound
        vm.prank(recipient);
        vm.expectRevert(GrantStreamVault.GrantNotFound.selector);
        vault.claim();
    }

    function test_RevokeAfterPartialClaim() public {
        uint32 startTime = uint32(block.timestamp);
        _createTestGrant();

        // Warp and claim 25%
        vm.warp(startTime + 90 days);
        vm.prank(recipient);
        vault.claim();

        uint256 recipientBalance = token.balanceOf(recipient);

        // Warp to 50% and revoke
        vm.warp(startTime + 180 days);

        vm.prank(owner);
        vault.revokeGrant(recipient);

        // Recipient can still claim remaining vested
        vm.prank(recipient);
        vault.claim();

        // Should have more than before
        assertGt(token.balanceOf(recipient), recipientBalance);
    }

    function test_ZeroFee() public {
        // Create vault with 0 fee
        vm.startPrank(owner);
        GrantStreamVault zeroFeeVault = new GrantStreamVault(0, address(token), feeRecipient, owner);

        token.approve(address(zeroFeeVault), GRANT_AMOUNT);

        uint32 startTime = uint32(block.timestamp);
        zeroFeeVault.createGrant(recipient, GRANT_AMOUNT, startTime, DURATION, CLIFF);
        vm.stopPrank();

        // Warp and claim
        vm.warp(startTime + DURATION);
        vm.prank(recipient);
        zeroFeeVault.claim();

        // Recipient should receive full amount (no fee)
        assertEq(token.balanceOf(recipient), GRANT_AMOUNT);
        assertEq(token.balanceOf(feeRecipient), 0);
    }

    function test_MaxFee() public {
        // Create vault with max fee (5%)
        vm.startPrank(owner);
        GrantStreamVault maxFeeVault = new GrantStreamVault(500, address(token), feeRecipient, owner);

        token.approve(address(maxFeeVault), GRANT_AMOUNT);

        uint32 startTime = uint32(block.timestamp);
        maxFeeVault.createGrant(recipient, GRANT_AMOUNT, startTime, DURATION, CLIFF);
        vm.stopPrank();

        // Warp and claim
        vm.warp(startTime + DURATION);
        vm.prank(recipient);
        maxFeeVault.claim();

        uint256 expectedFee = (GRANT_AMOUNT * 500) / 10000; // 5%
        uint256 expectedNet = GRANT_AMOUNT - expectedFee;

        assertEq(token.balanceOf(recipient), expectedNet);
        assertEq(token.balanceOf(feeRecipient), expectedFee);
    }

    // ============ FUZZ TESTS ============

    function testFuzz_VestingAmount(uint32 timeElapsed) public {
        uint32 startTime = uint32(block.timestamp);
        _createTestGrant();

        // Bound time to reasonable range
        timeElapsed = uint32(bound(timeElapsed, 0, DURATION * 2));

        vm.warp(startTime + timeElapsed);

        uint256 vested = vault.vestedAmount(recipient);

        // Invariants
        assertLe(vested, GRANT_AMOUNT, "Vested should never exceed total");

        if (timeElapsed < CLIFF) {
            assertEq(vested, 0, "Nothing should vest before cliff");
        }

        if (timeElapsed >= DURATION) {
            assertEq(vested, GRANT_AMOUNT, "Should be fully vested after duration");
        }
    }

    function testFuzz_ClaimAmount(uint32 timeElapsed) public {
        uint32 startTime = uint32(block.timestamp);
        _createTestGrant();

        // Bound time to after cliff
        timeElapsed = uint32(bound(timeElapsed, CLIFF, DURATION * 2));

        vm.warp(startTime + timeElapsed);

        uint256 vestedBefore = vault.vestedAmount(recipient);

        if (vestedBefore > 0) {
            vm.prank(recipient);
            vault.claim();

            (, uint128 claimedAmount,,,,) = vault.grants(recipient);
            // Invariant: claimed should equal what was vested
            assertEq(uint256(claimedAmount), vestedBefore);

            // Balance should be vested minus fee
            uint256 expectedFee = (vestedBefore * FEE_BPS) / 10000;
            assertEq(token.balanceOf(recipient), vestedBefore - expectedFee);
        }
    }

    function testFuzz_CreateGrant(uint128 amount, uint32 duration, uint32 cliff) public {
        // Bound inputs to reasonable ranges
        amount = uint128(bound(amount, 1e18, 1_000_000e18));
        duration = uint32(bound(duration, 1 days, 10 * 365 days));
        cliff = uint32(bound(cliff, 0, duration));

        vm.startPrank(owner);
        token.mint(owner, amount);
        token.approve(address(vault), amount);

        uint32 startTime = uint32(block.timestamp);

        vault.createGrant(otherRecipient, amount, startTime, duration, cliff);

        (uint128 totalAmount,,,,,) = vault.grants(otherRecipient);
        assertEq(totalAmount, amount);

        vm.stopPrank();
    }

    // ============ INVARIANT TESTS ============

    function invariant_ClaimedNeverExceedsTotal() public {
        // This would be used with proper invariant testing setup
        // For now, we test the principle manually

        _createTestGrant();

        // Try claiming at various times
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 73 days);

            try vault.claim() {
                (, uint128 claimedAmount,,,,) = vault.grants(recipient);
                (uint128 totalAmount,,,,,) = vault.grants(recipient);

                assertLe(claimedAmount, totalAmount, "Claimed exceeds total");
            } catch {
                // Claim reverted (no funds available), that's ok
            }

            vm.stopPrank();
            vm.startPrank(recipient);
        }
    }

    // ============ HELPER FUNCTIONS ============

    function _createTestGrant() internal {
        vm.startPrank(owner);
        token.approve(address(vault), GRANT_AMOUNT);
        vault.createGrant(recipient, GRANT_AMOUNT, uint32(block.timestamp), DURATION, CLIFF);
        vm.stopPrank();
    }
}
