# Yearn V3 — Aerodrome Slipstream WETH/USDC (Base)

Estratégia **Tokenized Strategy** (Yearn V3) que concentra liquidez no **Aerodrome Slipstream** (CL / estilo Uniswap V3) no par **WETH/USDC** na rede **Base**, stakeia o NFT no gauge CL para farmar **AERO**, vende as recompensas e faz compound.

> **Não** é um loop Morpho / yvUSD / PT. Apenas compounder de LP Slipstream.

Baseado nos padrões do [`yearn/tokenized-strategy-foundry-mix`](https://github.com/yearn/tokenized-strategy-foundry-mix), com dependências:

- `yearn/tokenized-strategy` **v3.1.0** (endereço CREATE2 de produção do `TokenizedStrategy`)
- `yearn/tokenized-strategy-periphery` (master — HealthCheck + AuctionSwapper)

## Arquitetura

```
Depositantes (ERC-4626)
        │
        ▼
AerodromeSlipstreamStrategy  ◄── BaseHealthCheck + AuctionSwapper
        │
        ├─ _deployFunds  → swap 50/50 → NPM.mint/increase → gauge.deposit(NFT)
        ├─ _freeFunds    → gauge.withdraw → decrease/collect → swap → WETH
        └─ _harvestAndReport → gauge.getReward(AERO) → auction|router → compound
```

| Peça | Papel |
|------|--------|
| **Asset** | WETH (`0x4200…0006`) |
| **Par** | USDC (`0x8335…2913`) |
| **NPM** | Slipstream NonfungiblePositionManager |
| **Gauge** | CL gauge do pool (emissões AERO) |
| **Router** | Slipstream SwapRouter (tickSpacing, não fee) |

### Periphery Yearn

- **`BaseHealthCheck`**: limita lucro/prejuízo reportados em `report()` vs `lastTotalAssets`. Depósitos podem ser abertos (`setOpen`) ou via whitelist.
- **`AuctionSwapper`**: venda opcional de AERO via Dutch auction Yearn (`setAuction`). Se desligado, o harvest usa o SwapRouter Slipstream.

### v0 — o que está implementado vs stub

| Item | Estado |
|------|--------|
| Overrides `_deployFunds` / `_freeFunds` / `_harvestAndReport` | Implementado (caminho NPM + gauge) |
| Claim AERO + swap + compound | Implementado (router; auction opcional) |
| `_tend` / `_tendTrigger` | Stub pragmático (skew de tick → trigger; rebalance completo = TODO) |
| Gestão de range CLM autônoma | **TODO(prod-range)** |
| Oracle TWAP / mins de slippage | **TODO(prod-oracle / prod-slippage)** |
| Valuation exata via LiquidityAmounts | **TODO(prod-amounts)** — v0 usa `deployedEstimate` |

## Riscos (leia antes de depositar)

1. **Impermanent Loss (IL)** — liquidez concentrada amplifica IL vs hold de WETH+USDC quando o preço sai do range.
2. **Fora de range** — fora de `[tickLower, tickUpper]` a posição não ganha fees de swap; v0 não rebalanceia sozinha.
3. **Emissões / gauges** — APR depende de votos veAERO; pode cair a zero.
4. **Contabilidade v0** — `deployedEstimate` é aproximado; não use em produção sem `TODO(prod-amounts)`.
5. **MEV / sandwich** — deploys permissionless em `deposit` podem ser sanduíche; considere deploy só via `tend` + relay privado.
6. **Risco de smart contract** — Yearn TS, Aerodrome Slipstream, esta estratégia (código novo).

## Endereços Base (placeholders)

Ver `src/libraries/BaseAddresses.sol`. **Confirme no Basescan / UI Aerodrome** antes do deploy:

- Pool CL100 WETH/USDC e respectivo gauge podem mudar entre deployments Slipstream.
- NPM canônico alinhado a `gauge.nft()` do CL100 (há mais de um NPM Slipstream na Base).
- `TokenizedStrategy` v3.1.0: `0x310f5Db015E9d6E542fd41bd4542640790791e76`

## Desenvolvimento

```bash
# Deps já estão em lib/ via forge install
export PATH="$HOME/.foundry/bin:$PATH"
cp .env.example .env   # opcional: BASE_RPC_URL=

make build             # forge build
make test-unit         # testes mock (sem RPC)
make test              # unit + fork se BASE_RPC_URL setado
make test-fork         # só fork Base
make deploy-dry        # script sem broadcast
```

### Estrutura

```
src/
  AerodromeSlipstreamStrategy.sol   # estratégia principal
  StrategyFactory.sol
  interfaces/IAerodromeSlipstream.sol
  interfaces/IStrategyInterface.sol
  libraries/BaseAddresses.sol
  test/…                            # unit + ForkBase
script/Deploy.s.sol
```

## Deploy (próximos passos)

1. `forge build` ✓
2. Ajustar `tickLower` / `tickUpper` com base em `pool.slot0().tick` (múltiplos de `tickSpacing`).
3. Validar pool/gauge em `BaseAddresses`.
4. Definir roles: `MANAGEMENT`, `KEEPER`, `EMERGENCY_ADMIN`, `PERF_FEE_RECIPIENT`.
5. Dry-run:
   ```bash
   forge script script/Deploy.s.sol:Deploy --rpc-url $BASE_RPC_URL -vvvv
   ```
6. Broadcast + verify (quando pronto — **não** incluído como requisito deste scaffold):
   ```bash
   forge script script/Deploy.s.sol:Deploy --rpc-url $BASE_RPC_URL --broadcast --verify
   ```
7. Pós-deploy: `acceptManagement` se necessário, `setAuction` (opcional), `setProfitLimitRatio` / `setLossLimitRatio`, keeper `report` / `tend`.

## Licença

AGPL-3.0 (alinhado ao Yearn Tokenized Strategy).
