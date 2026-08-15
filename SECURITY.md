# Política de seguridad

## Versiones mantenidas

| Versión | Estado            | Referencia                            |
| ------- | ----------------- | ------------------------------------- |
| 1.0.x   | Mantenida         | Rama `production` y etiqueta `v1.0.0` |
| < 1.0   | Sin mantenimiento | No recibe correcciones                |

Una entrega se considera publicada cuando `main`, `production`, la etiqueta anotada y el release
han superado sus controles independientes.

## Propiedades protegidas

Caldera preserva autorización, cobertura, aislamiento contable, monotonicidad de estados y
trazabilidad. Los invariantes fundamentales son:

```text
soldContracts <= writtenContracts
liveLongSupply + settledContracts == soldContracts
payout(request) <= collateralPerContract * contracts
reserveBySeries <= collateralDeposited - collateralReleased
premiumPaid + feePaid <= grossPremium
processed request => processedAt != 0
executed operation => activeApprovals >= approvalQuorum
```

Las cantidades monetarias usan enteros. Los precios se expresan en WAD y porcentajes en BPS. El
colateral máximo redondea hacia arriba y los pagos realizados hacia abajo. Ninguna integración debe
convertir unidades atómicas a coma flotante.

## Superficie protegida

- Registro de activos, decimales, habilitación y caps de depósito.
- Configuración de series, ventanas, strike, cap, tamaño y fees.
- Secuencia, timestamp, frescura y normalización del oracle.
- Escritura, compra, supplies y autoridad sobre posiciones.
- Custodia de garantía, primas, fees, reservas y balance físico.
- Solicitud, demora, procesamiento y cierre de ejercicios.
- Índices de prima y pérdida, restos de división y settlement de writers.
- Pausa, roles, timelock, quórum, predecesores y cancelación.
- Fuentes de liquidez, supuestos de estrés, concentración y digests.
- SDK, timeout, idempotencia, esquema de respuesta y cadena de entrega.

## Modelo de confianza

El administrador gestiona el grafo de roles; gobierno configura mercados y programa cambios; el
guardián pausa y cancela operaciones pendientes; el gestor de oracle publica observaciones
secuenciadas. Procesar solicitudes maduras es permissionless para no depender de una identidad
concreta. Los módulos con fondos aceptan llamadas de la fachada enlazada y rechazan sustitución
posterior.

Los activos admitidos deben seguir ERC-20 convencional. No se admiten comisiones en transferencia,
rebasing ni balances que cambien durante una operación. Una transferencia valida el delta exacto
antes de actualizar el estado final.

## Comunicación privada

Use **GitHub Security Advisories → New draft advisory** en este repositorio. No publique detalles
técnicos en incidencias o discusiones. Incluya:

1. Versión, contrato, función y precondiciones.
2. Orden exacto de transacciones y marcas temporales.
3. Estado de serie, posición, cola y custodia antes y después.
4. Variación de balances físicos y contables.
5. Impacto máximo razonable y factores que lo limitan.
6. Reproducción mínima con Foundry, sin secretos ni datos ajenos.
7. Mitigación o invariante propuesto.

Acusaremos recibo en tres días laborables, comunicaremos clasificación inicial en siete y
mantendremos actualizaciones relevantes al menos cada catorce días. La divulgación se coordina
después de que exista una versión corregida y verificable.

## Investigación de buena fe

- Use solo cuentas, activos y entornos bajo su control.
- Limite volumen y llamadas al mínimo necesario.
- No interrumpa disponibilidad ni cadenas de entrega.
- No acceda, retenga o comparta información de terceros.
- Detenga la actividad si aparece riesgo para activos externos.
- Conserve hashes, bloques, timestamps, versiones y entradas exactas.

Esta política no autoriza actividad fuera de los sistemas controlados por la organización.

## Respuesta

Una señal financiera activa el flujo de [docs/runbooks.md](./docs/runbooks.md): contención, captura
de estado, conciliación, escenarios de estrés, cambio autorizado, verificación y reanudación gradual.
No se corrigen saldos manualmente sin una transición reproducible y auditable.

## Integridad de entrega

- Solidity 0.8.24, Foundry 1.7.1, Node.js 24 y Bun 1.3.14 están fijados.
- `forge-std`, `foundry.lock` y `bun.lock` conservan dependencias reproducibles.
- CI ejecuta formato, tamaños, unitarias, fuzz, invariantes, SDK y contrato documental.
- Linux y Windows deben completar la misma puerta funcional.
- CODEOWNERS cubre gobierno, riesgo, workflows y documentación.
- La etiqueta debe ser anotada, coincidir con `package.json` y resolver a `origin/production`.
- La puerta completa se repite al crear la etiqueta y al publicar el release.
