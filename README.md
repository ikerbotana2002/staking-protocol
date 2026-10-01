# Staking Protocol

Protocolo de staking ERC-20 desarrollado en Solidity con Foundry y OpenZeppelin.

El proyecto implementa un sistema de staking con recompensas proporcionales al tiempo y al capital depositado, accounting global mediante `rewardPerToken`, gestión explícita de liabilities, controles administrativos y una suite de tests unitarios, fuzz e invariant testing.

El objetivo del proyecto no es únicamente implementar `stake()` y `unstake()`, sino trabajar problemas habituales en protocolos DeFi: distribución eficiente de recompensas, cambios de reward rate, separación entre principal y reward pool, protección de fondos, precisión aritmética y testing basado en propiedades.

---

## Características principales

- Staking y unstaking de tokens ERC-20.
- Recompensas proporcionales al tiempo y al capital stakeado.
- Reward rate configurable mediante basis points (BPS).
- Accounting eficiente mediante un índice global `rewardPerToken`.
- Soporte para múltiples usuarios con checkpoints individuales.
- Reward pool separado del principal depositado por los usuarios.
- Cálculo de rewards pendientes mediante `earned()`.
- Seguimiento global de rewards ya generadas mediante liabilities.
- Protección frente a pérdida de precisión por redondeos.
- Funding independiente del reward pool.
- Retirada únicamente de rewards realmente libres.
- Pausa de emergencia.
- Unstake disponible incluso durante una pausa.
- Protección frente a reentrancy.
- Transferencia de ownership en dos pasos.
- Tests unitarios, fuzz tests e invariant tests.

---

## Arquitectura

El proyecto utiliza dos contratos principales:

```text
StakingToken.sol
        │
        │ ERC-20 utilizado para testing
        ▼
StakingProtocol.sol
        │
        ├── staking
        ├── reward accounting
        ├── liabilities
        ├── reward pool
        ├── access control
        └── security controls
```

### `StakingToken.sol`

Token ERC-20 utilizado para ejecutar los escenarios de prueba del protocolo.

### `StakingProtocol.sol`

Contiene la lógica principal:

- depósitos;
- retiradas;
- generación de rewards;
- accounting global;
- accounting individual;
- financiación del reward pool;
- cálculo de liabilities;
- retirada de rewards no comprometidas;
- pausas;
- ownership.

---

## Modelo de rewards

El protocolo utiliza un modelo basado en un índice acumulativo global.

La variable:

```solidity
rewardPerTokenStored
```

representa cuánta reward se ha generado acumulativamente por cada token stakeado.

Cada usuario almacena además su propio checkpoint:

```solidity
userRewardPerTokenPaid[user]
```

De esta forma, las nuevas rewards de un usuario pueden calcularse mediante:

```text
rewardPerToken actual
-
rewardPerToken ya contabilizado para el usuario
=
nuevo tramo de rewards
```

y posteriormente:

```text
stakedBalance
×
diferencia del índice
=
reward generada
```

Esto permite actualizar usuarios de forma independiente sin recorrer una lista completa de stakers.

---

## Ejemplo de reward accounting

Supongamos que Alice tiene:

```text
100 STK stakeados
```

y cuando entra al protocolo:

```text
rewardPerToken = 0.05
```

Su checkpoint pasa a ser:

```text
userRewardPerTokenPaid[Alice] = 0.05
```

Más adelante:

```text
rewardPerToken = 0.08
```

Por tanto, Alice ha generado:

```text
100 × (0.08 - 0.05)
= 3 STK
```

Si Alice añade más tokens posteriormente, el contrato primero consolida las rewards generadas con su balance anterior.

Después actualiza su stake.

Así se evita aplicar retroactivamente el nuevo balance a periodos anteriores.

---

## Reward rate

La tasa se expresa mediante basis points:

```text
100 BPS    = 1%
200 BPS    = 2%
10,000 BPS = 100%
```

