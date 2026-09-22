// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IFeeManager {
    struct TokenInfo {
        /// @dev Only this curve may accrue curve-trade fees for the registered token.
        address curve;
        /// @dev Recipient of the creator allocation.
        address creator;
        /// @dev Pool fee rate in basis points of the USDC leg; strictly below 10,000.
        uint16 tradeFeeBps;
        /// @dev Creator allocation in basis points of the fee, not the trade.
        uint16 creatorShareBps;
        /// @dev Referrer allocation in basis points of the fee; combined shares cannot exceed 10,000.
        uint16 referrerShareBps;
    }

    /// @param token the launch token this record is keyed by
    /// @param curve the only address allowed to call `accrueTradeFee` for `token`
    /// @param creator address credited with the creator share of every fee on `token`
    /// @param tradeFeeBps fee charged on the USDC leg of a trade, in basis points of that leg
    /// @param creatorShareBps creator's cut, in basis points OF THE FEE (not of the trade)
    /// @param referrerShareBps referrer's cut, in basis points OF THE FEE (not of the trade)
    event TokenRegistered(address indexed token, address indexed curve, address indexed creator, uint16 tradeFeeBps, uint16 creatorShareBps, uint16 referrerShareBps);
    /// @param token the launch token the fee was charged on
    /// @param trader the wallet the fee was charged to, and whose binding decided `referrer`
    /// @param creator address credited with `creatorAmount`
    /// @param referrer address credited with `referrerAmount`, or `address(0)` when the trader has no binding
    /// @param creatorAmount native USDC wei (18-dec) added to the creator's claimable balance
    /// @param referrerAmount native USDC wei (18-dec) added to the referrer's claimable balance; 0 when unreferred
    /// @param platformAmount native USDC wei (18-dec) added to the platform bucket, i.e. the remainder of the
    ///        fee after the creator and referrer shares
    /// @param source 0 = bonding curve, 1 = pool hook
    event FeeAccrued(address indexed token, address indexed trader, address creator, address referrer, uint256 creatorAmount, uint256 referrerAmount, uint256 platformAmount, uint8 source);
    /// @param token the launch token the payment relates to, or `address(0)` for a `sweepUnaccounted` of native
    ///        USDC that belongs to no particular launch
    /// @param from the caller that sent the value in (a curve for a snipe tax or graduation dust, the factory
    ///        for a launch fee, the GraduationManager for its leftover, or whoever called `sweepUnaccounted`)
    /// @param amount native USDC wei (18-dec) added to the platform bucket
    event PlatformAccrued(address indexed token, address indexed from, uint256 amount);
    /// @param account the wallet whose claimable balance was paid out and zeroed
    /// @param to the address the native USDC was actually sent to, chosen by `account`
    /// @param amount native USDC wei (18-dec) paid out
    event FeeClaimed(address indexed account, address indexed to, uint256 amount);
    /// @param to the treasury address the factory pointed at when the claim ran
    /// @param amount native USDC wei (18-dec) paid out of the platform bucket
    event PlatformClaimed(address indexed to, uint256 amount);
    /// @param trader the wallet whose referrer was fixed, permanently, by this event
    /// @param referrer the wallet that will earn the referrer share of every future fee `trader` pays
    event ReferralBound(address indexed trader, address indexed referrer);

    error Unauthorized();
    error AlreadyRegistered();
    error InvalidReferrer();
    error InvalidShares();
    error InvalidTradeFee();
    error ReferrerLocked();
    error NothingToClaim();
    error TransferFailed();
    error Unbacked();

    /// @notice Registers a launch once; callable only by the configured factory.
    /// @param token Launch token address.
    /// @param curve Curve authorized to accrue this token's fees.
    /// @param creator Account credited with creator fees.
    /// @param tradeFeeBps_ Fee rate below 10,000 bps; the current factory additionally caps this at 500.
    /// @param creatorShareBps Creator allocation in bps of each fee.
    /// @param referrerShareBps Referrer allocation in bps of each fee; combined allocations must not exceed 10,000.
    function registerToken(address token, address curve, address creator, uint16 tradeFeeBps_, uint16 creatorShareBps, uint16 referrerShareBps) external;
    /// @notice Credits msg.value in native USDC wei; only the registered curve may call.
    /// @dev The first curve trade permanently resolves referral eligibility, even when msg.value is zero.
    /// @param token Registered launch token.
    /// @param trader Wallet whose referral is used.
    /// @param referrer Optional first-trade referral; zero and self referrals are ignored.
    function accrueTradeFee(address token, address trader, address referrer) external payable;
    /// @notice Credits msg.value to the platform bucket; anyone may donate, including zero value.
    /// @dev The token label is caller supplied and is not evidence of authenticated launch activity.
    /// @param token Attribution label; may be zero or unregistered.
    function accruePlatform(address token) external payable;
    /// @notice Credits a backed fee already transferred by the configured hook; only that hook may call.
    /// @dev Never binds referrals or marks a wallet as having traded. Reverts Unbacked if balance is insufficient.
    /// @param token Launch token whose fee allocation applies.
    /// @param trader Unauthenticated attribution used only to read an existing referral.
    /// @param amount Fee in 18-decimal native USDC wei, not 6-decimal ERC-20 units.
    function notifyHookFee(address token, address trader, uint256 amount) external;
    /// @notice Permanently binds the caller's referral before their first curve trade.
    /// @param referrer Nonzero address other than the caller; cannot replace an existing binding.
    function bindReferrer(address referrer) external;
    /// @notice Pays the caller's accrued creator/referral fees and clears their balance.
    /// @dev Reverts NothingToClaim for zero balance or TransferFailed if payment fails; all accounting rolls back.
    /// @param to Nonzero recipient accepting native USDC.
    /// @return amount Native USDC wei paid (18 decimals).
    function claim(address to) external returns (uint256 amount);
    /// @notice Pays the platform bucket to the factory's current treasury; anyone may trigger payment.
    /// @dev The caller cannot select the recipient. Failed payment rolls back accounting.
    /// @return amount Native USDC wei paid (18 decimals).
    function claimPlatform() external returns (uint256 amount);
    /// @notice Credits unaccounted native balance to the platform; callable by anyone.
    /// @dev Reverts NothingToClaim when balance equals totalOwed; cannot spend an existing claim.
    /// @return amount Native USDC wei newly accounted for (18 decimals).
    function sweepUnaccounted() external returns (uint256 amount);
    /// @notice Returns the registered pool fee rate.
    /// @param token Launch token; unregistered tokens return zero.
    /// @return Rate in basis points of the USDC trade leg.
    function tradeFeeBps(address token) external view returns (uint16);
    /// @notice Returns the registration used for authentication and fee allocation.
    /// @param token Launch token; unregistered tokens return an all-zero record.
    /// @return Registration including curve, creator and rates.
    function tokenInfo(address token) external view returns (TokenInfo memory);
    /// @notice Returns accrued creator and referral fees for an account.
    /// @param account Fee recipient.
    /// @return Claimable native USDC wei (18 decimals).
    function balances(address account) external view returns (uint256);
    /// @notice Returns the platform's claimable balance.
    /// @return Native USDC wei (18 decimals), included in totalOwed.
    function platformBalance() external view returns (uint256);
    /// @notice Returns total recorded liabilities across all recipients and the platform.
    /// @return Native USDC wei (18 decimals); must not exceed this contract's native balance.
    function totalOwed() external view returns (uint256);
    /// @notice Returns the permanent referral binding, if any.
    /// @param trader Wallet whose binding is queried.
    /// @return Referrer address, or zero if no binding exists.
    function referrerOf(address trader) external view returns (address);
    /// @notice Reports whether a registered curve has processed this wallet's first trade.
    /// @dev Pool swaps do not update this flag.
    /// @param trader Wallet to query.
    /// @return True when future referral binding is prohibited by a prior curve trade.
    function hasTraded(address trader) external view returns (bool);
}
