.PHONY: test

# Pure-logic + fake-client tests. No external deps; needs nvim >= 0.10 for `-l`.
test:
	nvim --headless -l tests/run.lua
