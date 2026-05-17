# mim-contracts
# $MIM — Replit Setup Guide

**Goal:** Bootstrap a Foundry-based Solidity project for $MIM in Replit, ready for contract development against Uniswap V4. By the end of this doc, you'll be able to run `forge test` and see green checkmarks.

**Estimated time:** 30–45 minutes

**Last verified:** May 2026

---

## Part 0 — Before you start

You need:
- A Replit account (you already have one)
- A GitHub account (for backing up the repo — strongly recommended)
- An Alchemy account (free tier is fine) for Base Sepolia RPC
- ~$0 in costs for this setup

You'll create:
- One Replit project called `mim-contracts`
- One private GitHub repo also called `mim-contracts` (mirror)
- One Alchemy app for Base Sepolia

---

## Part 1 — Create the Replit project

1. Go to https://replit.com → "Create Repl"
2. Choose template: **Blank** (not Node.js, not Python — we want a clean shell)
3. Title: `mim-contracts`
4. Privacy: **Private** (critical — contracts are sensitive until launch)
5. Click "Create Repl"

You should land in a blank workspace with just an empty file tree.

---

## Part 2 — Install Foundry

In the Replit shell (bottom panel), run:

```bash
curl -L https://foundry.paradigm.xyz | bash
```

This downloads the Foundry installer. You'll see output ending with something like:
```
Foundry has been installed.
Run `foundryup` to install/update the latest version.
```

Now add Foundry to your PATH and install the toolchain:

```bash
export PATH="$HOME/.foundry/bin:$PATH"
echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
foundryup
```

`foundryup` downloads `forge`, `cast`, `anvil`, and `chisel` (the four Foundry binaries). This takes 1–2 minutes.

Verify installation:

```bash
forge --version
cast --version
```

You should see version strings printed. If you get "command not found," the PATH didn't stick — close and reopen the shell tab in Replit, then run `forge --version` again.

---

## Part 3 — Initialize the Foundry project

In the Replit shell:

```bash
forge init --no-commit mim-contracts
cd mim-contracts
```

Wait — `forge init` wants an empty directory. Replit's project root has hidden files. Better approach:

```bash
forge init --force --no-commit .
```

This forces initialization in the current (already-mostly-empty) directory.

You'll see Foundry create:
```
.
├── foundry.toml
├── lib/
│   └── forge-std/
├── script/
│   └── Counter.s.sol
├── src/
│   └── Counter.sol
└── test/
    └── Counter.t.sol
```

