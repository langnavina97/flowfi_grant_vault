# GrantStreamVault

A minimal, gas-efficient vault for linearly distributing vested ERC20 DAO grants with a protocol fee.

## Features

- Linear vesting with cliff period
- Protocol fee collection (max 5%)
- Grant revocation with unvested fund recovery
- Emergency pause mechanism
- Comprehensive access control
- Gas-optimized storage layout

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

**Command to run tests:** `forge test`

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
