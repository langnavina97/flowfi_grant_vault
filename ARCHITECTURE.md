# GrantStreamVault Architecture

## Storage Layout

- **Grant struct**: Tightly packed with uint128 amounts, uint32 timestamps, and bool flags (46 bytes, 2 storage slots)
- **Mapping**: `grants[address]` stores one grant per recipient
- **Immutable parameters**: PROTOCOL_FEE_BPS, GRANT_TOKEN, FEE_RECIPIENT set at deployment
- **State variables**: owner (access control), paused (emergency stop), \_status (reentrancy guard)

## Access Control

- **Owner-only functions**: createGrant, updateGrant, revokeGrant, togglePause
- **Public functions**: claim (anyone), view functions (anyone)
- **Pause mechanism**: Emergency stop for all claims
- **Custom implementation**: MVP uses custom modifiers

## Key Safety Considerations

- **ReentrancyGuard**: Custom implementation prevents reentrancy attacks
- **CEI pattern**: State updates before external calls to prevent reentrancy
- **Input validation**: Comprehensive checks on all parameters
- **Grant revocation**: Locks vested amount, returns unvested funds
- **Fee protection**: Maximum 5% protocol fee enforced at deployment
- **No backdated grants**: Start time must be >= block.timestamp for security