Delete the example Counter files (we'll replace them):

```bash
rm src/Counter.sol test/Counter.t.sol script/Counter.s.sol
```

---

## Part 4 — Install required dependencies

$MIM needs five libraries. We install them as git submodules (Foundry convention):

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install Uniswap/v4-core --no-commit
forge install Uniswap/v4-periphery --no-commit
forge install PaulRBerg/prb-math --no-commit
forge install Vectorized/solady --no-commit
```

Each command takes 30–60 seconds. You'll see progress as git clones each repo into `lib/`.

**What each is for:**
- `openzeppelin-contracts` — Battle-tested ERC-20 base, MerkleProof verification, ReentrancyGuard
- `v4-core` — Uniswap V4 PoolManager interfaces and base hook contracts
- `v4-periphery` — V4 helper contracts including BaseHook
- `prb-math` — UD60x18 fixed-point math for the bonding curve
- `solady` — Highly gas-optimized utility contracts (we'll use a few)

---

## Part 5 — Configure foundry.toml

Replace the contents of `foundry.toml` with this:

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.26"
optimizer = true
optimizer_runs = 1000
via_ir = true
evm_version = "cancun"

remappings = [
    "@openzeppelin/=lib/openzeppelin-contracts/",
    "v4-core/=lib/v4-core/src/",
    "v4-periphery/=lib/v4-periphery/src/",
    "@prb/math/=lib/prb-math/src/",
    "solady/=lib/solady/src/",
    "forge-std/=lib/forge-std/src/"
]

# Fuzz settings — tuned for Replit's limited compute
[fuzz]
runs = 256

[invariant]
runs = 16
depth = 32

# Base mainnet config (used at deployment time)
[rpc_endpoints]
base_sepolia = "${BASE_SEPOLIA_RPC_URL}"
base_mainnet = "${BASE_MAINNET_RPC_URL}"

[etherscan]
base_sepolia = { key = "${BASESCAN_API_KEY}", chain = 84532 }
base_mainnet = { key = "${BASESCAN_API_KEY}", chain = 8453 }
```

**What this does:**
- `solc_version = "0.8.26"` — Required for V4 hooks
- `via_ir = true` — Uses the IR compiler pipeline, required for some V4 contracts (and lets us avoid "stack too deep" errors)
- `optimizer_runs = 1000` — Balanced between deployment cost and runtime cost
- `evm_version = "cancun"` — V4 uses transient storage (TSTORE/TLOAD) from Cancun
- `remappings` — Lets us write `import "@openzeppelin/contracts/..."` instead of `import "lib/openzeppelin-contracts/contracts/..."`
- `fuzz.runs = 256` — Lower than ideal but Replit will choke if higher; we'll bump locally later

---

## Part 6 — Set up environment variables

In Replit, click the **Secrets** icon in the left sidebar (it looks like a padlock).

Add these secrets:

| Key | Value | Where to get it |
|---|---|---|
| `BASE_SEPOLIA_RPC_URL` | Your Alchemy Base Sepolia URL | https://dashboard.alchemy.com/ → Create App → Base → Sepolia |
| `BASE_MAINNET_RPC_URL` | Your Alchemy Base Mainnet URL | Same dashboard, different network |
| `BASESCAN_API_KEY` | Your Basescan API key | https://basescan.org/myapikey |
| `DEPLOYER_PRIVATE_KEY` | A test wallet's private key (DO NOT use a real wallet) | Generate with `cast wallet new` (see below) |

**Generate a fresh deployer wallet** for testing only:

```bash
cast wallet new
```

This prints an address and private key. Copy the private key into the `DEPLOYER_PRIVATE_KEY` secret. **This wallet should only ever hold testnet ETH.** For mainnet launch, you'll generate a fresh wallet through proper privacy hops (we'll cover that in the launch step).

Fund this test wallet with Base Sepolia ETH from a faucet:
- https://www.alchemy.com/faucets/base-sepolia
- https://faucet.quicknode.com/base/sepolia

---

## Part 7 — Verify everything works

Create a temporary test file to make sure compilation works:

```bash
cat > src/Sanity.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UD60x18, ud, exp, ln} from "@prb/math/UD60x18.sol";

contract Sanity {
    function curveTest(uint256 e) external pure returns (uint256) {
        // q(e) = 21M * (1 - e^(-e/500))
        UD60x18 K = ud(21_000_000e18);
        UD60x18 S = ud(500e18);
        UD60x18 eParam = ud(e);
        UD60x18 ratio = eParam / S;
        UD60x18 expTerm = exp(ratio.intoSD59x18().mul(ud(0).intoSD59x18().sub(ud(1e18).intoSD59x18())).intoUD60x18());
        // Simplified for sanity check only
        return K.unwrap();
    }
}
EOF
```

This is a deliberately simple test — we just want to confirm imports work. (The actual curve math will be more careful in the real contracts.)

Now compile:

```bash
forge build
```

You should see:
```
[⠰] Compiling...
[⠒] Compiling N files with 0.8.26
[⠊] Solc 0.8.26 finished in X.XXs
Compiler run successful
```

If you see errors, the most common are:
- **"PrbMath not found"** → Re-run `forge install PaulRBerg/prb-math --no-commit`
- **"Solc 0.8.26 not available"** → Run `foundryup` again to update
- **"Stack too deep"** → Confirm `via_ir = true` is in foundry.toml

Delete the sanity check:

```bash
rm src/Sanity.sol
forge build
```

You should see `forge build` succeed with no files to compile (since src/ is empty now).

---

## Part 8 — Set up version control

In the Replit shell:

```bash
git init
git add .
git commit -m "Initial Foundry setup for MIM contracts"
```

Now create a private GitHub repo:

1. Go to https://github.com/new
2. Name: `mim-contracts`
3. Privacy: **Private**
4. **Do NOT initialize** with README, .gitignore, or license (we already have these)
5. Click "Create repository"