En este proyecto, la tasa representa la recompensa diaria.

Antes de modificarla se ejecuta:

```solidity
_updateGlobalReward();
```

Por tanto:

```text
periodo con tasa antigua
        ↓
se consolida
        ↓
se actualiza rewardPerTokenStored
        ↓
se cambia rewardRateBps
        ↓
comienza un nuevo periodo
```

Esto impide que una modificación de la tasa afecte retroactivamente a rewards ya generadas.

---

## Principal, reward pool y liabilities

Una parte importante del diseño es distinguir entre tokens que físicamente se encuentran en el contrato y tokens que económicamente pertenecen a usuarios.

### Principal

```solidity
totalStaked
```

Representa el capital depositado por los usuarios.

Este capital no debe utilizarse para pagar rewards.

### Reward pool

```solidity
rewardPoolBalance()
```

Se calcula aproximadamente como:

```text
balance ERC-20 del contrato
-
totalStaked
```

Representa los tokens disponibles físicamente para pagar recompensas.

### Reward liability

```solidity
currentRewardLiability()
```

Representa las rewards que ya se han generado y que, por tanto, el protocolo debe a los usuarios.

### Rewards retirables por el owner

```solidity
withdrawableRewards()
```

Solo permite retirar:

```text
reward pool
-
liabilities
```

Por ejemplo:

```text
Reward pool físico:       10,000 STK
Rewards ya generadas:        600 STK
-----------------------------------
Rewards libres:            9,400 STK
```

Aunque los 10,000 STK estén físicamente dentro del contrato, 600 ya pertenecen económicamente a los stakers.

El owner únicamente puede retirar los 9,400 STK restantes.

---

## Precisión y redondeos

Solidity trabaja con enteros.

Por tanto, cualquier división puede producir truncamiento.

Durante el desarrollo se utilizó invariant testing con Foundry y se encontró un caso en el que la contabilidad global de liabilities podía perder pequeñas fracciones al realizar muchas actualizaciones.

Por ejemplo, conceptualmente podían producirse actualizaciones como:

```text
0.4
0.4
0.4
```

Si cada operación se truncase independientemente:

```text
0 + 0 + 0 = 0
```

aunque acumulativamente ya se hubiera generado más de una unidad.

Esto podía provocar que la deuda registrada globalmente fuese inferior a la reward contabilizada para un usuario y terminar provocando un arithmetic underflow durante un claim.

Para evitarlo, el contrato mantiene:

```solidity
rewardLiabilityRemainder
```

Los restos de las divisiones se conservan y se reutilizan en las siguientes actualizaciones:

```text
0.4 → liability 0 | remainder 0.4

+0.4
    → liability 0 | remainder 0.8

+0.4
    → liability 1 | remainder 0.2
```

El problema fue detectado mediante stateful invariant testing, no por los tests unitarios iniciales.

---

## Seguridad

El protocolo utiliza componentes de OpenZeppelin:

- `SafeERC20`
- `ReentrancyGuard`
- `Pausable`
- `Ownable`
- `Ownable2Step`

### Reentrancy

Las operaciones que realizan transferencias o modifican fondos utilizan:

```solidity
nonReentrant
```

para impedir reentradas durante su ejecución.

### Pausa de emergencia

El owner puede detener determinadas operaciones:

```text
stake()         bloqueado
claimRewards()  bloqueado
unstake()       permitido
```

La retirada del principal sigue disponible deliberadamente para evitar bloquear los fondos de los usuarios durante una emergencia.

### Ownership en dos pasos

El protocolo utiliza `Ownable2Step`.

Una transferencia administrativa requiere:

```text
owner
  │
  ├── transferOwnership(newOwner)
  │
  ▼
pendingOwner
  │
  ├── acceptOwnership()
  │
  ▼
new owner
```

Esto reduce el riesgo de transferir accidentalmente el control del protocolo a una dirección incorrecta.

