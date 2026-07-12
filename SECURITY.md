# Seguridad

## Modelo de seguridad

Caldera separa configuración, custodia, representación de posiciones y
settlement. Las operaciones económicas se orquestan desde una única fachada y
los módulos de estado solo aceptan llamadas de esa dirección una vez enlazados.

El administrador inicial asigna roles diferenciados:

- gobierno configura activos, parámetros y series;
- el gestor de oracle publica precios secuenciados;
- el guardián puede pausar nuevas operaciones económicas;
- la reanudación requiere autoridad de gobierno.

El procesamiento de solicitudes maduras es permissionless para evitar que un
keeper concreto sea un requisito de disponibilidad.

## Supuestos de activos

- Los activos implementan el comportamiento ERC-20 convencional.
- Se admiten entre 1 y 18 decimales.
- No se admiten tokens con comisión en transferencia, rebasing o balances que
  cambien durante una operación.
- Cada activo tiene cap de depósito y puede deshabilitarse para nuevas series.
- Los precios del subyacente se normalizan a 18 decimales.

## Invariantes esperadas

- Los contratos vendidos nunca superan los contratos escritos.
- El supply long, las solicitudes registradas y los contratos liquidados
  conservan el open interest de la serie.
- El payout individual nunca supera el colateral máximo de sus contratos.
- Una solicitud solo transita de pendiente a procesamiento y a procesada.
- Una posición writer solo puede liquidarse una vez.
- Las primas se separan físicamente del vault de colateral.
- Las comisiones y primas pagadas no superan el importe recaudado.
- Los precios caducados, futuros o fuera de secuencia se rechazan.
- Los cambios de fase dependen exclusivamente de ventanas inmutables.
- El balance físico y las reservas contables pueden inspeccionarse por activo.

## Controles automatizados

```bash
forge fmt --check
forge build --sizes
forge test
FOUNDRY_PROFILE=ci forge test
bash scripts/check-loc.sh
```

Los tests cubren creación de series, cotización, escritura, compras,
distribución de primas, ejercicio, procesamiento por lotes, expiración,
transferencias de posiciones, roles, pausado y límites del oracle.

## Dependencias y compilación

El proyecto fija Solidity 0.8.24 y EVM Cancun en `foundry.toml`. `forge-std` es
la única dependencia de desarrollo. Dependabot revisa GitHub Actions y los
submódulos de Foundry.

## Alcance de revisión

Los reportes deben incluir:

- contrato y función afectados;
- precondiciones y orden exacto de transacciones;
- estado de series, posiciones y cola antes y después;
- variación de balances físicos y contables;
- impacto económico máximo;
- prueba reproducible con Foundry;
- propuesta de mitigación y tests de regresión.

No se aceptan como hallazgos aislados decisiones documentadas del modelo, como
la liquidación monetaria, el cap de las calls o la naturaleza permissionless
del procesamiento maduro.
