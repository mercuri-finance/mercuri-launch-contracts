// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPositionOwner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Owns every graduated pool's Uniswap v4 position NFT. It contains no code that approves, transfers
///         or modifies a position, no owner, no delegatecall and no selfdestruct: liquidity sent here stays.
contract LiquidityLocker {
    /// @notice Canonical PositionManager whose NFTs this contract holds permanently.
    IPositionOwner public immutable positionManager;
    /// @notice Only caller allowed to record a locked position; may itself be an upgradeable proxy.
    address public immutable graduationManager;

    /// @notice Recorded NFT ID for a token; zero means unrecorded. Canonical PositionManager starts IDs at one.
    mapping(address token => uint256 tokenId) public positionOf;

    /// @notice Emitted once per launch, when the graduated pool's position NFT has been verified to be held
    ///         here. There is no counterpart event: nothing in this contract can ever release a position.
    /// @param token the launch token whose full-range position this is
    /// @param tokenId the PositionManager ERC-721 id now owned by this contract
    event PositionLocked(address indexed token, uint256 indexed tokenId);

    error Unauthorized();
    error AlreadyRecorded();
    error NotHeld();

    /// @notice Fixes position custody and registration authority permanently.
    /// @param positionManager_ Canonical PositionManager; must use nonzero NFT IDs.
    /// @param graduationManager_ Trusted graduation manager proxy permitted to record positions.
    constructor(address positionManager_, address graduationManager_) {
        positionManager = IPositionOwner(positionManager_);
        graduationManager = graduationManager_;
    }

    /// @notice Records a position once after checking that this locker owns it.
    /// @dev Only graduationManager may call. It is trusted to associate the correct token and pool.
    /// @param token Launch token to associate with the position.
    /// @param tokenId Nonzero canonical PositionManager NFT ID already owned by this locker.
    function record(address token, uint256 tokenId) external {
        if (msg.sender != graduationManager) revert Unauthorized();
        if (positionOf[token] != 0) revert AlreadyRecorded();
        if (positionManager.ownerOf(tokenId) != address(this)) revert NotHeld();
        positionOf[token] = tokenId;
        emit PositionLocked(token, tokenId);
    }

    /// @notice Checks recorded custody; does not independently validate pool composition or liquidity.
    /// @param token Launch token to query.
    /// @return True when its recorded NFT is currently owned by this contract.
    function isLocked(address token) external view returns (bool) {
        uint256 tokenId = positionOf[token];
        return tokenId != 0 && positionManager.ownerOf(tokenId) == address(this);
    }
}