---

## Testing

El proyecto utiliza Foundry como framework principal.

La suite incluye pruebas sobre:

- staking;
- unstaking;
- partial unstaking;
- claims;
- múltiples depósitos;
- múltiples usuarios;
- acumulación temporal de rewards;
- cambios de reward rate;
- reward pool;
- insolvencia;
- liabilities;
- pausas;
- ownership;
- permisos administrativos;
- compounding manual;
- reward checkpoints;
- fuzz testing;
- stateful invariant testing;
- precisión y redondeos.

### Unit testing

Los tests verifican escenarios concretos y resultados esperados.

Ejemplo:

```text
Alice stakea 100 STK
↓
pasa 1 día
↓
reward rate = 1%
↓
Alice gana 1 STK
```

### Fuzz testing

Foundry genera automáticamente múltiples valores de entrada para comprobar que determinadas propiedades siguen siendo válidas para muchos escenarios diferentes.

Se prueban, entre otros:

- cantidades de stake variables;
- unstake parcial;
- duración variable del staking.

### Stateful invariant testing

Además de probar funciones individualmente, Foundry ejecuta largas secuencias de acciones en distintos órdenes:

```text
stake
stake
advanceTime
claim
unstake
advanceTime
stake
claim
...
```

En una ejecución del proyecto:

```text
Runs:     256
Calls:    128,000
Reverts:  0
```

Esto permite comprobar que propiedades fundamentales del protocolo siguen siendo ciertas independientemente del orden de las operaciones.

Entre las propiedades comprobadas se encuentran:

```text
totalStaked
=
suma del stake de los usuarios
```

y:

```text
balance físico del contrato
>=
totalStaked
```

El invariant testing fue además el mecanismo que permitió descubrir el edge case de precisión descrito anteriormente.

---

## Cobertura

Resultados obtenidos con:

```bash
forge coverage
```

### Contrato principal

| Métrica | Cobertura |
|---|---:|
| Lines | **98.92% (92/93)** |
| Statements | **98.97% (96/97)** |
| Branches | **70.83% (17/24)** |
| Functions | **100.00% (17/17)** |

### Proyecto completo

| Métrica | Cobertura |
|---|---:|
| Lines | **99.32% (145/146)** |
| Statements | **99.35% (153/154)** |
| Branches | **78.12% (25/32)** |
| Functions | **100.00% (29/29)** |

La prioridad del proyecto no ha sido alcanzar artificialmente un 100% de branch coverage, sino cubrir el comportamiento relevante mediante una combinación de unit tests, fuzz tests e invariants.

---

## Estructura del proyecto

```text
staking-protocol/
│
├── src/
│   ├── StakingProtocol.sol
│   └── StakingToken.sol
│
├── test/
│   ├── StakingProtocol.t.sol
│   └── StakingInvariant.t.sol
│
├── foundry.toml
├── remappings.txt
└── README.md
```

---

## Instalación

### Requisitos

Tener Foundry instalado.

Clonar el repositorio:

```bash
git clone https://github.com/ikerbotana2002/staking-protocol.git
```

Entrar en el proyecto:

```bash
cd staking-protocol
```

Instalar dependencias:

```bash
forge install
```

Compilar:

```bash
forge build
```

Ejecutar tests:

```bash
forge test
```

Tests con más detalle:

```bash
forge test -vv
```

Ejecutar únicamente invariant testing:

```bash
forge test --match-contract StakingInvariantTest -vv
```

Coverage:

```bash
forge coverage
```

---

## Tecnologías

- Solidity
- Foundry
- Forge
- OpenZeppelin Contracts
- Forge Std
- Git
- GitHub

---

## Objetivos técnicos trabajados

Este proyecto se ha utilizado para profundizar especialmente en:

