# Token Swap

## How to install aptos-cli@v2.0.0

```sh
wget https://aptos.dev/scripts/install_cli.py

# convert "aptos-cli-" to "aptos-cli-v2.0.0" at line 248            
vim ./install_cli.py

python3 ./install-cli.py
```

## Run test

```sh

aptos account fund-with-faucet --account default
aptos move test --named-addresses token_swap=default
aptos move test --named-addresses token_swap=default

```
