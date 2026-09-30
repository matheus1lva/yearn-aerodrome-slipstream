-include .env

.PHONY: build test test-unit test-fork clean size update deploy-dry

update:; forge update
build:; forge build
size:; forge build --sizes
clean:; forge clean

# Unit / mock tests (no fork required)
test-unit:; forge test --no-match-path 'src/test/Fork*.t.sol' -vv

# Full suite: unit always; fork only if BASE_RPC_URL is set
test:
	@forge test --no-match-path 'src/test/Fork*.t.sol' -vv
	@if [ -n "$(BASE_RPC_URL)" ]; then \
		echo "Running Base fork tests..."; \
		forge test --match-path 'src/test/Fork*.t.sol' -vv --fork-url $(BASE_RPC_URL); \
	else \
		echo "Skipping fork tests (set BASE_RPC_URL to enable)."; \
	fi

test-fork:
	@if [ -z "$(BASE_RPC_URL)" ]; then echo "BASE_RPC_URL not set"; exit 1; fi
	forge test --match-path 'src/test/Fork*.t.sol' -vv --fork-url $(BASE_RPC_URL)

# Dry-run deploy script (no broadcast)
deploy-dry:
	@if [ -z "$(BASE_RPC_URL)" ]; then echo "BASE_RPC_URL not set"; exit 1; fi
	forge script script/Deploy.s.sol:Deploy --rpc-url $(BASE_RPC_URL) -vvvv