- fixed-point arithmetic;
- reward accounting;
- global indexes;
- user checkpoints;
- asset/liability separation;
- ERC-20 integrations;
- stateful testing;
- invariant design;
- fuzz testing;
- arithmetic precision;
- access control;
- emergency mechanisms;
- DeFi protocol security.

---

## Estado

Proyecto funcional y cubierto por una suite amplia de tests.

No ha sido auditado profesionalmente.

Este repositorio tiene fines educativos y de portfolio y no debe utilizarse con fondos reales.

---

# English version

## Staking Protocol

ERC-20 staking protocol built with Solidity, Foundry and OpenZeppelin.

The project implements time-based staking rewards, global `rewardPerToken` accounting, explicit reward liability tracking, administrative controls and an extensive unit, fuzz and invariant testing suite.

The goal of the project is not only to implement `stake()` and `unstake()`, but also to explore common DeFi engineering problems such as efficient reward distribution, reward-rate changes, principal protection, reward solvency, arithmetic precision and property-based testing.

---

## Main features

- ERC-20 staking and unstaking.
- Time and stake-based rewards.
- Configurable reward rate using basis points.
- Global `rewardPerToken` accounting.
- Per-user reward checkpoints.
- Multi-user support.
- Reward pool separated from user principal.
- Pending reward calculation through `earned()`.
- Global reward liability tracking.
- Rounding remainder accounting.
- Independent reward-pool funding.
- Withdrawal of genuinely unused rewards only.
- Emergency pause mechanism.
- Principal withdrawals remain available while paused.
- Reentrancy protection.
- Two-step ownership transfers.
- Unit testing.
- Fuzz testing.
- Stateful invariant testing.

---

## Architecture

The project contains two main contracts:

```text
StakingToken.sol
        │
        │ ERC-20 used for testing
        ▼
StakingProtocol.sol
        │
        ├── staking
        ├── reward accounting
        ├── liabilities
        ├── reward pool
        ├── access control
        └── security controls
```

`StakingToken.sol` provides the ERC-20 token used by the test environment.

`StakingProtocol.sol` contains the staking, reward, liability and administrative logic.

---

## Reward accounting

The protocol uses a cumulative global reward index:

```solidity
rewardPerTokenStored
```

Each user stores an individual checkpoint:

```solidity
userRewardPerTokenPaid[user]
```

New rewards are calculated from:

```text
current rewardPerToken
-
user checkpoint
=
new reward interval
```

and:

```text
staked balance
×
reward index difference
=
generated rewards
```

This architecture avoids iterating over every staker whenever rewards need to be updated.

---

## Reward-rate changes

Reward rates are expressed using basis points:

```text
100 BPS    = 1%
200 BPS    = 2%
10,000 BPS = 100%
```

Before changing the reward rate, the protocol consolidates rewards generated using the previous rate.

```text
old reward period
        ↓
_updateGlobalReward()
        ↓
global index updated
        ↓
rewardRateBps changed
        ↓
new reward period
```

This prevents new rates from being applied retroactively.

---

## Principal, reward pool and liabilities

The protocol explicitly separates physical token balances from economic obligations.

### Principal

```solidity
totalStaked
```

Tracks user principal.

These tokens must never be used as rewards.

### Reward pool

```solidity
rewardPoolBalance()
```

Represents the physical tokens available for rewards:

```text
contract ERC-20 balance
-
user principal
```

### Reward liabilities

```solidity
currentRewardLiability()
```

Tracks rewards that have already been economically earned by users.

### Withdrawable rewards

```solidity
withdrawableRewards()
```

Only rewards that are not already owed to users can be withdrawn by the owner.

Example:

```text
Physical reward pool:      10,000 STK
Existing liabilities:         600 STK
-------------------------------------
Owner withdrawable:         9,400 STK
```

---

## Precision and rounding

Solidity uses integer arithmetic, meaning divisions can truncate fractional values.

During stateful invariant testing, a precision edge case was discovered.

