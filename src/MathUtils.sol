// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library MathUtils {
    error InvalidCastToUint128();

    /**
     * @notice Safely casts a uint value to uint128, ensuring the value is within the range of uint128.
     * @param _val The value to cast to uint128.
     * @return The value cast to uint128, if it is representable.
     * @dev Reverts with `InvalidCastToUint128` error if the value exceeds the maximum uint128 value.
     */
    function safe128(uint256 _val) internal pure returns (uint128) {
        if (_val > type(uint128).max) revert InvalidCastToUint128();
        // casting to 'uint128' is safe because we check bounds above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(_val);
    }
}
