KipuBankV3
Descripción

KipuBankV3 es un contrato inteligente educativo en Solidity que simula un banco descentralizado en Ethereum. Ha sido mejorado para soportar múltiples criptoactivos y gestionar un límite de capacidad basado en el valor USD.
Características Clave

    Soporte Multi-Token: Permite depósitos y retiros de ETH (nativo), USDC (ERC20), y BTC (via un token ERC20).
    Capacidad Global en USD: Utiliza oráculos de Chainlink para asegurar que el valor total depositado en el banco nunca exceda un límite máximo predefinido en USD.
    Seguridad: Implementa protección contra reentrancy (ReentrancyGuard) y usa consultas de precios seguras (validación de Chainlink, stale price checks).

Mejoras Realizadas

El contrato original era un banco simple de ETH. Las mejoras en KipuBankV3 lo transforman en una simulación más robusta de un protocolo DeFi moderno:

    Soporte Multi-Token (ETH, USDC, BTC): Se agregaron funciones de depósito y retiro específicas para ERC20. Racional: Un banco moderno necesita interactuar con múltiples activos, incluyendo stablecoins y tokens representativos.
    Capacidad en USD con Chainlink: La capacidad máxima (i_bankCap) se define en USD. El contrato calcula el valor actual de todos los fondos (ETH + USDC + BTC) en USD antes de permitir depósitos. Racional: Centralizar la capacidad en USD es crucial para gestionar el riesgo de liquidez cuando se aceptan múltiples activos volátiles.
    Oráculo y Stale Price Checks: Se integraron feeds de Chainlink y se implementó la verificación de tiempo (ORACLE_HEARTBEAT). Racional: Garantiza que las conversiones de valor a USD utilicen precios recientes y válidos, mitigando el riesgo de manipulación de precios.
    Emergency Withdrawal: Se añadió una función onlyOwner para que el dueño recupere ETH o tokens ERC20 enviados por error al contrato. Racional: Práctica de seguridad estándar para recuperar activos no rastreados.

Instrucciones de Despliegue e Interacción
Despliegue

El despliegue requiere siete (8) argumentos en el constructor:
| Parámetro | Tipo | Descripción |
|------------|------|-------------|
| `_initialOwner` | `address` | Dirección del dueño del contrato. |
| `_weth` | `address` | Dirección del token WETH en Sepolia. |
| `_usdc` | `address` | Dirección del token USDC (o mock USDC) en Sepolia. |
| `_router` | `address` | Dirección del Router de Uniswap V2. |
| `_factory` | `address` | Dirección del Factory de Uniswap V2. |
| `_ethFeed` | `address` | Dirección del oráculo ETH/USD de Chainlink. |
| `_btcFeed` | `address` | Dirección del oráculo BTC/USD de Chainlink. |
| `_bankCap` | `uint256` | Capacidad máxima del banco (en USD, sin decimales). |
| `_maxWithdrawal` | `uint256` | Límite máximo de retiro por transacción (en USD). |

Interacción

| Función | Descripción | Requerimientos | | deposit() | Deposita ETH nativo. | Debe ser payable. | | withdraw(uint256 amount) | Retira ETH del saldo del usuario. | Saldo suficiente y monto menor a i_maxWithdrawal. | | depositERC20(uint256 amount) | Deposita tokens ERC20, presentes en UniSwap. | El usuario debe haber aprobado (approve) la transferencia previamente. | | withdrawUSDC(uint256 amount) | Retira tokens USDC. | Saldo suficiente y monto menor a i_maxWithdrawal. | | consultKipuBankFounds() | Retorna el valor total de todos los activos del banco en USDC. | view function. | | setFeeds(...) | Actualiza las direcciones de los oráculos. | onlyOwner. | | emergencyWithdrawal(...) | Retira ETH o ERC20 enviados por error al contrato. | onlyOwner. |

#### Ejemplo (Sepolia)

{
	"address _initialOwner": "",
	"address _weth": "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
	"address _usdc": "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
	"address _router": "0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3",
	"address _factory": "0xF62c03E08ada871A0bEb309762E260a7a6a880E6",
	"uint256 _bankCap": "10000",
	"uint256 _maxWithdrawal": "500"
}