Frequent global liability updates could truncate very small reward fractions while a user's accumulated reward eventually represented a complete token unit.

Conceptually:

```text
0.4
0.4
0.4
```

could be independently truncated instead of being accumulated.

This could make the global liability smaller than an individual user's claimable reward and eventually trigger an arithmetic underflow during a claim.

The protocol fixes this by preserving the division remainder through:

```solidity
rewardLiabilityRemainder
```

Instead of discarding fractional accounting information, it is carried into future global updates.

This issue was discovered through invariant testing rather than the initial unit-test suite.

---

## Security

The protocol uses OpenZeppelin components including:

- `SafeERC20`
- `ReentrancyGuard`
- `Pausable`
- `Ownable`
- `Ownable2Step`

### Emergency mode

While paused:

```text
stake()         blocked
claimRewards()  blocked
unstake()       available
```

Users deliberately retain the ability to recover their principal during an emergency.

### Two-step ownership

Administrative ownership transfers require explicit acceptance by the new owner:

```text
transferOwnership()
        ↓
pendingOwner
        ↓
acceptOwnership()
        ↓
new owner
```

---

## Testing strategy

The project combines:

- unit tests;
- multi-user scenarios;
- time-dependent tests;
- access-control tests;
- insolvency tests;
- reward accounting tests;
- fuzz testing;
- stateful invariant testing;
- precision and rounding tests.

### Stateful invariant testing

Foundry executes long randomized sequences such as:

```text
stake
advanceTime
stake
claim
unstake
advanceTime
claim
...
```

One complete invariant campaign executed:

```text
Runs:     256
Calls:    128,000
Reverts:  0
```

Fundamental protocol properties include:

```text
totalStaked
=
sum of user stakes
```

and:

```text
contract token balance
>=
totalStaked
```

Invariant testing also uncovered the reward-liability precision issue described above.

---

## Coverage

Generated with:

```bash
forge coverage
```

### Main contract

| Metric | Coverage |
|---|---:|
| Lines | **98.92% (92/93)** |
| Statements | **98.97% (96/97)** |
| Branches | **70.83% (17/24)** |
| Functions | **100.00% (17/17)** |

### Complete project

| Metric | Coverage |
|---|---:|
| Lines | **99.32% (145/146)** |
| Statements | **99.35% (153/154)** |
| Branches | **78.12% (25/32)** |
| Functions | **100.00% (29/29)** |

The project intentionally prioritizes meaningful behavioral testing over artificially forcing 100% branch coverage.

Unit tests, fuzz tests and invariants are used together to validate the protocol.

---

## Project structure

```text
staking-protocol/
│
├── src/
│   ├── StakingProtocol.sol
│   └── StakingToken.sol
│
├── test/
│   ├── StakingProtocol.t.sol
│   └── StakingInvariant.t.sol
│
├── foundry.toml
├── remappings.txt
└── README.md
```

---

## Installation

Clone the repository:

```bash
git clone https://github.com/ikerbotana2002/staking-protocol.git
cd staking-protocol
```

Install dependencies:

```bash
forge install
```

Build:

```bash
forge build
```

Run the complete test suite:

```bash
forge test
```

Run invariant testing:

```bash
forge test --match-contract StakingInvariantTest -vv
```

Generate coverage:

```bash
forge coverage
```

---

## Tech stack

- Solidity
- Foundry
- Forge
- OpenZeppelin Contracts
- Forge Std
- Git
- GitHub

---

## Technical topics explored

- fixed-point arithmetic;
- reward accounting;
- global reward indexes;
- user checkpoints;
- asset/liability separation;
- ERC-20 integrations;
- stateful testing;
- invariant design;
- fuzz testing;
- arithmetic precision;
- access control;
- emergency mechanisms;
- DeFi protocol security.

---

## Status

Functional portfolio and educational project with extensive automated testing.

The contracts have not undergone a professional security audit and should not be used with real funds.