GitHub will show you commands. Use the SSH or HTTPS option:

```bash
git remote add origin git@github.com:YOUR_USERNAME/mim-contracts.git
git branch -M main
git push -u origin main
```

For HTTPS, you'll need a GitHub Personal Access Token (Settings → Developer settings → PATs).

**Verify the push worked** by refreshing your GitHub repo page. You should see the Foundry project structure.

---

## Part 9 — Create the directory structure

We're going to need a specific layout for the five contracts. Run:

```bash
mkdir -p src/interfaces
mkdir -p src/libraries
mkdir -p test/unit
mkdir -p test/integration
mkdir -p test/invariant
mkdir -p test/utils
mkdir -p script/deploy
```

Final structure:

```
mim-contracts/
├── foundry.toml
├── lib/                          # dependencies (gitignored except submodules)
├── src/
│   ├── MIM.sol                   # ERC-20 token with transfer hooks
│   ├── Cauldron.sol              # V4 hook implementing gravity curve
│   ├── Grimoire.sol              # identity registry
│   ├── Wellspring.sol            # yield distributor
│   ├── Wand.sol                  # frontend-facing router
│   ├── interfaces/               # external-facing interfaces
│   └── libraries/                # internal math/utility libraries
├── test/
│   ├── unit/                     # per-contract unit tests
│   ├── integration/              # multi-contract tests
│   ├── invariant/                # property-based fuzz tests
│   └── utils/                    # test helpers (mock Lido, etc.)
├── script/
│   └── deploy/                   # deployment scripts
└── README.md
```

Create a README:

```bash
cat > README.md << 'EOF'
# magic internet money

immutable bonding curve on uniswap v4 with shrinking supply cap, lido yield distribution, and on-chain identity layer.

## architecture

- `MIM.sol` — custom erc-20 with transfer hooks for hold-time tracking
- `Cauldron.sol` — uniswap v4 hook implementing the gravity bonding curve and reserve management
- `Grimoire.sol` — immutable identity registry, auto-written by cauldron
- `Wellspring.sol` — merkle-based eth yield distributor sourced from lido stETH rebases
- `Wand.sol` — frontend router that calls the curve pool unconditionally

## development

```bash
forge build                       # compile
forge test                        # run all tests
forge test --match-path test/unit/MIM.t.sol -vvvv  # run specific test verbose
forge fmt                         # format
forge snapshot                    # gas snapshot
```

## status

pre-launch, contracts in active development. not yet deployed.

EOF
```

Commit:

```bash
git add .
git commit -m "Add directory structure and README"
git push
```

---

## Part 10 — A first sanity test

Let's write one test to confirm the whole pipeline works end-to-end. Create a placeholder MIM contract:

```bash
cat > src/MIM.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MIM is ERC20 {
    constructor() ERC20("magic internet money", "mim") {}
}
EOF
```

Create a corresponding test:

```bash
cat > test/unit/MIM.t.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MIM} from "../../src/MIM.sol";

contract MIMTest is Test {
    MIM public mim;

    function setUp() public {
        mim = new MIM();
    }

    function test_NameAndSymbol() public view {
        assertEq(mim.name(), "magic internet money");
        assertEq(mim.symbol(), "mim");
    }

    function test_DecimalsAreEighteen() public view {
        assertEq(mim.decimals(), 18);
    }
}
EOF
```

Run the test:

```bash
forge test
```

You should see:
```
Running 2 tests for test/unit/MIM.t.sol:MIMTest
[PASS] test_DecimalsAreEighteen() (gas: ...)
[PASS] test_NameAndSymbol() (gas: ...)
Suite result: ok. 2 passed; 0 failed; 0 skipped
```

If you see this, **everything is working.** You're ready to start writing the real contracts.

Commit:

```bash
git add .
git commit -m "Add placeholder MIM contract with sanity tests"
git push
```

---

## Part 11 — Useful commands cheat sheet

Bookmark these. You'll use them constantly during development:

```bash
# Compile
forge build

# Run all tests
forge test

# Run a specific test, verbose (4 levels of -v for trace output)
forge test --match-test test_NameAndSymbol -vvvv

# Run tests in a specific file
forge test --match-path test/unit/MIM.t.sol

# Run with coverage
forge coverage

# Format code
forge fmt

# Snapshot gas costs (creates .gas-snapshot file)
forge snapshot

# Diff gas costs against snapshot
forge snapshot --diff

# Run a Foundry script
forge script script/deploy/DeployMIM.s.sol --rpc-url base_sepolia --broadcast

# Fork test (against real Base mainnet state)
forge test --fork-url base_mainnet

# Generate a fresh wallet
cast wallet new

# Check wallet balance
cast balance YOUR_ADDRESS --rpc-url base_sepolia

# Send test tx
cast send TARGET --value 0.01ether --rpc-url base_sepolia --private-key $DEPLOYER_PRIVATE_KEY

# Clean build artifacts
forge clean
```

---

## Part 12 — When to graduate off Replit

Replit will start hurting when you hit any of:
- Fork tests against real Base mainnet (slow on free tier)
- Heavy fuzz campaigns (1000+ runs)
- Hook address mining (CPU-intensive)
- Multi-hour test suites

When that happens, options in order of preference:

1. **Local development on your laptop** — Install Foundry locally with same `foundryup` command. Clone the repo from GitHub. Identical setup.
2. **DigitalOcean droplet** — You have prior experience. A $20/month droplet handles everything. Same setup commands.
3. **Dedicated dev VM** — For heavy fuzzing, consider a 16-core dedicated machine. Overkill for now.

The Foundry project is fully portable — your `foundry.toml`, contracts, and tests work identically on any machine with Foundry installed.

---

## Part 13 — What's next

You now have:
- ✅ Foundry installed and working in Replit
- ✅ All dependencies installed (OpenZeppelin, V4, PRBMath, Solady, forge-std)
- ✅ Project structure laid out
- ✅ One sanity test passing
- ✅ Private GitHub repo backing it all up
- ✅ Environment variables configured

**Next steps (in order):**
1. Architecture diagram (Claude will produce — your reference document for all contract interactions)
2. `MIM.sol` — full custom ERC-20 with transfer hooks (~150 lines)
3. `Grimoire.sol` — identity registry (~200 lines)
4. `Wellspring.sol` — Merkle yield distributor (~250 lines)
5. `Cauldron.sol` — the V4 hook with bonding curve (~600+ lines, the heavy one)
6. `Wand.sol` — frontend router (~100 lines)
7. Deployment script
8. Integration test suite

For each, Claude will produce:
- The full contract code
- The Foundry test file
- A walkthrough explaining what each section does
- Specific failure modes to watch for

You'll:
- Paste each into Replit
- Run `forge test --match-path test/unit/CONTRACT.t.sol`
- Report results back
- Iterate until green

---

## Troubleshooting common Replit issues

**"forge: command not found" after closing the shell**
The PATH didn't persist. Run:
```bash
export PATH="$HOME/.foundry/bin:$PATH"
```
Add to `~/.bashrc` if it isn't already there.

**"Out of memory" during `forge test`**
Reduce fuzz runs in `foundry.toml`:
```toml
[fuzz]
runs = 64
```
Or run tests sequentially with `--threads 1`.

**Replit goes to sleep mid-build**
Free Replit projects sleep after inactivity. Either:
- Upgrade to Replit Hacker plan ($7/month) for always-on
- Use Replit Reserved VM (you've used these before for $PULSE)
- Or just `forge build` again when you come back — it'll resume from cache

**"Submodule not found" or similar git errors**
Run:
```bash
git submodule update --init --recursive
```

**Slow `forge test` performance**
Replit's free CPU is shared. Options:
- Reduce fuzz runs
- Run specific tests with `--match-path` instead of full suite
- Upgrade to Hacker plan for dedicated compute

---

## Security reminders

- Never commit `.env` files or private keys to git
- The `DEPLOYER_PRIVATE_KEY` in Replit Secrets is for testnet only — never put a real wallet's key there
- Before mainnet, you'll generate a fresh deployer wallet funded through privacy hops
- All contract addresses are public; treat anything written to mainnet as permanent
- Keep the repo private until you're ready to publish on launch day

---

End of setup guide. When you've got `forge test` passing, ping Claude and we'll start with the architecture diagram.
